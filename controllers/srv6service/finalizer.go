// SPDX-License-Identifier: Apache-2.0
//
// Finalizer, T358/T359 and T394/T395. The finalizer
// (api/v1alpha1.SRv6Finalizer, agentic-netops.dev/srv6) is added BEFORE any
// claim (T358). On delete (T394): roll back on each node, KEEP the finalizer
// and the claims while a node is unreachable (condition Finalizing naming the
// node, requeue with backoff), release the claims only when every node is
// clean, then remove the finalizer (contracts/srv6service-crd.md §5).
package srv6service

import (
	"context"
	"fmt"
	"sort"
	"strings"

	corev1 "k8s.io/api/core/v1"

	"github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/reasons"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// hasSRv6Finalizer reports whether the object carries the finalizer.
func hasSRv6Finalizer(svc *v1alpha1.SRv6Service) bool {
	for _, f := range svc.Finalizers {
		if f == v1alpha1.SRv6Finalizer {
			return true
		}
	}
	return false
}

// ensureFinalizer adds the finalizer before any claim is made. It returns
// true when the object was patched (the caller requeues; the next reconcile
// sees the finalizer).
func (r *Reconciler) ensureFinalizer(ctx context.Context, svc *v1alpha1.SRv6Service) (bool, error) {
	if hasSRv6Finalizer(svc) {
		return false, nil
	}
	base := svc.DeepCopy()
	svc.Finalizers = append(svc.Finalizers, v1alpha1.SRv6Finalizer)
	if err := r.Patch(ctx, svc, client.MergeFrom(base)); err != nil {
		return false, err
	}
	r.emit(svc, corev1.EventTypeNormal, reasons.ReasonVerified, "finalizer %s added before any claim", v1alpha1.SRv6Finalizer)
	return true, nil
}

// finalizeDelete is the deletion path (T394/T395). Order per §5: rollback on
// every node FIRST, claims released only when every node is clean, then the
// finalizer removed. A node whose rollback cannot be confirmed (transport
// failure — the executor may simply be restarting) keeps the finalizer AND
// the claims; the Finalizing condition names it.
func (r *Reconciler) finalizeDelete(ctx context.Context, svc *v1alpha1.SRv6Service) (ctrl.Result, error) {
	corrID := correlationID(svc)
	log := r.Log.WithValues("finalizing", client.ObjectKeyFromObject(svc), "correlationId", corrID)

	// T558/T559: a deleted service must stop claiming locator, SID and path
	// state in Prometheus. Without this, the gauges keep the last observed
	// values of a service that no longer exists — its active-path series
	// would hold the alert open about nothing.
	if dropped := clearSrv6Metrics(svc); dropped > 0 {
		log.Info("cleared SRv6 state gauges for the deleted service", "series", dropped)
	}

	// Render the plan of what is (or was) applied, to roll it back. Without
	// allocations nothing was ever applied or claimed — in that case the
	// completion event says so explicitly instead of claiming a rollback that
	// never ran (the pre-fix era stored no allocations and silently skipped
	// the device rollback while reporting "rollback confirmed").
	dirty := map[string]bool{}
	rolledBack := false
	if alloc := r.finalizeAllocation(svc); alloc != nil {
		if plan, err := BuildPlan(svc, alloc, r.Facts); err == nil {
			rolledBack = true
			order := PlanOrder(plan)
			sort.Strings(order)
			for _, node := range order {
				np := plan.Nodes[node]
				if len(np.Rollback) == 0 {
					continue
				}
				_, err := r.Executor.Apply(ctx, node, np.Rollback)
				switch {
				case err == nil:
					// clean
				case executorPermanent(err):
					// The executor refused permanently (unknown node, bad
					// request): the node never held our state, so it is
					// clean. A retry would repeat the refusal forever.
					log.Info("rollback permanently refused; treating node as clean", "node", node, "err", err.Error())
				default:
					// Unreachable node: keep the finalizer AND the claims.
					dirty[node] = true
					log.Info("node unreachable during rollback", "node", node, "err", err.Error())
				}
			}
		} else {
			// Without a renderable plan there is nothing to roll back; the
			// release below is what still guards the claims.
			log.Info("plan not renderable during finalize; rolling back nothing", "err", err.Error())
		}
	}

	if len(dirty) > 0 {
		nodes := make([]string, 0, len(dirty))
		for n := range dirty {
			nodes = append(nodes, n)
		}
		sort.Strings(nodes)
		msg := fmt.Sprintf("rollback not yet confirmed on %s; finalizer and claims kept", strings.Join(nodes, ", "))
		r.setAndEmitFinalizing(ctx, svc, msg, nodes)
		return ctrl.Result{RequeueAfter: failureBackoff}, nil
	}

	// Every node clean: release the claims. A release failure also keeps the
	// finalizer (§5: removed only after every claim is released).
	if err := releaseAll(ctx, r.Client, corrID); err != nil {
		msg := fmt.Sprintf("claims not yet released (%v); finalizer kept", err)
		r.setAndEmitFinalizing(ctx, svc, msg, nil)
		return ctrl.Result{RequeueAfter: failureBackoff}, nil
	}

	// Clean: remove the finalizer; the object then goes away.
	base := svc.DeepCopy()
	finalizers := make([]string, 0, len(svc.Finalizers))
	for _, f := range svc.Finalizers {
		if f != v1alpha1.SRv6Finalizer {
			finalizers = append(finalizers, f)
		}
	}
	svc.Finalizers = finalizers
	if err := r.Patch(ctx, svc, client.MergeFrom(base)); err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}
	if rolledBack {
		r.emit(svc, corev1.EventTypeNormal, reasons.ReasonVerified,
			"rollback confirmed on every node and claims released; finalizer removed")
	} else {
		r.emit(svc, corev1.EventTypeNormal, reasons.ReasonVerified,
			"no recorded allocations; released claims and removed finalizer without device rollback")
	}
	return ctrl.Result{}, nil
}

// finalizeAllocation rebuilds the allocation view the applied plan was
// rendered from, from the recorded status (or nil when nothing was claimed).
func (r *Reconciler) finalizeAllocation(svc *v1alpha1.SRv6Service) *Allocation {
	st := svc.Status.Allocations
	if st == nil || st.ServiceID <= 0 {
		return nil
	}
	sids, err := serviceSIDs(svc, r.Facts.Locators)
	if err != nil {
		return nil
	}
	return &Allocation{Allocations: st, ServiceSIDs: sids}
}

// setAndEmitFinalizing records the Finalizing condition and emits it. nodes
// (possibly empty) names the nodes whose rollback is not yet confirmed — the
// condition message carries them and the log line keeps them structured.
func (r *Reconciler) setAndEmitFinalizing(ctx context.Context, svc *v1alpha1.SRv6Service, message string, nodes []string) {
	base := svc.DeepCopy()
	setFinalizing(&svc.Status, svc.Generation, message)
	if err := r.Status().Patch(ctx, svc, client.MergeFrom(base)); err != nil {
		r.Log.Error(err, "record Finalizing condition", "srv6service", client.ObjectKeyFromObject(svc))
	}
	if len(nodes) > 0 {
		r.Log.Info("finalizing", "srv6service", client.ObjectKeyFromObject(svc), "unconfirmedNodes", nodes)
	}
	r.emit(svc, corev1.EventTypeWarning, reasons.ReasonFinalizing, "%s", message)
}
