//go:build agentic_netops_k8s

// SPDX-License-Identifier: Apache-2.0
// NetworkReconciler: the SONiC provider's Network intent loop.
//
// Watches network.kubenet.dev Networks in the intent tier's namespace (the
// deployer submits them there), renders them into per-node SONiC device
// operations (pkg/fabricplan), applies them through the fabric-executor, and —
// this is the part the whole intent-to-fabric contract hangs on — sets the
// Network's Ready condition from VERIFIED device state, so the deployer's
// convergence watch reports the fabric's truth, not the submission's optimism.
//
// Apply semantics are idempotent (GCU add replaces, redis hset overwrites,
// kernel sets are no-ops-when-satisfied), so requeues after partial failures
// converge without a separate transaction log.
package sonicprovider

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"github.com/go-logr/logr"
	"github.com/mairp/agentic-netops/pkg/compat"
	"github.com/mairp/agentic-netops/pkg/fabricplan"
	"github.com/mairp/agentic-netops/pkg/kubenet"
	"github.com/mairp/agentic-netops/pkg/reasons"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
)

const networkFinalizer = "agentic-netops.dev/fabric"

// ExecutorURL is the fabric-executor Service (env FABRIC_EXECUTOR_URL).
func ExecutorURL() string {
	if v := os.Getenv("FABRIC_EXECUTOR_URL"); v != "" {
		return v
	}
	return "http://agentic-netops-fabric-executor.agentic-netops-system:8084"
}

// PortMapFromEnv parses FABRIC_PORT_MAP (logical attachment name -> kernel port).
func PortMapFromEnv() fabricplan.PortMapper {
	raw := os.Getenv("FABRIC_PORT_MAP")
	if raw == "" {
		return fabricplan.PortMapper{}
	}
	m := fabricplan.PortMapper{}
	_ = json.Unmarshal([]byte(raw), &m)
	return m
}

type NetworkReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Log      logr.Logger
	Recorder recordEventer
	// APIReader, when set, is used for the site pins ConfigMap: uncached,
	// so a broken shared ConfigMap informer cannot starve pin resolution.
	APIReader compat.PinReader
	http      *http.Client

	applyCounter prometheus.Counter
}

// executorApplyResult mirrors fabric-executor's ApplyResponse.
type executorApplyResult struct {
	Node    string `json:"node"`
	OK      bool   `json:"ok"`
	Results []struct {
		Kind   string `json:"kind"`
		OK     bool   `json:"ok"`
		Output string `json:"output,omitempty"`
		Error  string `json:"error,omitempty"`
	} `json:"results"`
}

type executorVerifyResult struct {
	Node    string `json:"node"`
	OK      bool   `json:"ok"`
	Results []struct {
		Check  string `json:"check"`
		OK     bool   `json:"ok"`
		Actual string `json:"actual,omitempty"`
		Error  string `json:"error,omitempty"`
	} `json:"results"`
}

func (r *NetworkReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	var net kubenet.Network
	if err := r.Get(ctx, req.NamespacedName, &net); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
	log := r.Log.WithValues("network", req.NamespacedName)

	// Deletion: roll back owned device state (best-effort), then release.
	if !net.DeletionTimestamp.IsZero() {
		log.Info("rolling back network on device")
		plan, err := fabricplan.ForNetwork(&net, fabricplan.Options{Ports: PortMapFromEnv()})
		if err == nil {
			for _, nodeName := range sortedNodeNames(plan) {
				np := plan.Nodes[nodeName]
				if len(np.Rollback) > 0 {
					res, err := r.executorApply(ctx, nodeName, np.Rollback)
					if err != nil {
						if isPermanentExecutorError(err) {
							// The site does not have this node, so nothing was
							// ever applied on it and nothing can be rolled
							// back. Holding the finalizer for a node that
							// cannot exist made such an object undeletable
							// except by editing its finalizers by hand.
							log.Info("rollback skipped: executor refuses this node permanently",
								"node", nodeName, "err", err.Error())
							continue
						}
						log.Error(err, "rollback apply failed; retaining finalizer", "node", nodeName)
						return ctrl.Result{RequeueAfter: 15 * time.Second}, nil
					}
					log.Info("rollback applied", "node", nodeName, "ok", res.OK)
				}
			}
		} else {
			// Unrenderable networks cannot have applied anything on device.
			log.Info("network unrenderable at delete; skipping rollback", "err", err.Error())
		}
		net.Finalizers = removeString(net.Finalizers, networkFinalizer)
		if err := r.Update(ctx, &net); err != nil {
			return ctrl.Result{}, err
		}
		if r.Recorder != nil {
			r.Recorder.Eventf(&net, "Normal", "FabricRolledBack", "device state rolled back and finalizer released")
		}
		return ctrl.Result{}, nil
	}

	// Ensure finalizer before any device write.
	if !containsString(net.Finalizers, networkFinalizer) {
		net.Finalizers = append(net.Finalizers, networkFinalizer)
		if err := r.Update(ctx, &net); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{RequeueAfter: time.Second}, nil
	}

	// Compatibility gate against the site pins (versions.lock defaults, object
	// annotations override). Failures are truthful SchemaMismatch, not guesses.
	pinReader := compat.PinReader(r.Client)
	if r.APIReader != nil {
		pinReader = r.APIReader
	}
	pins := compat.ResolveSitePins(ctx, pinReader, net.Annotations, net.Labels)
	set := compat.FromAnnotations(pins.Annotations)
	discovered := map[string]bool{"sai.srv6": pins.Labels["agentic-netops.dev/cap.sai.srv6"] == "true"}
	if err := compat.FullValidate(set, pins.Labels, discovered); err != nil {
		r.setConditions(ctx, &net, false, compat.ReasonFor(err), err.Error()+" ("+pins.Provenance()+")", false)
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	plan, err := fabricplan.ForNetwork(&net, fabricplan.Options{Ports: PortMapFromEnv()})
	if err != nil {
		// Rendering failures are intent-shape problems, not transients.
		r.setConditions(ctx, &net, false, reasons.ReasonSchemaMismatch, err.Error(), false)
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}

	hardFail := false
	var firstErr string
	for _, nodeName := range sortedNodeNames(plan) {
		np := plan.Nodes[nodeName]
		res, err := r.executorApply(ctx, nodeName, np.Ops)
		if err != nil {
			hardFail, firstErr = true, fmt.Sprintf("node %s: executor unreachable: %v", nodeName, err)
			break
		}
		for _, rr := range res.Results {
			if rr.OK {
				continue
			}
			// Every rendered operation is part of the convergence contract. The
			// clean 202505 image closes D-A2, so FRR failures can no longer be
			// reported as a successful deployment.
			hardFail = true
			if firstErr == "" {
				// Include the op's own log tail: "exit code N" alone is not
				// actionable (a bare exit 2 hid a shell failure for a full
				// debug cycle).
				firstErr = fmt.Sprintf("node %s %s: %s | %s", nodeName, rr.Kind, rr.Error, truncateStr(rr.Output, 1500))
			}
		}
		if hardFail {
			break
		}

		vres, err := r.executorVerify(ctx, nodeName, np.Checks)
		if err != nil {
			hardFail, firstErr = true, fmt.Sprintf("node %s: executor verify unreachable: %v", nodeName, err)
			break
		}
		for _, vr := range vres.Results {
			if !vr.OK {
				hardFail = true
				if firstErr == "" {
					firstErr = fmt.Sprintf("node %s %s: %s", nodeName, vr.Check, vr.Error)
				}
			}
		}
		if hardFail {
			break
		}
	}

	switch {
	case hardFail:
		msg := firstErr
		if msg == "" {
			msg = "device apply/verify failed"
		}
		r.setConditions(ctx, &net, false, reasons.ReasonApplyFailed, msg, false)
		// Transient: manager daemons lag GCU writes by seconds; requeue fast.
		return ctrl.Result{RequeueAfter: 5 * time.Second}, nil
	default:
		r.setConditions(ctx, &net, true, reasons.ReasonApplySucceeded, "applied and verified on all nodes", false)
		// Re-verify on a slow cadence. Returning no requeue at all meant a
		// converged service was never looked at again: device state that
		// drifted afterwards — a manager daemon that died, a reboot, another
		// service's teardown taking a shared device with it — left the Network
		// claiming Ready=True over a fabric that no longer matched it
		// (observed live: nine L3VPNs Ready=True with their SVIs gone). Every
		// op and check is idempotent, so a resync either confirms the service
		// or repairs it and says so.
		return ctrl.Result{RequeueAfter: resyncInterval}, nil
	}
}

// resyncInterval is how often a converged Network is re-applied and
// re-verified. Long enough not to churn the executor, short enough that a
// Ready condition is a statement about the fabric now, not only about the
// moment it first converged.
const resyncInterval = 5 * time.Minute

func sortedNodeNames(plan *fabricplan.Plan) []string {
	names := make([]string, 0, len(plan.Nodes))
	for n := range plan.Nodes {
		names = append(names, n)
	}
	for i := 1; i < len(names); i++ {
		for j := i; j > 0 && names[j] < names[j-1]; j-- {
			names[j], names[j-1] = names[j-1], names[j]
		}
	}
	return names
}

func (r *NetworkReconciler) clientHTTP() *http.Client {
	if r.http == nil {
		r.http = &http.Client{Timeout: 120 * time.Second}
	}
	return r.http
}

func (r *NetworkReconciler) executorApply(ctx context.Context, node string, ops []fabricplan.Op) (*executorApplyResult, error) {
	payload, err := json.Marshal(map[string]any{"node": node, "ops": ops})
	if err != nil {
		return nil, err
	}
	return postJSON[executorApplyResult](r.clientHTTP(), ctx, ExecutorURL()+"/v1/node/apply", payload)
}

func (r *NetworkReconciler) executorVerify(ctx context.Context, node string, checks []fabricplan.Check) (*executorVerifyResult, error) {
	payload, err := json.Marshal(map[string]any{"node": node, "checks": checks})
	if err != nil {
		return nil, err
	}
	return postJSON[executorVerifyResult](r.clientHTTP(), ctx, ExecutorURL()+"/v1/node/verify", payload)
}

func postJSON[T any](hc *http.Client, ctx context.Context, url string, body []byte) (*T, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 300 {
		err := fmt.Errorf("executor %s: %d %s", url, resp.StatusCode, truncateStr(string(raw), 200))
		if resp.StatusCode >= 400 && resp.StatusCode < 500 {
			// The executor understood and refused: the request itself is wrong
			// (an unknown node, a malformed op). Retrying cannot change that,
			// and the caller needs to tell it apart from an outage.
			return nil, &permanentExecutorError{err: err}
		}
		return nil, err
	}
	var out T
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("executor response: %v", err)
	}
	return &out, nil
}

// permanentExecutorError marks a refusal the executor will give every time —
// a node the site does not have, a request it cannot parse. A transport
// failure is NOT one of these: the executor may simply be restarting.
type permanentExecutorError struct{ err error }

func (e *permanentExecutorError) Error() string { return e.err.Error() }
func (e *permanentExecutorError) Unwrap() error { return e.err }

func isPermanentExecutorError(err error) bool {
	var perm *permanentExecutorError
	return errors.As(err, &perm)
}

func truncateStr(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

// setConditions patches Ready and Degraded onto the Network status
// map. The loose map is copied before mutation: the shallow DeepCopyObject of
// the loose types shares the underlying map.
func (r *NetworkReconciler) setConditions(ctx context.Context, net *kubenet.Network, ready bool, reason, message string, degraded bool) {
	status := map[string]any{}
	for k, v := range net.Status {
		status[k] = v
	}
	conds := decodeConditions(status["conditions"])
	now := metav1.NewTime(time.Now())
	conds = upsertCondition(conds, metav1.Condition{
		Type: "Ready", Status: boolCond(ready), Reason: reason, Message: message,
		ObservedGeneration: net.Generation, LastTransitionTime: now,
	})
	conds = upsertCondition(conds, metav1.Condition{
		Type: "Degraded", Status: boolCond(degraded),
		Reason:             map[bool]string{true: "ApplyDegraded", false: "NoFailuresObserved"}[degraded],
		Message:            map[bool]string{true: "one or more non-fatal apply operations failed", false: ""}[degraded],
		ObservedGeneration: net.Generation, LastTransitionTime: now,
	})
	status["conditions"] = conds
	status["observedGeneration"] = net.Generation

	patched := net.DeepCopyObject().(*kubenet.Network)
	patched.Status = status
	if err := r.Status().Patch(ctx, patched, client.MergeFrom(net)); err != nil {
		r.Log.Error(err, "status patch failed", "network", client.ObjectKeyFromObject(net))
	}
	if r.applyCounter != nil && ready {
		r.applyCounter.Inc()
	}
	if r.Recorder != nil {
		eventtype, ereason := "Normal", reason
		if !ready {
			eventtype = "Warning"
		}
		r.Recorder.Eventf(patched, eventtype, ereason, "%s", message)
	}
}

// decodeConditions round-trips the status map's conditions through JSON: after
// the first status write the API hands them back as []any (float timestamps),
// which no Go type assertion accepts.
func decodeConditions(v any) []metav1.Condition {
	var conds []metav1.Condition
	if v == nil {
		return conds
	}
	b, err := json.Marshal(v)
	if err != nil {
		return conds
	}
	_ = json.Unmarshal(b, &conds)
	return conds
}

func upsertCondition(conds []metav1.Condition, c metav1.Condition) []metav1.Condition {
	for i := range conds {
		if conds[i].Type == c.Type {
			conds[i] = c
			return conds
		}
	}
	return append(conds, c)
}

func boolCond(b bool) metav1.ConditionStatus {
	if b {
		return metav1.ConditionTrue
	}
	return metav1.ConditionFalse
}

func (r *NetworkReconciler) SetupWithManager(mgr ctrl.Manager) error {
	if r.applyCounter == nil {
		r.applyCounter = promauto.NewCounter(prometheus.CounterOpts{
			Namespace: "agentic_netops",
			Subsystem: "sonicprovider",
			Name:      "networks_converged_total",
			Help:      "Networks verified converged onto the fabric",
		})
	}
	return ctrl.NewControllerManagedBy(mgr).
		For(&kubenet.Network{}).
		WithEventFilter(predicate.NewPredicateFuncs(func(obj client.Object) bool {
			// The intent tier's namespace is where the deployer submits Networks;
			// nothing else in the cluster is our input.
			return obj.GetNamespace() == "agentic-netops-intent"
		})).
		Complete(r)
}
