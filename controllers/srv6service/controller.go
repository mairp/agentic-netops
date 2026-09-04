package srv6service

import (
	"context"
	"time"

	"github.com/go-logr/logr"
	agenticnetopsv1alpha1 "github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/compat"
	"github.com/mairp/agentic-netops/pkg/reasons"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

type Reconciler struct {
	client.Client
	Scheme *runtime.Scheme
	Log    logr.Logger
	// APIReader, when set, backs the site-pins read (uncached; see pins.go).
	APIReader compat.PinReader
}

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	var svc agenticnetopsv1alpha1.SRv6Service
	if err := r.Get(ctx, req.NamespacedName, &svc); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// Handle deletion early
	if !svc.DeletionTimestamp.IsZero() {
		return ctrl.Result{}, nil
	}

	// Set ObservedGeneration and initial gating conditions
	updated := svc.DeepCopy()
	if updated.Status.ObservedGeneration != svc.Generation {
		updated.Status.ObservedGeneration = svc.Generation
	}
	// Ensure Ready=False and Degraded=False with WaitingDependencies
	condReady := metav1.Condition{
		Type:               "Ready",
		Status:             metav1.ConditionFalse,
		ObservedGeneration: svc.Generation,
		LastTransitionTime: metav1.NewTime(time.Now()),
		Reason:             reasons.ReasonWaitingDependencies,
		Message:            "Waiting for topology, allocations, targets, and schema compatibility",
	}
	condDegraded := metav1.Condition{
		Type:               "Degraded",
		Status:             metav1.ConditionFalse,
		ObservedGeneration: svc.Generation,
		LastTransitionTime: metav1.NewTime(time.Now()),
		Reason:             reasons.ReasonWaitingDependencies,
		Message:            "No failures observed; dependencies not yet satisfied",
	}
	updated.Status.Conditions = upsertCondition(updated.Status.Conditions, condReady)
	updated.Status.Conditions = upsertCondition(updated.Status.Conditions, condDegraded)

	// Integrate compatibility-set validation. Pins resolve from the site
	// ConfigMap (generated from versions.lock.yaml) with the object's own
	// annotations taking precedence — objects are not required to carry the
	// pins themselves (nothing in the pipeline ever stamped them, which
	// produced false SchemaMismatch on every object).
	pinReader := compat.PinReader(r.Client)
	if r.APIReader != nil {
		pinReader = r.APIReader
	}
	pins := compat.ResolveSitePins(ctx, pinReader, svc.Annotations, svc.Labels)
	set := compat.FromAnnotations(pins.Annotations)
	discovered := map[string]bool{"sai.srv6": pins.Labels["agentic-netops.dev/cap.sai.srv6"] == "true"}
	if err := compat.FullValidate(set, pins.Labels, discovered); err != nil {
		reason := compat.ReasonFor(err)
		cond := metav1.Condition{Type: "Ready", Status: metav1.ConditionFalse, ObservedGeneration: svc.Generation, LastTransitionTime: metav1.NewTime(time.Now()), Reason: reason, Message: err.Error() + " (" + pins.Provenance() + ")"}
		updated.Status.Conditions = upsertCondition(updated.Status.Conditions, cond)
		if e := r.Status().Patch(ctx, updated, client.MergeFrom(&svc)); e != nil {
			return ctrl.Result{}, e
		}
		return reconcile.Result{RequeueAfter: 15 * time.Second}, nil
	}

	if err := r.Status().Patch(ctx, updated, client.MergeFrom(&svc)); err != nil {
		return ctrl.Result{}, err
	}

	// Requeue with bounded backoff while waiting
	return reconcile.Result{RequeueAfter: 10 * time.Second}, nil
}

func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&agenticnetopsv1alpha1.SRv6Service{}).
		Complete(r)
}

func upsertCondition(conds []metav1.Condition, c metav1.Condition) []metav1.Condition {
	found := false
	for i := range conds {
		if conds[i].Type == c.Type {
			conds[i] = c
			found = true
			break
		}
	}
	if !found {
		conds = append(conds, c)
	}
	return conds
}
