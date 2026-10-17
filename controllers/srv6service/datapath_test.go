// SPDX-License-Identifier: Apache-2.0
//
// Data-path tests, T386 (datapath.go): the probe-ping client-to-client check
// is built from the claimed prefixes (client at .2, 8900-byte DF payload,
// count 3), a passing probe stamps status.dataPath.checkedAt + result "pass"
// through the nowFunc clock seam, a failed probe is the NON-TERMINAL
// DataPathFailed, the probe runs once at first activation only, and a
// missing probe host never reaches this stage at all — rule C8 refuses the
// request before any claim, so the executor sees zero calls.
package srv6service

import (
	"context"
	"strings"
	"testing"
	"time"

	agenticnetopsv1alpha1 "github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/executorclient"
	"github.com/mairp/agentic-netops/pkg/fabricplan"
	"github.com/mairp/agentic-netops/pkg/reasons"
	ctrl "sigs.k8s.io/controller-runtime"
)

// pinClock pins the package clock seam for the test's duration.
func pinClock(t *testing.T, at time.Time) {
	t.Helper()
	prev := nowFunc
	nowFunc = func() time.Time { return at }
	t.Cleanup(func() { nowFunc = prev })
}

// isProbeCall reports whether an executor Verify call carried the probe.
func isProbeCall(checks []fabricplan.Check) bool {
	return len(checks) > 0 && checks[0].Type == "probe-ping"
}

// TestProbeCheckShapeAndPassStampsCheckedAt is T386's shape + stamp half.
func TestProbeCheckShapeAndPassStampsCheckedAt(t *testing.T) {
	svc := testService("probe-shape", "probe-shape-1")
	alloc := testAllocation(t, svc)

	chk, err := dataPathCheck(svc, alloc)
	if err != nil {
		t.Fatalf("dataPathCheck: %v", err)
	}
	if chk.Type != "probe-ping" || chk.ProbeFrom != "leaf01/wan1" || chk.ProbeTo != "leaf02/wan1" {
		t.Errorf("probe = %+v, want leaf01/wan1 -> leaf02/wan1", chk)
	}
	// The peer client container sits at .2 of leaf02's claimed /24.
	if chk.Addr != "192.168.36.2" || chk.Size != 8900 || chk.Count != 3 {
		t.Errorf("probe addr/size/count = %s/%d/%d, want 192.168.36.2/8900/3", chk.Addr, chk.Size, chk.Count)
	}

	// A passing probe reports pass with the recipe detail.
	ex := &recordingExecutor{}
	ok, detail, derr := runDataPath(context.Background(), ex, svc, alloc)
	if !ok || derr != nil {
		t.Fatalf("runDataPath = (%v, %v), want pass", ok, derr)
	}
	for _, want := range []string{"leaf01/wan1", "192.168.36.2", "8900 bytes x3", "pass"} {
		if !strings.Contains(detail, want) {
			t.Errorf("detail %q must name %q", detail, want)
		}
	}
	// The probe went to the FIRST attachment's node.
	if calls := ex.verifyCount(); calls != 1 {
		t.Errorf("probe verify calls = %d, want 1", calls)
	}

	// The stamp goes through the clock seam: CheckedAt is the pinned now,
	// Result is "pass".
	pinned := time.Date(2026, 10, 17, 6, 30, 0, 0, time.UTC)
	pinClock(t, pinned)
	st := &agenticnetopsv1alpha1.SRv6ServiceStatus{}
	setDataPathPassed(st)
	if st.DataPath == nil || !st.DataPath.CheckedAt.Time.Equal(pinned) || st.DataPath.Result != "pass" {
		t.Errorf("status.dataPath = %+v, want checkedAt %v and result \"pass\"", st.DataPath, pinned)
	}
	if !dataPathPassed(&agenticnetopsv1alpha1.SRv6Service{Status: *st}) {
		t.Error("dataPathPassed = false after the stamp")
	}
	// Until the probe has passed, checkedAt is zero and the stage re-runs.
	if dataPathPassed(testService("probe-fresh", "probe-fresh-1")) {
		t.Error("dataPathPassed = true for a service never probed")
	}
}

// TestProbeFailureIsNonTerminalDataPathFailed is T386's failure half.
func TestProbeFailureIsNonTerminalDataPathFailed(t *testing.T) {
	svc := testService("probe-fail", "probe-fail-1")
	alloc := testAllocation(t, svc)

	// A failed ping (echoes missing) is a traffic verdict, not an error.
	ex := &recordingExecutor{}
	ex.verifyFn = func(node string, checks []fabricplan.Check, nth int) (res *executorclient.VerifyResult) {
		return verifyScripted(node, checks, false, "0 of 3 echoes", "")
	}
	ok, detail, derr := runDataPath(context.Background(), ex, svc, alloc)
	if ok || derr != nil {
		t.Fatalf("runDataPath = (%v, %v), want a failed verdict without transport error", ok, derr)
	}
	if !strings.Contains(detail, "probe leaf01/wan1 -> 192.168.36.2 failed") ||
		!strings.Contains(detail, "0 of 3 echoes") {
		t.Errorf("detail %q must name the probe and the verdict", detail)
	}
	ref := dataPathRefusal(detail)
	if ref.Reason != reasons.ReasonDataPathFailed {
		t.Errorf("refusal reason = %q, want %q", ref.Reason, reasons.ReasonDataPathFailed)
	}
	if ref.Terminal() {
		t.Error("DataPathFailed must be non-terminal (retried on the failure backoff)")
	}

	// Pipeline level: the plan checks verify fine, the probe fails; the
	// service settles in DataPathFailed with NO checkedAt stamp.
	const name = "probe-fail-live"
	c := newTestClient(t, testService(name, "probe-fail-live"))
	testClaims(t, c, "probe-fail-live")
	ex2 := &recordingExecutor{}
	ex2.verifyFn = func(node string, checks []fabricplan.Check, nth int) *executorclient.VerifyResult {
		if isProbeCall(checks) {
			return verifyScripted(node, checks, false, "no echoes received", "")
		}
		return verifyAllOK(node, checks)
	}
	got := convergeService(t, c, ex2, goodPins(), name)
	cond := readyCondition(&got.Status)
	if cond == nil || cond.Reason != reasons.ReasonDataPathFailed {
		t.Fatalf("Ready reason = %+v, want %s", cond, reasons.ReasonDataPathFailed)
	}
	if got.Status.DataPath != nil {
		t.Errorf("status.dataPath = %+v, want nil (the probe never passed)", got.Status.DataPath)
	}
	if !strings.Contains(cond.Message, "192.168.36.2") {
		t.Errorf("refusal message %q must name the probed address", cond.Message)
	}
}

// TestProbeRunsOnceAtFirstActivation is T386's once-only rule: after a
// passing probe every later reconcile skips the probe — verify still runs,
// the probe does not.
func TestProbeRunsOnceAtFirstActivation(t *testing.T) {
	const name = "probe-once"
	const corrID = "probe-once"
	c := newTestClient(t, testService(name, corrID))
	testClaims(t, c, corrID)
	pinned := time.Date(2026, 10, 17, 6, 31, 0, 0, time.UTC)
	pinClock(t, pinned)

	probes := 0
	ex := &recordingExecutor{}
	ex.verifyFn = func(node string, checks []fabricplan.Check, nth int) *executorclient.VerifyResult {
		if isProbeCall(checks) {
			probes++
		}
		return verifyAllOK(node, checks)
	}
	got := convergeService(t, c, ex, goodPins(), name)
	cond := readyCondition(&got.Status)
	if cond == nil || cond.Status != "True" {
		t.Fatalf("service did not converge Ready: %+v", cond)
	}
	if probes != 1 {
		t.Fatalf("probe ran %d times on the way to Ready, want exactly 1", probes)
	}
	if got.Status.DataPath == nil || !got.Status.DataPath.CheckedAt.Time.Equal(pinned) {
		t.Fatalf("status.dataPath.checkedAt = %+v, want the pinned %v", got.Status.DataPath, pinned)
	}

	// A later reconcile: verify still runs, the probe does not, and the
	// stamp (and Ready) survive.
	before := ex.verifyCount()
	if _, err := testReconciler(t, c, ex, goodPins()).Reconcile(context.Background(),
		ctrl.Request{NamespacedName: testKey(name)}); err != nil {
		t.Fatalf("steady-state reconcile: %v", err)
	}
	if probes != 1 {
		t.Errorf("probe ran %d times after first activation, want still 1", probes)
	}
	if ex.verifyCount() == before {
		t.Error("steady-state reconcile skipped verify; only the probe must be skipped")
	}
	var again agenticnetopsv1alpha1.SRv6Service
	if err := c.Get(context.Background(), testKey(name), &again); err != nil {
		t.Fatalf("get: %v", err)
	}
	if again.Status.DataPath == nil || !again.Status.DataPath.CheckedAt.Time.Equal(pinned) {
		t.Errorf("checkedAt drifted to %+v, want the pinned %v kept", again.Status.DataPath, pinned)
	}
	if cond := readyCondition(&again.Status); cond == nil || cond.Status != "True" {
		t.Errorf("Ready after the steady-state reconcile = %+v, want True", cond)
	}
}

// TestMissingProbeHostNeverReachesDataPath is T386's structural half: with
// no probe host registered, rule C8 refuses the request before any claim and
// before any device work — the executor sees zero calls of any kind.
func TestMissingProbeHostNeverReachesDataPath(t *testing.T) {
	const name = "probe-noc8"
	pins := goodPins()
	delete(pins.Data, KeyProbeAttachments)

	ex := &recordingExecutor{}
	got := convergeService(t, newTestClient(t, testService(name, name)), ex, pins, name)
	cond := readyCondition(&got.Status)
	if cond == nil || cond.Reason != reasons.ReasonDataPathUnverifiable {
		t.Fatalf("Ready reason = %+v, want %s", cond, reasons.ReasonDataPathUnverifiable)
	}
	for _, want := range []string{"no probe host registered", "leaf01/wan1"} {
		if !strings.Contains(cond.Message, want) {
			t.Errorf("message %q must name %q", cond.Message, want)
		}
	}
	if calls := ex.applyCalls(); len(calls) != 0 {
		t.Errorf("executor saw %d apply calls; C8 must refuse before any device work", len(calls))
	}
	if ex.verifyCount() != 0 {
		t.Errorf("executor saw %d verify calls; the probe must never be attempted", ex.verifyCount())
	}
}
