// SPDX-License-Identifier: Apache-2.0
//
// Ready condition, T388/T389 + drift T392/T393. Ready=True is set ONLY after
// every per-node check passed on device-observed state AND the first-
// activation data-path probe passed (contracts/srv6service-crd.md §5). The
// steady state re-syncs every five minutes; on resync the per-node checks run
// again, and a drifted node is re-applied (idempotent ops) so Ready returns
// True.
package srv6service

import (
	"time"

	"github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/reasons"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Condition types (data-model.md §2).
const (
	ConditionReady    = "Ready"
	ConditionDegraded = "Degraded"
)

// upsertCondition replaces the condition of the same type, appending when
// absent. The LastTransitionTime follows the Kubernetes condition semantics
// (apimachinery meta.SetStatusCondition): it is stamped ONLY when the
// condition's status changes; rewriting the same True/False condition keeps
// the existing stamp. A steady-state reconcile therefore re-writes
// byte-identical conditions, which is what lets the ready stage detect "the
// status did not change" and skip the patch entirely (T388 — without this
// every resync re-stamped both conditions and re-queued itself through its
// own watch event, a hot loop running the device checks every ~2 s).
func upsertCondition(conds []metav1.Condition, c metav1.Condition) []metav1.Condition {
	for i := range conds {
		if conds[i].Type == c.Type {
			if conds[i].Status == c.Status {
				c.LastTransitionTime = conds[i].LastTransitionTime
			}
			conds[i] = c
			return conds
		}
	}
	return append(conds, c)
}

func newCondition(typ, reason, message string, status metav1.ConditionStatus, gen int64) metav1.Condition {
	return metav1.Condition{
		Type:               typ,
		Status:             status,
		ObservedGeneration: gen,
		LastTransitionTime: metav1.NewTime(nowFunc()),
		Reason:             reason,
		Message:            message,
	}
}

// readyTrue is the Verified condition: every check passed and the data path
// passed at first activation.
func readyTrue(gen int64) metav1.Condition {
	return newCondition(ConditionReady, reasons.ReasonVerified,
		"applied on every attachment node, every check passes, data path verified", metav1.ConditionTrue, gen)
}

// setRefusal records ONE refusal as the Ready/Degraded pair and returns
// whether the controller may requeue on it (terminal refusals do not).
func setRefusal(st *v1alpha1.SRv6ServiceStatus, gen int64, ref *Refusal) bool {
	if ref == nil {
		return true
	}
	ready := newCondition(ConditionReady, ref.Reason, ref.Message, metav1.ConditionFalse, gen)
	degraded := newCondition(ConditionDegraded, ref.Reason, ref.Message, metav1.ConditionTrue, gen)
	st.Conditions = upsertCondition(st.Conditions, ready)
	st.Conditions = upsertCondition(st.Conditions, degraded)
	st.ObservedGeneration = gen
	return !ref.Terminal()
}

// setDriftObserved records a drift's check failure as an OBSERVED
// Ready=False/Degraded=True pair (quickstart Q6: "Ready turns False within one
// re-verification interval with a message naming the node and the failed
// check") while the controller repairs it by re-applying the idempotent ops.
// A drift is not a refusal: the caller proceeds with the repair, and the
// Verified write at the end of the reconcile replaces this pair.
func setDriftObserved(st *v1alpha1.SRv6ServiceStatus, gen int64, ref *Refusal) {
	if ref == nil {
		return
	}
	setRefusal(st, gen, ref)
}

// setFinalizing records the delete-in-progress condition naming the nodes not
// yet confirmed clean.
func setFinalizing(st *v1alpha1.SRv6ServiceStatus, gen int64, message string) {
	st.Conditions = upsertCondition(st.Conditions,
		newCondition(ConditionReady, reasons.ReasonFinalizing, message, metav1.ConditionFalse, gen))
	st.ObservedGeneration = gen
}

// setReadyTrue records the Verified Ready=True condition and clears Degraded.
func setReadyTrue(st *v1alpha1.SRv6ServiceStatus, gen int64) {
	cond := readyTrue(gen)
	st.Conditions = upsertCondition(st.Conditions, cond)
	st.Conditions = upsertCondition(st.Conditions,
		newCondition(ConditionDegraded, reasons.ReasonVerified, "no failures observed", metav1.ConditionFalse, gen))
	st.ObservedGeneration = gen
}

// setReadyOutcome records the Verified state plus everything the update, drift
// and reader stages diff against: the plan hashes, the applied spec, the
// correlation id, the active path and the claimed allocations. status.
// allocations is the contract's report of every claimed identifier
// (contracts/srv6service-crd.md §1, quickstart Q5) — without it the operator
// cannot trace a device identifier to its claim.
func setReadyOutcome(st *v1alpha1.SRv6ServiceStatus, gen int64, hashes map[string]string,
	applied *v1alpha1.SRv6ServiceSpec, corrID, activePath string, alloc *v1alpha1.Allocations) {
	setReadyTrue(st, gen)
	st.ConfigHashes = hashes
	st.AppliedSpec = applied
	st.CorrelationID = corrID
	st.ActivePath = activePath
	st.Allocations = alloc
}

// requeueFor turns a refusal into the reconcile result: terminal refusals do
// NOT requeue (T396 — the controller still re-evaluates on its resync via
// the informer and the 5-minute interval while Ready, or on spec/site
// change); non-terminal failures requeue with backoff.
func requeueFor(ref *Refusal) ctrlResult {
	if ref == nil || !ref.Terminal() {
		return ctrlResult{requeueAfter: failureBackoff}
	}
	return ctrlResult{}
}

// ctrlResult is a tiny seam so the requeue policy is table-testable without
// importing controller-runtime into every test assertion.
type ctrlResult struct {
	requeueAfter time.Duration
}
