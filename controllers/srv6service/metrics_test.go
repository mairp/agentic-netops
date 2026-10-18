// SPDX-License-Identifier: Apache-2.0
// metrics_test.go — T558/T559 unit tests for the controller-emitted SRv6
// state gauges. The gauges are package-level and registered on the
// controller-runtime metrics Registry (that is how the pod's :8081 /metrics
// serves them), so the tests read the same registered children and clean up
// after themselves: a label set left behind here would leak into another
// test's read.
package srv6service

import (
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"

	"github.com/mairp/agentic-netops/api/v1alpha1"
)

// gaugeValue reads the current value of one labeled child of a GaugeVec.
func gaugeValue(t *testing.T, vec *prometheus.GaugeVec, labels prometheus.Labels) (float64, bool) {
	t.Helper()
	g, err := vec.GetMetricWith(labels)
	if err != nil {
		t.Fatalf("child %v: %v", labels, err)
	}
	var m dto.Metric
	if err := g.Write(&m); err != nil {
		t.Fatalf("write metric: %v", err)
	}
	return m.GetGauge().GetValue(), true
}

func TestRecordSrv6VerifySetsLocatorAndSIDState(t *testing.T) {
	svc := &v1alpha1.SRv6Service{}
	svc.Name = "srv6-vpn"
	svc.Namespace = "agentic-netops-intent"
	order := []string{"leaf01", "leaf02"}
	locators := map[string]string{
		"leaf01": "fcbb:bbbb:1::/48",
		"leaf02": "fcbb:bbbb:2::/48",
	}
	sids := map[string]string{
		"leaf01": "fcbb:bbbb:1:11::/64",
		"leaf02": "fcbb:bbbb:2:11::/64",
	}
	statuses := []v1alpha1.NodeStatus{
		{Node: "leaf01", Verified: true},
		{Node: "leaf02", Verified: false, FailedCheck: "sid-present"},
	}
	t.Cleanup(func() { clearSrv6Metrics(svc) })

	recordSrv6Verify(svc, order, locators, sids, statuses)

	if v, _ := gaugeValue(t, srv6LocatorState, prometheus.Labels{
		"service": "srv6-vpn", "namespace": "agentic-netops-intent",
		"node": "leaf01", "locator": "fcbb:bbbb:1::/48"}); v != 1 {
		t.Fatalf("leaf01 locator state = %v, want 1 (node verified)", v)
	}
	if v, _ := gaugeValue(t, srv6SIDState, prometheus.Labels{
		"service": "srv6-vpn", "namespace": "agentic-netops-intent",
		"node": "leaf01", "sid": "fcbb:bbbb:1:11::/64"}); v != 1 {
		t.Fatalf("leaf01 sid state = %v, want 1 (node verified)", v)
	}
	if v, _ := gaugeValue(t, srv6LocatorState, prometheus.Labels{
		"service": "srv6-vpn", "namespace": "agentic-netops-intent",
		"node": "leaf02", "locator": "fcbb:bbbb:2::/48"}); v != 0 {
		t.Fatalf("leaf02 locator state = %v, want 0 (node failed its checks)", v)
	}
	if v, _ := gaugeValue(t, srv6SIDState, prometheus.Labels{
		"service": "srv6-vpn", "namespace": "agentic-netops-intent",
		"node": "leaf02", "sid": "fcbb:bbbb:2:11::/64"}); v != 0 {
		t.Fatalf("leaf02 sid state = %v, want 0 (node failed its checks)", v)
	}

	// The next pass replaces the previous verdicts: the gauges say what the
	// newest verify saw, not what any earlier pass saw.
	statuses[1].Verified = true
	recordSrv6Verify(svc, order, locators, sids, statuses)
	if v, _ := gaugeValue(t, srv6LocatorState, prometheus.Labels{
		"service": "srv6-vpn", "namespace": "agentic-netops-intent",
		"node": "leaf02", "locator": "fcbb:bbbb:2::/48"}); v != 1 {
		t.Fatalf("leaf02 locator state after re-verify = %v, want 1", v)
	}
}

func TestRecordSrv6ActivePathPrefersPreferredSpine(t *testing.T) {
	svc := &v1alpha1.SRv6Service{}
	svc.Name = "srv6-steered"
	svc.Namespace = "agentic-netops-intent"
	svc.Spec.Path.PreferredSpine = "spine01"
	svc.Spec.Path.AlternateSpine = "spine02"
	view := &pathView{
		Node:   "leaf01",
		PeerFn: "fcbb:bbbb:2:11::",
		Legs:   map[string]string{"spine01": "2001:db8:ff::1", "spine02": "2001:db8:ff::2"},
	}
	base := prometheus.Labels{"service": "srv6-steered", "namespace": "agentic-netops-intent", "node": "leaf01"}
	t.Cleanup(func() { clearSrv6Metrics(svc) })

	recordSrv6ActivePath(svc, view, "spine01")
	if v, _ := gaugeValue(t, srv6ActivePath, withPath(base, "preferred", "spine01")); v != 1 {
		t.Fatalf("preferred series = %v, want 1 (pin rides spine01)", v)
	}
	if v, _ := gaugeValue(t, srv6ActivePath, withPath(base, "alternate", "spine02")); v != 0 {
		t.Fatalf("alternate series = %v, want 0 while the pin rides spine01", v)
	}

	// Failover: the pin moved to the other spine. Preferred reads 0 (the
	// SRv6PathDown condition), alternate reads 1.
	recordSrv6ActivePath(svc, view, "spine02")
	if v, _ := gaugeValue(t, srv6ActivePath, withPath(base, "preferred", "spine01")); v != 0 {
		t.Fatalf("preferred series = %v, want 0 after failover to spine02", v)
	}
	if v, _ := gaugeValue(t, srv6ActivePath, withPath(base, "alternate", "spine02")); v != 1 {
		t.Fatalf("alternate series = %v, want 1 after failover to spine02", v)
	}

	// No known leg serves the pin: both read 0 — the condition the
	// SRv6PathDown alert fires on.
	recordSrv6ActivePath(svc, view, "")
	if v, _ := gaugeValue(t, srv6ActivePath, withPath(base, "preferred", "spine01")); v != 0 {
		t.Fatalf("preferred series = %v, want 0 with no serving leg", v)
	}
	if v, _ := gaugeValue(t, srv6ActivePath, withPath(base, "alternate", "spine02")); v != 0 {
		t.Fatalf("alternate series = %v, want 0 with no serving leg", v)
	}
}

func TestRecordSrv6ActivePathDerivesAlternateWhenUnspecified(t *testing.T) {
	svc := &v1alpha1.SRv6Service{}
	svc.Name = "srv6-steered-noalt"
	svc.Namespace = "agentic-netops-intent"
	svc.Spec.Path.PreferredSpine = "spine01"
	view := &pathView{
		Node: "leaf01",
		Legs: map[string]string{"spine01": "2001:db8:ff::1", "spine02": "2001:db8:ff::2"},
	}
	base := prometheus.Labels{"service": "srv6-steered-noalt", "namespace": "agentic-netops-intent", "node": "leaf01"}
	t.Cleanup(func() { clearSrv6Metrics(svc) })

	recordSrv6ActivePath(svc, view, "spine02")
	if v, _ := gaugeValue(t, srv6ActivePath, withPath(base, "alternate", "spine02")); v != 1 {
		t.Fatalf("derived alternate series = %v, want 1 (the known leg that is not preferred)", v)
	}
}

func TestRecordSrv6ActivePathEmitsNothingForUnsteeredService(t *testing.T) {
	svc := &v1alpha1.SRv6Service{}
	svc.Name = "srv6-unsteered"
	svc.Namespace = "agentic-netops-intent"

	// view == nil is the unsteered case (steeredPathView returned nil): the
	// gauge helper must not fabricate a path series for a service with no
	// pin. A read on an uncreated child would CREATE it, so the count of
	// deletions is the honest probe: deleting an unsteered service's series
	// finds none.
	recordSrv6ActivePath(svc, nil, "spine01")
	if got := clearSrv6Metrics(svc); got != 0 {
		t.Fatalf("unsteered service emitted %d series, want 0", got)
	}
}

// withPath copies the common label set and adds the path/spine pair.
func withPath(base prometheus.Labels, path, spine string) prometheus.Labels {
	labels := prometheus.Labels{}
	for k, v := range base {
		labels[k] = v
	}
	labels["path"] = path
	labels["spine"] = spine
	return labels
}
