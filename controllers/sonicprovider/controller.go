package sonicprovider

import (
	"context"
	"fmt"
	"math/rand"
	"time"

	"github.com/go-logr/logr"
	"github.com/mairp/agentic-netops/pkg/compat"
	"github.com/mairp/agentic-netops/pkg/kubenet"
	"github.com/mairp/agentic-netops/pkg/reasons"
	"github.com/mairp/agentic-netops/pkg/render"
	"github.com/mairp/agentic-netops/pkg/sdc"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/predicate"

	// OpenTelemetry instrumentation (T041)
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

// Reconciler watches Kubenet NetworkDevice resources and reconciles downstream SDC Config.

type Reconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Log      logr.Logger
	Recorder recordEventer
	// APIReader, when set, backs the site-pins read (uncached; see pins.go).
	APIReader compat.PinReader

	// metrics
	renderCounter prometheus.Counter

	// tracing
	tracer trace.Tracer
}

type recordEventer interface {
	Eventf(object runtime.Object, eventtype, reason, messageFmt string, args ...any)
}

const (
	finalizerName  = "agentic-netops.dev/finalizer"
	fieldManager   = "agentic-netops-sonic-provider"
	annotationHash = "agentic-netops.dev/config-hash"
	ownerKind      = "NetworkDevice"
)

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	// OTel span
	if r.tracer == nil {
		r.tracer = otel.Tracer("agentic-netops/sonicprovider")
	}
	ctx, span := r.tracer.Start(ctx, "ReconcileNetworkDevice")
	defer span.End()
	span.SetAttributes(attribute.String("k8s.name", req.Name), attribute.String("k8s.namespace", req.Namespace))

	r.Log.Info("reconcile NetworkDevice", "name", req.NamespacedName)
	var nd kubenet.NetworkDevice
	if err := r.Get(ctx, req.NamespacedName, &nd); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// Handle deletion with ordered finalization: delete owned SDC intent, confirm/timeout, retain evidence
	if !nd.DeletionTimestamp.IsZero() {
		cfgName := ownedConfigName(nd.Name)
		cfg := &sdc.Config{ObjectMeta: metav1.ObjectMeta{Name: cfgName, Namespace: nd.Namespace}}
		// Attempt delete each pass
		_ = r.Delete(ctx, cfg)
		// Confirm deletion via independent read path
		err := r.Get(ctx, client.ObjectKey{Name: cfgName, Namespace: nd.Namespace}, cfg)
		if err == nil {
			// Still exists; requeue without removing finalizer yet
			r.Log.Info("waiting for owned SDC Config to be deleted", "name", cfgName)
			return resultWithBackoff(false), nil
		}
		if !apierrors.IsNotFound(err) {
			// API error; retry
			return resultWithBackoff(true), nil
		}
		// It's gone; add finalized-at evidence and remove finalizer
		anno := nd.Annotations
		if anno == nil {
			anno = map[string]string{}
		}
		anno["agentic-netops.dev/finalized-at"] = time.Now().UTC().Format(time.RFC3339)
		nd.Annotations = anno
		nd.Finalizers = removeString(nd.Finalizers, finalizerName)
		if err := r.Update(ctx, &nd); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{}, nil
	}

	// Ensure finalizer present
	if !containsString(nd.Finalizers, finalizerName) {
		nd.Finalizers = append(nd.Finalizers, finalizerName)
		if err := r.Update(ctx, &nd); err != nil {
			return ctrl.Result{}, err
		}
	}

	// Initialize/gate conditions
	condReady := metav1.Condition{
		Type:               "Ready",
		Status:             metav1.ConditionFalse,
		ObservedGeneration: nd.Generation,
		LastTransitionTime: metav1.NewTime(time.Now()),
		Reason:             reasons.ReasonWaitingDependencies,
		Message:            "Waiting for Kubenet/KUID, targets, schema, SDC validation",
	}
	updated := nd
	updated.Status = upsertConditionGeneric(nd.Status, condReady)
	if err := r.Status().Patch(ctx, &updated, client.MergeFrom(&nd)); err != nil {
		return ctrl.Result{}, err
	}

	// Observe existing SDC status EARLY to emit events regardless of gating (T038)
	{
		name := ownedConfigName(nd.Name)
		cfg := &sdc.Config{}
		if err := r.Get(ctx, client.ObjectKey{Name: name, Namespace: nd.Namespace}, cfg); err == nil {
			if len(cfg.Status.Deviation) > 0 {
				// Emit an event even if later gates will block downstream changes.
				if r.Recorder != nil {
					r.Recorder.Eventf(&nd, "Warning", "DeviationObserved", "SDC reported deviations on %s", name)
				}
			}
		}
	}

	// Compatibility-set validation gates downstream mutations (site ConfigMap
	// pins with object-annotation override — see pkg/compat/pins.go).
	pinReader := compat.PinReader(r.Client)
	if r.APIReader != nil {
		pinReader = r.APIReader
	}
	pins := compat.ResolveSitePins(ctx, pinReader, nd.Annotations, nd.Labels)
	set := compat.FromAnnotations(pins.Annotations)
	discovered := map[string]bool{"sai.srv6": pins.Labels["agentic-netops.dev/cap.sai.srv6"] == "true"}
	if err := compat.FullValidate(set, pins.Labels, discovered); err != nil {
		// Set SchemaMismatch/CapabilityMissing and requeue with terminal backoff, no downstream change
		reason := compat.ReasonFor(err)
		cond := metav1.Condition{Type: "Ready", Status: metav1.ConditionFalse, ObservedGeneration: nd.Generation, LastTransitionTime: metav1.NewTime(time.Now()), Reason: reason, Message: err.Error() + " (" + pins.Provenance() + ")"}
		patched := nd
		patched.Status = upsertConditionGeneric(nd.Status, cond)
		_ = r.Status().Patch(ctx, &patched, client.MergeFrom(&nd))
		span.SetAttributes(attribute.String("compat.reason", reason))
		return resultWithBackoff(false), nil
	}

	// Observe existing SDC status to propagate Degraded/Ready (T038)
	{
		name := ownedConfigName(nd.Name)
		cfg := &sdc.Config{}
		if err := r.Get(ctx, client.ObjectKey{Name: name, Namespace: nd.Namespace}, cfg); err == nil {
			if len(cfg.Status.Deviation) > 0 {
				cond := metav1.Condition{Type: "Degraded", Status: metav1.ConditionTrue, ObservedGeneration: nd.Generation, LastTransitionTime: metav1.NewTime(time.Now()), Reason: "DeviationObserved", Message: fmt.Sprintf("%d deviations", len(cfg.Status.Deviation))}
				patched := nd
				patched.Status = upsertConditionGeneric(nd.Status, cond)
				_ = r.Status().Patch(ctx, &patched, client.MergeFrom(&nd))
				if r.Recorder != nil {
					r.Recorder.Eventf(&nd, "Warning", "DeviationObserved", "SDC reported deviations on %s", name)
				}
				return resultWithBackoff(false), nil
			}
			if cfg.Status.Ready {
				condOK := metav1.Condition{Type: "Ready", Status: metav1.ConditionTrue, ObservedGeneration: nd.Generation, LastTransitionTime: metav1.NewTime(time.Now()), Reason: reasons.ReasonApplySucceeded, Message: "rendered and applied"}
				patched := nd
				patched.Status = upsertConditionGeneric(nd.Status, condOK)
				_ = r.Status().Patch(ctx, &patched, client.MergeFrom(&nd))
				return ctrl.Result{}, nil
			}
		}
	}

	// Compose minimal rendered spec (placeholders; full renderers in later tasks)
	spec := map[string]any{}
	spec["/interfaces/interface"] = []map[string]any{{"name": "Ethernet1"}}

	// Offline schema/path validation and register enforcement prior to SSA
	if err := sdc.OfflineValidate(spec); err != nil {
		cond := metav1.Condition{Type: "Ready", Status: metav1.ConditionFalse, ObservedGeneration: nd.Generation, LastTransitionTime: metav1.NewTime(time.Now()), Reason: reasons.ReasonApplyFailed, Message: fmt.Sprintf("offline schema validation failed: %v", err)}
		patched := nd
		patched.Status = upsertConditionGeneric(nd.Status, cond)
		_ = r.Status().Patch(ctx, &patched, client.MergeFrom(&nd))
		return resultWithBackoff(true), nil
	}
	if err := sdc.ValidateSpecAgainstRegister(spec, nil); err != nil {
		cond := metav1.Condition{Type: "Ready", Status: metav1.ConditionFalse, ObservedGeneration: nd.Generation, LastTransitionTime: metav1.NewTime(time.Now()), Reason: reasons.ReasonApplyFailed, Message: fmt.Sprintf("register validation failed: %v", err)}
		patched := nd
		patched.Status = upsertConditionGeneric(nd.Status, cond)
		_ = r.Status().Patch(ctx, &patched, client.MergeFrom(&nd))
		return resultWithBackoff(true), nil
	}

	// Compute canonical hash and apply via SSA with dedicated field manager and minimal policy fields
	hash, _ := render.CanonicalHash(spec)
	obj := &sdc.Config{ObjectMeta: metav1.ObjectMeta{Name: ownedConfigName(nd.Name), Namespace: nd.Namespace, Labels: map[string]string{"agentic-netops.dev/ownerKind": ownerKind}}, Spec: map[string]any{}}
	// seed spec with policy block and rendered fragments (T037)
	obj.Spec["$policy"] = sdc.BuildPolicy(100, "replace", true, "retain")
	for k, v := range spec {
		obj.Spec[k] = v
	}
	if obj.Annotations == nil {
		obj.Annotations = map[string]string{}
	}
	obj.Annotations[annotationHash] = hash
	// propagate compatibility annotations (T035)
	copyCompatAnnotations(nd.Annotations, obj.Annotations)
	// Set owner reference
	if err := ctrl.SetControllerReference(&nd, obj, r.Scheme); err != nil {
		r.Log.Error(err, "set owner reference")
	}
	apply := client.Apply
	force := true
	if err := r.Patch(ctx, obj, apply, &client.PatchOptions{FieldManager: fieldManager, Force: &force}); err != nil {
		cond := metav1.Condition{Type: "Ready", Status: metav1.ConditionFalse, ObservedGeneration: nd.Generation, LastTransitionTime: metav1.NewTime(time.Now()), Reason: reasons.ReasonApplyFailed, Message: err.Error()}
		patched := nd
		patched.Status = upsertConditionGeneric(nd.Status, cond)
		_ = r.Status().Patch(ctx, &patched, client.MergeFrom(&nd))
		return resultWithBackoff(true), nil
	}
	if r.renderCounter != nil {
		r.renderCounter.Inc()
	}
	if r.Recorder != nil {
		r.Recorder.Eventf(&nd, "Normal", reasons.ReasonApplySucceeded, "Applied SDC Config %s with hash %s", obj.Name, hash)
	}

	// Observe SDC Config status to update aggregate conditions and events
	cfg := &sdc.Config{}
	if err := r.Get(ctx, client.ObjectKey{Name: obj.Name, Namespace: obj.Namespace}, cfg); err == nil {
		if cfg.Status.Ready {
			condOK := metav1.Condition{Type: "Ready", Status: metav1.ConditionTrue, ObservedGeneration: nd.Generation, LastTransitionTime: metav1.NewTime(time.Now()), Reason: reasons.ReasonApplySucceeded, Message: "rendered and applied"}
			patched := nd
			patched.Status = upsertConditionGeneric(nd.Status, condOK)
			_ = r.Status().Patch(ctx, &patched, client.MergeFrom(&nd))
			return ctrl.Result{}, nil
		}
		if len(cfg.Status.Deviation) > 0 {
			cond := metav1.Condition{Type: "Degraded", Status: metav1.ConditionTrue, ObservedGeneration: nd.Generation, LastTransitionTime: metav1.NewTime(time.Now()), Reason: "DeviationObserved", Message: fmt.Sprintf("%d deviations", len(cfg.Status.Deviation))}
			patched := nd
			patched.Status = upsertConditionGeneric(nd.Status, cond)
			_ = r.Status().Patch(ctx, &patched, client.MergeFrom(&nd))
			if r.Recorder != nil {
				r.Recorder.Eventf(&nd, "Warning", "DeviationObserved", "SDC reported deviations on %s", obj.Name)
			}
		}
	}

	// Requeue while waiting for SDC to report Ready
	return resultWithBackoff(true), nil
}

func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	// initialize metrics once per manager
	if r.renderCounter == nil {
		r.renderCounter = promauto.NewCounter(prometheus.CounterOpts{
			// Underscore, not hyphen. A Prometheus metric name must match
			// [a-zA-Z_:][a-zA-Z0-9_:]*, and Namespace is prefixed onto it verbatim:
			// "agentic-netops" composes to "agentic-netops_sonicprovider_applies_total",
			// which MustRegister rejects -- panicking the controller at startup before
			// it can serve. The ainetops -> agentic-netops rename (f16b27dc) rewrote
			// this string along with the rest and introduced the hyphen.
			Namespace: "agentic_netops",
			Subsystem: "sonicprovider",
			Name:      "applies_total",
			Help:      "Number of successful SDC Config apply operations",
		})
	}
	return ctrl.NewControllerManagedBy(mgr).
		For(&kubenet.NetworkDevice{}).
		WithEventFilter(ignoreNonNetworkDevice()).
		Owns(&sdc.Config{}).
		Complete(r)
}

func ignoreNonNetworkDevice() predicate.Predicate {
	return predicate.NewPredicateFuncs(func(obj client.Object) bool {
		labels := obj.GetLabels()
		if labels == nil {
			return false
		}
		// Use Kubenet's derived label to select only devices the provider should reconcile
		if v, ok := labels["network.kubenet.dev/derived"]; ok && v == "true" {
			return true
		}
		return false
	})
}

// propagate selected compatibility annotations from source to destination
func copyCompatAnnotations(src, dst map[string]string) {
	if src == nil || dst == nil {
		return
	}
	keys := []string{
		"agentic-netops.dev/sonic-image",
		"agentic-netops.dev/openconfig-commit",
		"agentic-netops.dev/sonic-native-commit",
		"agentic-netops.dev/mapping-version",
		"agentic-netops.dev/kubenet-commit",
		"agentic-netops.dev/kuid-commit",
		"agentic-netops.dev/sdc-release",
	}
	for _, k := range keys {
		if v, ok := src[k]; ok && v != "" {
			dst[k] = v
		}
	}
}

// ensure import
var _ = fmt.Sprintf

func containsString(list []string, s string) bool {
	for _, i := range list {
		if i == s {
			return true
		}
	}
	return false
}
func removeString(list []string, s string) []string {
	out := make([]string, 0, len(list))
	for _, i := range list {
		if i != s {
			out = append(out, i)
		}
	}
	return out
}
func ownedConfigName(owner string) string { return fmt.Sprintf("nd-%s", owner) }

func resultWithBackoff(transient bool) ctrl.Result {
	// Minimal bounded backoff with jitter
	base := 5 * time.Second
	if !transient {
		base = 20 * time.Second
	}
	j := time.Duration(rand.Intn(3000)) * time.Millisecond
	if j > 5*time.Second {
		j = 5 * time.Second
	}
	return ctrl.Result{RequeueAfter: base + j}
}
