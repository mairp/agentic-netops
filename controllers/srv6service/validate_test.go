// SPDX-License-Identifier: Apache-2.0
//
// Site-validation tests, T360/T362/T364 (rules C1-C3) and T608 (rule C8).
// C1-C3 are checked BEFORE anything is claimed, so a refused attachment
// leaves zero claims and zero device writes:
//
//   - C1: every attachment node is a leaf of the fabric;
//   - C2: every attachment port resolves in the site port map;
//   - C3: preferred and alternate spines are spines of the fabric;
//   - C8: every attachment has a registered probe host in the capability
//     record — otherwise the data path could never be verified, so the
//     refusal (DataPathUnverifiable) lists the attachments that CAN be
//     verified, still before any claim.
package srv6service

import (
	"strings"
	"testing"

	agenticnetopsv1alpha1 "github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/reasons"
)

// attachmentTo mutates the first attachment's node.
func attachmentTo(svc *agenticnetopsv1alpha1.SRv6Service, node string) {
	svc.Spec.Attachments[0].Node = node
}

// portTo mutates the first attachment's port.
func portTo(svc *agenticnetopsv1alpha1.SRv6Service, port string) {
	svc.Spec.Attachments[0].Port = port
}

// refusalOf runs validateSite and requires a refusal with the given reason.
func refusalOf(t *testing.T, svc *agenticnetopsv1alpha1.SRv6Service, reason string) *Refusal {
	t.Helper()
	ref := validateSite(svc, DefaultSiteFacts())
	if ref == nil {
		t.Fatalf("validateSite accepted %+v, want a %s refusal", svc.Spec, reason)
	}
	if ref.Reason != reason {
		t.Fatalf("refusal reason = %q (%s), want %q", ref.Reason, ref.Message, reason)
	}
	if !ref.Terminal() {
		t.Errorf("site refusal %q must be terminal", ref.Reason)
	}
	return ref
}

// TestC1AttachmentNodesMustBeLeaves is T360: a spine — or a node the fabric
// does not know at all — is refused with the site's valid nodes/leaves named.
func TestC1AttachmentNodesMustBeLeaves(t *testing.T) {
	svc := testService("c1-spine", "c1-1")
	attachmentTo(svc, "spine01")
	ref := refusalOf(t, svc, reasons.ReasonInvalidSite)
	for _, want := range []string{"spine01", "not a leaf", "leaf01", "leaf02"} {
		if !strings.Contains(ref.Message, want) {
			t.Errorf("C1 message %q must name %q", ref.Message, want)
		}
	}

	unknown := testService("c1-unknown", "c1-2")
	attachmentTo(unknown, "leaf99")
	ref = refusalOf(t, unknown, reasons.ReasonInvalidSite)
	for _, want := range []string{"leaf99", "not a node of the fabric", "spine01", "spine02"} {
		if !strings.Contains(ref.Message, want) {
			t.Errorf("C1 message %q must name %q", ref.Message, want)
		}
	}

	// A valid service still passes C1-C3: the refusal is the attachment's,
	// not the site's.
	if ref := validateSite(testService("c1-ok", "c1-3"), DefaultSiteFacts()); ref != nil {
		t.Fatalf("valid service refused: %s", ref.Message)
	}
}

// TestC2AttachmentPortsResolve is T362: a port outside the site port map is
// refused with the valid ports named.
func TestC2AttachmentPortsResolve(t *testing.T) {
	svc := testService("c2-port", "c2-1")
	portTo(svc, "sriov3")
	ref := refusalOf(t, svc, reasons.ReasonInvalidSite)
	for _, want := range []string{"sriov3", "does not resolve in the site port map", "wan1"} {
		if !strings.Contains(ref.Message, want) {
			t.Errorf("C2 message %q must name %q", ref.Message, want)
		}
	}
	// The site port map knows exactly the access ports of the leaves.
	if ports := DefaultSiteFacts().ValidPorts(); len(ports) == 0 || ports[0] != "wan1" {
		t.Errorf("ValidPorts() = %v, want [wan1] (the mapped access port)", ports)
	}
}

// TestC3SpinesMustBeSpines is T364: preferred and alternate spines must be
// spines of the fabric; a leaf named there is refused with the valid spines.
func TestC3SpinesMustBeSpines(t *testing.T) {
	for _, mutate := range []func(*agenticnetopsv1alpha1.SRv6Service){
		func(s *agenticnetopsv1alpha1.SRv6Service) { s.Spec.Path.PreferredSpine = "leaf01" },
		func(s *agenticnetopsv1alpha1.SRv6Service) { s.Spec.Path.AlternateSpine = "leaf02" },
	} {
		svc := testService("c3-spine", "c3-1")
		mutate(svc)
		ref := refusalOf(t, svc, reasons.ReasonInvalidSite)
		for _, want := range []string{"not a spine of the fabric", "spine01", "spine02"} {
			if !strings.Contains(ref.Message, want) {
				t.Errorf("C3 message %q must name %q", ref.Message, want)
			}
		}
	}
	if ref := validateSite(testService("c3-ok", "c3-2"), DefaultSiteFacts()); ref != nil {
		t.Fatalf("steered service with both spines valid is refused: %s", ref.Message)
	}
}

// TestC8EveryAttachmentNeedsAProbeHost is T608: an attachment without a
// registered probe host is refused DataPathUnverifiable — the refusal names
// the missing attachment AND the verifiable ones — and the pipeline stops
// before ANY claim and ANY device write.
func TestC8EveryAttachmentNeedsAProbeHost(t *testing.T) {
	// Unit level: a record that registers only leaf02/wan1.
	cap := &Capability{
		Found:            true,
		SAISRV6:          true,
		Supported:        []string{"ip-vrf/vpn", "steering"},
		ProbeAttachments: []string{"leaf02/wan1"},
	}
	svc := testService("c8-probe", "c8-1")
	ref := checkCapability(svc, cap)
	if ref == nil {
		t.Fatal("checkCapability accepted an attachment with no probe host, want DataPathUnverifiable")
	}
	if ref.Reason != reasons.ReasonDataPathUnverifiable {
		t.Fatalf("refusal reason = %q, want %q", ref.Reason, reasons.ReasonDataPathUnverifiable)
	}
	if !ref.Terminal() {
		t.Error("DataPathUnverifiable must be terminal (the data path could never be verified)")
	}
	for _, want := range []string{"leaf01/wan1", "verifiable attachments: leaf02/wan1"} {
		if !strings.Contains(ref.Message, want) {
			t.Errorf("C8 message %q must name %q", ref.Message, want)
		}
	}
	// Both registered: no refusal.
	cap.ProbeAttachments = []string{"leaf01/wan1", "leaf02/wan1"}
	if ref := checkCapability(svc, cap); ref != nil {
		t.Fatalf("both probe hosts registered: %s", ref.Message)
	}

	// Pipeline level: a record without srv6-probe-attachments refuses the
	// whole request at C8 — zero claims, zero device writes.
	const name = "c8-no-probe"
	c := newTestClient(t, testService(name, "c8-no-probe"))
	testClaims(t, c, "c8-no-probe")
	pins := goodPins()
	delete(pins.Data, KeyProbeAttachments)
	ex := &recordingExecutor{}
	got := convergeService(t, c, ex, pins, name)
	cond := readyCondition(&got.Status)
	if cond == nil || cond.Reason != reasons.ReasonDataPathUnverifiable {
		t.Fatalf("Ready reason = %+v, want %s", cond, reasons.ReasonDataPathUnverifiable)
	}
	if n := countClaims(t, c); n != 3 {
		t.Errorf("C8 refusal left %d claims, want the 3 pre-created ones untouched (nothing new claimed)", n)
	}
	if got.Status.Allocations != nil {
		t.Error("status.allocations recorded despite the C8 refusal; nothing may be claimed")
	}
	assertNoDeviceWrites(t, ex)
}

// assertNoDeviceWrites requires the executor to have seen nothing at all —
// the structural proof that the pipeline stopped before the apply stage.
func assertNoDeviceWrites(t *testing.T, ex *recordingExecutor) {
	t.Helper()
	if calls := ex.applyCalls(); len(calls) != 0 {
		t.Errorf("executor saw %d apply calls after a pre-claim refusal; the first must be at apply", len(calls))
	}
	if n := ex.verifyCount(); n != 0 {
		t.Errorf("executor saw %d verify calls after a pre-claim refusal", n)
	}
}

// TestSiteRefusalLeavesNothingBehind pins the C1-C3 order property end to
// end: a service whose attachment names a spine never claims and never
// reaches the executor.
func TestSiteRefusalLeavesNothingBehind(t *testing.T) {
	const name = "c1-live"
	svc := testService(name, "c1-live")
	attachmentTo(svc, "spine01")
	c := newTestClient(t, svc)
	testClaims(t, c, "c1-live")
	ex := &recordingExecutor{}
	got := convergeService(t, c, ex, goodPins(), name)
	cond := readyCondition(&got.Status)
	if cond == nil || cond.Reason != reasons.ReasonInvalidSite {
		t.Fatalf("Ready reason = %+v, want %s", cond, reasons.ReasonInvalidSite)
	}
	if got.Status.Allocations != nil {
		t.Error("claims were recorded for a service refused at C1")
	}
	if n := countClaims(t, c); n != 3 {
		t.Errorf("C1 refusal left %d claims, want the 3 pre-created ones untouched", n)
	}
	assertNoDeviceWrites(t, ex)
	if cond.ObservedGeneration != got.Generation {
		t.Errorf("observedGeneration = %d, want the object's %d", cond.ObservedGeneration, got.Generation)
	}
}
