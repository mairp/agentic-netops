// SPDX-License-Identifier: Apache-2.0
//
// Pipeline driver, T396 (+T397 events, T390-T393 idempotence and drift,
// T612/T613 the update stage). This file only SEQUENCES the stages and
// records the outcome; one concern per file lives next to it (finalizer.go,
// validate.go, capability.go, supported.go, conflict.go, allocate.go,
// plan.go, update.go, apply.go, verify.go, datapath.go, ready.go,
// events.go). Stage order is the contract's (contracts/srv6service-crd.md
// §5):
//
//	finalizer -> site validation (C1-C3) -> capability (C5, C8)
//	-> supported variant (C6) -> conflicts (C4, C7) -> claims
//	-> plan (render + hash) -> update (changed render)
//	-> apply (zero-write when unchanged)
//	-> verify -> data path (first activation only) -> Ready
//
// Deletion is the finalizer's concern. Every refusal is ONE Ready=False /
// Degraded=True condition pair carrying the data-model.md §6 reason plus one
// event (events.go); terminal refusals do not requeue (ready.go requeueFor).
package srv6service

import (
	"context"
	"errors"

	"github.com/go-logr/logr"
	agenticnetopsv1alpha1 "github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/compat"
	"github.com/mairp/agentic-netops/pkg/reasons"
	"k8s.io/apimachinery/pkg/api/equality"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

// Reconciler reconciles an SRv6Service through the pipeline above.
type Reconciler struct {
	client.Client
	Scheme *runtime.Scheme
	Log    logr.Logger
	// APIReader, when set, backs the capability-record read (uncached; the
	// capability decision must not depend on a possibly-stale shared
	// informer, the same rule pkg/compat/pins.go documents).
	APIReader compat.PinReader
	// Facts are the site facts the validation and render stages consume
	// (validate.go); cmd/srv6-controller builds them from env.
	Facts SiteFacts
	// Executor is the device work surface (executor.go); tests stub it.
	Executor Executor
	// Recorder emits Kubernetes events; nil in unit tests (emit still logs).
	Recorder recordEventer
}

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	var svc agenticnetopsv1alpha1.SRv6Service
	if err := r.Get(ctx, req.NamespacedName, &svc); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// Deletion: the finalizer's concern (T394/T395). Without the finalizer
	// nothing was ever claimed or applied, so the object just goes away.
	if !svc.DeletionTimestamp.IsZero() {
		if !hasSRv6Finalizer(&svc) {
			return ctrl.Result{}, nil
		}
		return r.finalizeDelete(ctx, &svc)
	}

	// The finalizer goes on BEFORE any claim (T358). The patch itself
	// triggers the next reconcile.
	added, err := r.ensureFinalizer(ctx, &svc)
	if err != nil {
		return ctrl.Result{}, err
	}
	if added {
		return ctrl.Result{}, nil
	}

	// Gate 1: site validation C1-C3 (terminal, before anything is claimed).
	if ref := validateSite(&svc, r.Facts); ref != nil {
		return r.refuse(ctx, &svc, ref)
	}

	// Gate 2: capability record C5 (cap-sai-srv6) then C8 (probe hosts),
	// read UNCACHED (capability.go).
	reader := compat.PinReader(r.Client)
	if r.APIReader != nil {
		reader = r.APIReader
	}
	cap, ref := readCapability(ctx, reader)
	if ref == nil {
		ref = checkCapability(&svc, cap)
	}
	if ref != nil {
		return r.refuse(ctx, &svc, ref)
	}

	// Gate 3: supported variant C6 (terminal).
	if ref := checkSupported(&svc, cap); ref != nil {
		return r.refuse(ctx, &svc, ref)
	}

	// Gate 4: conflicts C4/C7 and the operator-named VLAN pre-check
	// (terminal, still before any claim).
	if ref := checkConflicts(ctx, r.Client, &svc); ref != nil {
		return r.refuse(ctx, &svc, ref)
	}

	// Claims (allocate.go): served kuid claim first, Lease fallback for the
	// broken GENID family. A *Refusal is terminal (PoolExhausted, having
	// released every partial claim); any other error is transient. A status
	// that already carries the claimed identifiers reuses them — the claims
	// are deterministic per correlation id, so steady-state reconciles must
	// not round-trip the authority again (measured: repeated claim traffic
	// wedges its in-memory index; quickstart incident 20:49).
	corrID := correlationID(&svc)
	var alloc *Allocation
	if cached := reuseAllocation(&svc, corrID, r.Facts.Locators); cached != nil {
		alloc = &Allocation{Allocations: cached.Allocations, ServiceSIDs: cached.ServiceSIDs}
	} else {
		var err error
		alloc, err = Allocate(ctx, r.Client, &svc, corrID, r.Facts.Locators)
		if err != nil {
			var aref *Refusal
			if errors.As(err, &aref) {
				return r.refuse(ctx, &svc, aref)
			}
			r.Log.Error(err, "claims are temporarily unavailable; requeueing",
				"srv6service", client.ObjectKeyFromObject(&svc), "correlationId", corrID)
			return ctrl.Result{RequeueAfter: failureBackoff}, nil
		}
	}

	// Render + hash (plan.go). After C6 only a proven variant reaches this,
	// so a render error is an invariant breach, not an operator mistake: it
	// surfaces as a non-terminal ApplyFailed naming the error.
	plan, err := BuildPlan(&svc, alloc, r.Facts)
	if err != nil {
		return r.refuse(ctx, &svc, &Refusal{
			Reason:  reasons.ReasonApplyFailed,
			Message: "plan could not be rendered: " + err.Error(),
			Kind:    refusalApply,
		})
	}
	order := PlanOrder(plan)
	hashes := PlanHashes(plan)
	unchanged := hashesEqual(svc.Status.ConfigHashes, hashes)

	// Update (update.go, T612/T613): when a previous render IS applied and
	// the fresh render differs, the change is driven by the update path —
	// per node the PREVIOUS plan's rollback first, then the new plan, verify,
	// and only then the new status.appliedSpec (§3a). A refusal there (a
	// failed node, a failed verification) is surfaced unchanged; a nil return
	// means the new render is already applied, verified and recorded, and the
	// stages below still run over it. The first application (nothing applied
	// yet) and the zero-write re-apply (T390/T391) stay on the plain path.
	if svc.Status.AppliedSpec != nil && !unchanged {
		if ref := r.applyUpdate(ctx, &svc, alloc, plan, order, hashes); ref != nil {
			return r.refuse(ctx, &svc, ref)
		}
	} else if !unchanged {
		// Apply (apply.go): first application. On a node failure the
		// rollback runs on EVERY node and the claims are released.
		failed, aerr := applyPlan(ctx, r.Executor, plan, order)
		if aerr != nil {
			if rberr := rollbackPlan(ctx, r.Executor, plan, order, r.Log); rberr != nil {
				r.Log.Error(rberr, "rollback after apply failure", "srv6service",
					client.ObjectKeyFromObject(&svc), "failedNode", failed)
			}
			if rerr := releaseAll(ctx, r.Client, corrID); rerr != nil {
				r.Log.Error(rerr, "claim release after apply failure", "srv6service",
					client.ObjectKeyFromObject(&svc))
			}
			return r.refuse(ctx, &svc, applyFailedRefusal(failed, aerr))
		}
	}

	// Verify (verify.go): the bootstrap-locator probe first, then every
	// per-node check against device-observed state.
	nodeStatus, vref := verifyPlan(ctx, r.Executor, plan, order, r.Facts.Locators)
	svc.Status.Nodes = nodeStatus

	// Path (path.go, T520/T521): the device-observed spine in use for a
	// steered service, read off the pin's via address on the ingress leaf
	// AFTER verify. It decides failover-vs-drift — a pin on the alternate is
	// the failure action's state, not drift — and raises PathDown naming the
	// missing path when neither leg serves the pin. Unsteered services leave
	// status.activePath empty (data-model §2).
	var view *pathView
	var pobs pathObservation
	if v := steeredPathView(&svc, order, alloc.ServiceSIDs, r.Facts.SpineLinks); v != nil {
		obs, oerr := observePath(ctx, r.Executor, *v)
		if oerr != nil {
			r.Log.Error(oerr, "path observation failed; requeueing",
				"srv6service", client.ObjectKeyFromObject(&svc))
			return ctrl.Result{RequeueAfter: failureBackoff}, nil
		}
		view, pobs = v, obs
	}
	path := steerPathOutcome(&svc, view, pobs, vref)
	if path.Refusal != nil {
		return r.refuse(ctx, &svc, path.Refusal)
	}
	if path.SkipRepair {
		// The pin rides the alternate: the failed preferred-pin checks are
		// the failover state (FR-026 — traffic moves to the other spine),
		// not drift. Re-applying the plan here would re-install the
		// preferred pin and undo the operator's switch, so the reconcile
		// proceeds to Ready with the observed path instead.
		vref = nil
	}
	if vref != nil {
		// Drift repair (T392/T393): when the checks fail but the rendered
		// plan is unchanged (the device state moved, not the spec), the
		// idempotent ops are applied once more and the node is re-verified.
		if unchanged && vref.Kind == refusalCheck {
			// Observe the drift BEFORE repairing it (quickstart Q6): the
			// Ready=False pair names the node and the failed check, so an
			// operator sees the interruption; the Verified write below
			// replaces the pair once the repair re-verifies clean.
			if perr := r.patchDriftObserved(ctx, &svc, vref); perr != nil {
				r.Log.Error(perr, "record drift observation",
					"srv6service", client.ObjectKeyFromObject(&svc))
			}
			r.Log.Info("check failed on an unchanged plan; re-applying (drift)",
				"srv6service", client.ObjectKeyFromObject(&svc), "detail", vref.Message)
			failed, aerr := applyPlan(ctx, r.Executor, plan, order)
			if aerr == nil {
				nodeStatus2, vref2 := verifyPlan(ctx, r.Executor, plan, order, r.Facts.Locators)
				svc.Status.Nodes = nodeStatus2
				vref = vref2
			} else {
				if rberr := rollbackPlan(ctx, r.Executor, plan, order, r.Log); rberr != nil {
					r.Log.Error(rberr, "rollback after drift re-apply failure",
						"srv6service", client.ObjectKeyFromObject(&svc), "failedNode", failed)
				}
				return r.refuse(ctx, &svc, applyFailedRefusal(failed, aerr))
			}
		}
		if vref != nil {
			return r.refuse(ctx, &svc, vref)
		}
	}

	// Ready (ready.go): Verified, with the hashes, applied spec, correlation
	// id, active path and the claimed allocations recorded for the update,
	// drift and reader stages to diff against. base is snapshotted BEFORE
	// the stage writes so the write-back below can tell "nothing changed".
	base := svc.DeepCopy()
	if !dataPathPassed(&svc) {
		ok, detail, derr := runDataPath(ctx, r.Executor, &svc, alloc)
		if derr != nil {
			r.Log.Error(derr, "data-path probe transport failed; requeueing",
				"srv6service", client.ObjectKeyFromObject(&svc))
			return ctrl.Result{RequeueAfter: failureBackoff}, nil
		}
		if !ok {
			return r.refuse(ctx, &svc, dataPathRefusal(detail))
		}
		// The stamp is written ONLY on the pass that actually probed
		// (T388): status.dataPath.checkedAt keeps the first activation's
		// time instead of being re-stamped every reconcile.
		setDataPathPassed(&svc.Status)
	}
	// status.activePath (T520/T521): the device-observed spine the service
	// rides, empty when not steered (data-model §2). Never a spec echo.
	setReadyOutcome(&svc.Status, svc.Generation, hashes, svc.Spec.DeepCopy(), corrID, path.ActivePath, alloc.Allocations)
	// T388 steady state: when every field this stage would write already
	// matches — the same Verified/Degraded pair (upsertCondition keeps the
	// LastTransitionTime unless the status itself changed), the same
	// hashes, applied spec, nodes and data-path stamp — the reconcile
	// writes NOTHING: no status patch and no Verified event. A patch here
	// would trip the object's own watch and requeue it immediately, which
	// is exactly the hot loop this guard removes: the next reconcile now
	// comes from the RequeueAfter below (the §5 "re-verification every 5
	// minutes"), not from self-caused status churn.
	if equality.Semantic.DeepEqual(&base.Status, &svc.Status) {
		return reconcile.Result{RequeueAfter: resyncInterval}, nil
	}
	if err := r.Status().Patch(ctx, &svc, client.MergeFrom(base)); err != nil {
		return ctrl.Result{}, err
	}
	r.emitCondition(&svc, readyTrue(svc.Generation), "service %s verified on %s (data path %s)",
		svc.Name, joinNames(order), svc.Status.DataPath.Result)
	// Steady state: the drift resync (T392) re-runs verify on the interval.
	return reconcile.Result{RequeueAfter: resyncInterval}, nil
}

// SetupWithManager registers the controller. The manager's recorder provider
// backs the event stream (events.go).
func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	if r.Log.GetSink() == nil {
		r.Log = mgr.GetLogger()
	}
	if r.Recorder == nil {
		r.Recorder = mgr.GetEventRecorderFor("srv6-controller")
	}
	return ctrl.NewControllerManagedBy(mgr).
		For(&agenticnetopsv1alpha1.SRv6Service{}).
		Complete(r)
}

// refuse records ONE refusal as the Ready/Degraded pair, emits its event,
// patches the status, and returns the stage's reconcile result (terminal
// refusals do not requeue).
func (r *Reconciler) refuse(ctx context.Context, svc *agenticnetopsv1alpha1.SRv6Service, ref *Refusal) (ctrl.Result, error) {
	base := svc.DeepCopy()
	mayRequeue := setRefusal(&svc.Status, svc.Generation, ref)
	if err := r.Status().Patch(ctx, svc, client.MergeFrom(base)); err != nil {
		return ctrl.Result{}, err
	}
	r.emitCondition(svc, readyConditionOf(svc.Status.Conditions), "%s", ref.Message)
	if !mayRequeue {
		return ctrl.Result{}, nil
	}
	return ctrl.Result{RequeueAfter: requeueFor(ref).requeueAfter}, nil
}

// patchDriftObserved persists the drift's check failure as a Ready=False pair
// (setDriftObserved) and emits the event, so the interruption is observable
// while the repair runs. It is best-effort: a patch error is logged by the
// caller and must not block the repair.
func (r *Reconciler) patchDriftObserved(ctx context.Context, svc *agenticnetopsv1alpha1.SRv6Service, ref *Refusal) error {
	base := svc.DeepCopy()
	setDriftObserved(&svc.Status, svc.Generation, ref)
	if err := r.Status().Patch(ctx, svc, client.MergeFrom(base)); err != nil {
		return err
	}
	r.emitCondition(svc, readyConditionOf(svc.Status.Conditions), "drift observed: %s", ref.Message)
	return nil
}

// readyConditionOf returns the Ready condition of a condition list.
func readyConditionOf(conds []metav1.Condition) metav1.Condition {
	for i := range conds {
		if conds[i].Type == ConditionReady {
			return conds[i]
		}
	}
	return metav1.Condition{}
}
