// SPDX-License-Identifier: Apache-2.0
//
// Path stage tests (T520, plan 10-05): `status.activePath` names the spine in
// use — read off the pin's via address on the ingress leaf (data-model §8.6:
// "preferred" is the pin's via address), never echoed from the spec — and a
// steered service whose pin is gone from every leg refuses `PathDown` naming
// the missing path (data-model §6). The observation is a READ-ONLY command
// check: it never asserts, it only carries the observed route table back.

package srv6service

import (
	"context"
	"strings"
	"testing"

	"github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/executorclient"
	"github.com/mairp/agentic-netops/pkg/fabricplan"
	"github.com/mairp/agentic-netops/pkg/reasons"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// pathLegs is the ingress leaf's spine-leg address table (the shape
// facts.SpineLinks[node] arrives in): two spines, one leg address each.
var pathLegs = map[string]string{
	"spine01": "2001:db8:1::3",
	"spine02": "2001:db8:2::3",
}

func pathTestView() *pathView {
	return &pathView{Node: "leaf01", PeerFn: "fcbb:bbbb:4:11::", Legs: pathLegs}
}

// pathRouteTable is an ingress leaf's `ip -6 route show` slice: the /48 pin,
// the decap route, the VRF client route — plus the per-service pin when one
// is on the device (data-model §8.4/§8.6 read-back shapes, receipt-literal
// spacing).
func pathRouteTable(pin string) string {
	table := "fcbb:bbbb:3::/48 via 2001:db8:1::3 dev Ethernet0 metric 5\n" +
		"fcbb:bbbb:3:11::  encap seg6local action End.DT46 vrftable 1001 dev Vrf1 metric 1024 pref medium\n" +
		"192.168.2.0/24 dev Vrf1 metric 1024\n"
	if pin != "" {
		table += pin + "\n"
	}
	return table
}

func pathRouteAnswer(pin string) func(string, []fabricplan.Check) *executorclient.VerifyResult {
	return func(node string, checks []fabricplan.Check) *executorclient.VerifyResult {
		res := &executorclient.VerifyResult{Node: node, OK: true}
		for range checks {
			res.Results = append(res.Results, struct {
				Check  string `json:"check"`
				OK     bool   `json:"ok"`
				Actual string `json:"actual,omitempty"`
				Error  string `json:"error,omitempty"`
			}{Check: "checks[0].command", OK: true, Actual: pathRouteTable(pin)})
		}
		return res
	}
}

func TestPathObservationReadsThePinViaAddress(t *testing.T) {
	ex := &fakeExecutor{answer: pathRouteAnswer(
		"fcbb:bbbb:4:11:: from :: via 2001:db8:1::3 dev Ethernet0 metric 20")}
	obs, err := observePath(context.Background(), ex, *pathTestView())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if obs.Down {
		t.Fatalf("observation = down, want the preferred spine")
	}
	if obs.Active != "spine01" {
		t.Fatalf("active = %q, want spine01 (the pin's via address)", obs.Active)
	}
	if obs.Via != "2001:db8:1::3" {
		t.Fatalf("via = %q, want 2001:db8:1::3", obs.Via)
	}
	// The read is exactly one READ-ONLY check: a command check against the
	// route table with an EMPTY Expect — it never asserts, it only carries
	// the observed output back.
	if len(ex.verified) != 1 {
		t.Fatalf("verify calls = %d, want exactly one read", len(ex.verified))
	}
	ck := ex.verified[0]
	if ck.Type != "command" || ck.Command != "ip -6 route show" {
		t.Fatalf("read = %+v, want the read-only `ip -6 route show` command check", ck)
	}
	if ck.Expect != "" {
		t.Fatalf("expect = %q, want empty (the observation never asserts)", ck.Expect)
	}
}

func TestPathObservationNamesTheAlternateWhenThePinMoved(t *testing.T) {
	// The failure action re-points the pin via the alternate spine's link
	// address (contract §3.2): the observation must name spine02 — the
	// device, not the spec's preferred spine.
	ex := &fakeExecutor{answer: pathRouteAnswer(
		"fcbb:bbbb:4:11:: from :: via 2001:db8:2::3 dev Ethernet0 metric 20")}
	obs, err := observePath(context.Background(), ex, *pathTestView())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if obs.Down || obs.Active != "spine02" || obs.Via != "2001:db8:2::3" {
		t.Fatalf("observation = %+v, want spine02 via 2001:db8:2::3", obs)
	}
}

func TestPathObservationIsDownWithoutAPin(t *testing.T) {
	// No pin line at all: neither path is usable.
	ex := &fakeExecutor{answer: pathRouteAnswer("")}
	obs, err := observePath(context.Background(), ex, *pathTestView())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !obs.Down {
		t.Fatalf("observation = %+v, want down with no pin on the device", obs)
	}
	if obs.Active != "" {
		t.Fatalf("active = %q, want empty while down", obs.Active)
	}
}

func TestPathObservationIsDownOnAnUnknownVia(t *testing.T) {
	// A pin whose via address matches no leg of this node serves no known
	// path: the service's two paths are still both absent.
	ex := &fakeExecutor{answer: pathRouteAnswer(
		"fcbb:bbbb:4:11:: from :: via 2001:db8:9::9 dev Ethernet0 metric 20")}
	obs, err := observePath(context.Background(), ex, *pathTestView())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !obs.Down {
		t.Fatalf("observation = %+v, want down when the via matches no known leg", obs)
	}
}

func TestPathRefusalNamesTheMissingPath(t *testing.T) {
	view := pathTestView()
	ref := pathDownRefusal(*view, pathObservation{Down: true})
	if ref == nil {
		t.Fatalf("refusal = nil, want PathDown")
	}
	if ref.Reason != reasons.ReasonPathDown {
		t.Fatalf("reason = %q, want %q", ref.Reason, reasons.ReasonPathDown)
	}
	if ref.Kind != refusalPath {
		t.Fatalf("kind = %v, want refusalPath", ref.Kind)
	}
	if ref.Terminal() {
		t.Fatalf("PathDown must be retryable (data-model §6: terminal = no)")
	}
	// The message names the node and BOTH missing paths (the §6 table: the
	// message names the node and the check where one applies).
	for _, want := range []string{"leaf01", "spine01", "spine02", "2001:db8:1::3", "2001:db8:2::3", view.PeerFn} {
		if !strings.Contains(ref.Message, want) {
			t.Errorf("message %q must name %q", ref.Message, want)
		}
	}
}

func TestSteerPathOutcomeDecidesFailoverNotDrift(t *testing.T) {
	// The pin rides the ALTERNATE while the spec still names spine01: the
	// plan's preferred-pin checks failing is the failover state (FR-026 —
	// traffic moves to the other spine), NOT drift — re-applying the plan
	// would re-install the preferred pin and undo the operator's switch.
	svc := &v1alpha1.SRv6Service{}
	svc.Spec.Path.PreferredSpine = "spine01"
	svc.Spec.Path.AlternateSpine = "spine02"
	vref := &Refusal{Reason: reasons.ReasonCheckFailed, Kind: refusalCheck,
		Message: "check command failed on node leaf01"}
	out := steerPathOutcome(svc, pathTestView(),
		pathObservation{Active: "spine02", Via: "2001:db8:2::3"}, vref)
	if out.Refusal != nil {
		t.Fatalf("refusal = %+v, want none while the alternate serves", out.Refusal)
	}
	if !out.SkipRepair {
		t.Fatalf("skipRepair = false, want true (the repair would undo the failover)")
	}
	if out.ActivePath != "spine02" {
		t.Fatalf("activePath = %q, want the device-observed spine02", out.ActivePath)
	}
}

func TestSteerPathOutcomeKeepsDriftRepairOnThePreferredPath(t *testing.T) {
	svc := &v1alpha1.SRv6Service{}
	svc.Spec.Path.PreferredSpine = "spine01"
	svc.Spec.Path.AlternateSpine = "spine02"
	vref := &Refusal{Reason: reasons.ReasonCheckFailed, Kind: refusalCheck,
		Message: "check command failed on node leaf01"}
	// The pin is exactly where the plan wants it: a failing check here is
	// ordinary drift and must stay repairable.
	out := steerPathOutcome(svc, pathTestView(),
		pathObservation{Active: "spine01", Via: "2001:db8:1::3"}, vref)
	if out.SkipRepair {
		t.Fatalf("skipRepair = true, want false for a drift on the preferred path")
	}
	if out.Refusal != nil || out.ActivePath != "spine01" {
		t.Fatalf("outcome = %+v, want spine01 and no refusal", out)
	}
}

func TestSteerPathOutcomeRefusesWhenBothPathsDown(t *testing.T) {
	svc := &v1alpha1.SRv6Service{}
	svc.Spec.Path.PreferredSpine = "spine01"
	svc.Spec.Path.AlternateSpine = "spine02"
	out := steerPathOutcome(svc, pathTestView(), pathObservation{Down: true}, nil)
	if out.Refusal == nil {
		t.Fatalf("refusal = nil, want PathDown with both paths down")
	}
	if out.Refusal.Reason != reasons.ReasonPathDown {
		t.Fatalf("reason = %q, want %q", out.Refusal.Reason, reasons.ReasonPathDown)
	}
	if out.SkipRepair {
		t.Fatalf("skipRepair = true, want false — PathDown is the answer, not a repair")
	}
}

func TestActivePathEmptyWhenNotSteered(t *testing.T) {
	// data-model §2: `status.activePath` is the spine carrying the service
	// and is EMPTY when not steered. An alternateSpine-only service renders
	// no pin (steering keys on the preferred spine), so there is no path to
	// name — the pre-US5 echo of the alternate name must be gone.
	svc := &v1alpha1.SRv6Service{}
	svc.Spec.Path.AlternateSpine = "spine02"
	if view := steeredPathView(svc, nil, nil, nil); view != nil {
		t.Fatalf("view = %+v, want nil for an unsteered service", view)
	}
	out := steerPathOutcome(svc, nil, pathObservation{}, nil)
	if out.ActivePath != "" {
		t.Fatalf("activePath = %q, want empty when not steered", out.ActivePath)
	}
	if out.Refusal != nil || out.SkipRepair {
		t.Fatalf("outcome = %+v, want a no-op for an unsteered service", out)
	}
}

func TestSteeredPathViewFindsTheIngressAndThePeerFunction(t *testing.T) {
	// The ingress leaf is the attachment node that sorts first (the renderer
	// pins exactly that node), the peer function is the OTHER attachment's
	// service SID without its /64, and the legs are the ingress node's own.
	svc := &v1alpha1.SRv6Service{}
	svc.Spec.Path.PreferredSpine = "spine01"
	svc.Spec.Attachments = []v1alpha1.Attachment{
		{Node: "leaf02"}, {Node: "leaf01"},
	}
	sids := map[string]string{
		"leaf01": "fcbb:bbbb:3:11::/64",
		"leaf02": "fcbb:bbbb:4:11::/64",
	}
	links := map[string]map[string]string{
		"leaf01": {"spine01": "2001:db8:1::3", "spine02": "2001:db8:2::3"},
		"leaf02": {"spine01": "2001:db8:1::5", "spine02": "2001:db8:2::5"},
	}
	view := steeredPathView(svc, []string{"leaf01", "leaf02"}, sids, links)
	if view == nil {
		t.Fatalf("view = nil, want the ingress view")
	}
	if view.Node != "leaf01" {
		t.Fatalf("node = %q, want leaf01 (the sorted-first attachment)", view.Node)
	}
	if view.PeerFn != "fcbb:bbbb:4:11::" {
		t.Fatalf("peerFn = %q, want the peer leaf02's function fcbb:bbbb:4:11::", view.PeerFn)
	}
	if len(view.Legs) != 2 || view.Legs["spine02"] != "2001:db8:2::3" {
		t.Fatalf("legs = %v, want leaf01's own two spine legs", view.Legs)
	}
}

func TestSteerPathOutcomeStillReadsTheDeviceWhenVerifyPassed(t *testing.T) {
	// A healthy steered service: verify passed, the pin is where the plan
	// wants it — activePath is the DEVICE answer (spine01), never a spec
	// echo of a service the device does not carry.
	svc := &v1alpha1.SRv6Service{}
	svc.Spec.Path.PreferredSpine = "spine01"
	svc.Spec.Path.AlternateSpine = "spine02"
	out := steerPathOutcome(svc, pathTestView(),
		pathObservation{Active: "spine01", Via: "2001:db8:1::3"}, nil)
	if out.ActivePath != "spine01" || out.Refusal != nil || out.SkipRepair {
		t.Fatalf("outcome = %+v, want plain spine01", out)
	}
}

// compile-time proof the decision reads the conditions the reconcile hands it
// (the Ready/Degraded pair is untouched here; the stage only produces its own
// refusal or clears the verify refusal).
var _ = metav1.Condition{}
