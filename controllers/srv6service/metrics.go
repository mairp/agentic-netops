// SPDX-License-Identifier: Apache-2.0
// metrics.go — controller-emitted SRv6 service state (T558/T559).
//
// D33 (specs/004-srv6-service-requests/research.md): locator and SID state per
// node are emitted by the SRv6Service controller from its verify results, and
// the active-path gauge marks which spine leg a steered service's pin rides
// (steering is proven on the default profile —
// lab/profiles/sonic-vm/srv6-supported.yaml). The gauges register on the
// controller-runtime metrics Registry, which the pod serves on :8081 and
// Prometheus scrapes through the pod's prometheus.io/scrape annotations
// (deploy/agentic-netops/manifests/srv6-controller.yaml) — no extra exporter,
// and no device read outside the reconcile's own verify and path stages.
//
// Nothing here duplicates the verify/path verdicts: the gauges carry the same
// values the status write carries (Status.Nodes[].Verified, status.activePath),
// so an operator reading Prometheus reads what the CRD claims.
package srv6service

import (
	"github.com/prometheus/client_golang/prometheus"
	"sigs.k8s.io/controller-runtime/pkg/metrics"

	"github.com/mairp/agentic-netops/api/v1alpha1"
)

// The three gauges carry the reconcile's device-observed SRv6 state to
// Prometheus. Every series is keyed by service first, so several services on
// one site stay distinguishable; node/locator/sid/path/spine name the device
// object the value describes.
var (
	srv6LocatorState = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "agentic_netops_srv6_locator_state",
			Help: "Locator state per node from the SRv6Service controller's verify results: 1 when the node verified (its bootstrap-locator probe and per-node checks passed) in the last verify pass, 0 when it did not.",
		},
		[]string{"service", "namespace", "node", "locator"},
	)
	srv6SIDState = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "agentic_netops_srv6_sid_state",
			Help: "Service SID state per node from the SRv6Service controller's verify results: 1 when the node holding that SID verified in the last verify pass, 0 when it did not.",
		},
		[]string{"service", "namespace", "node", "sid"},
	)
	srv6ActivePath = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "agentic_netops_srv6_active_path",
			Help: "Which spine leg a steered service's pin rides, from the path stage's route-table observation: 1 under path=preferred when the pin's via names the preferred spine, 1 under path=alternate when it names any other known leg, and 0 under both when no known leg serves the pin (the SRv6PathDown alert watches path=preferred). Unsteered services emit no series.",
		},
		[]string{"service", "namespace", "node", "path", "spine"},
	)
)

func init() {
	metrics.Registry.MustRegister(srv6LocatorState, srv6SIDState, srv6ActivePath)
}

// recordSrv6Verify sets the locator and SID state gauges for one service from
// one verify pass. order is the plan's node order; locators maps each node to
// its bootstrap locator; sids maps each attachment node to its service SID
// (absent or empty for the nodes that hold none); statuses is what verifyPlan
// just recorded in Status.Nodes. Called after every verify pass — including
// the drift-repair re-verify — so the gauges always say what the newest pass
// saw, never what an earlier one saw.
func recordSrv6Verify(svc *v1alpha1.SRv6Service, order []string, locators, sids map[string]string, statuses []v1alpha1.NodeStatus) {
	verified := make(map[string]bool, len(statuses))
	for _, ns := range statuses {
		if ns.Verified {
			verified[ns.Node] = true
		}
	}
	for _, node := range order {
		loc, ok := locators[node]
		if !ok || loc == "" {
			continue
		}
		v := 0.0
		if verified[node] {
			v = 1
		}
		srv6LocatorState.WithLabelValues(svc.Name, svc.Namespace, node, loc).Set(v)
		if sid := sids[node]; sid != "" {
			srv6SIDState.WithLabelValues(svc.Name, svc.Namespace, node, sid).Set(v)
		}
	}
}

// recordSrv6ActivePath sets the active-path gauges from the path stage's
// observation. view is nil for an unsteered service: no pin exists, so no
// series is emitted (data-model §2 — activePath stays empty there). One series
// per known leg: the preferred spine under path=preferred, any other leg under
// path=alternate; a series is 1 only when activePath names that spine. The
// observation is recorded BEFORE the stage's refusal is raised, so a pin with
// no serving leg writes 0 under both labels and the SRv6PathDown alert
// (deploy/observability/rules/agentic-netops.rules.yaml) sees it.
func recordSrv6ActivePath(svc *v1alpha1.SRv6Service, view *pathView, activePath string) {
	if view == nil {
		return
	}
	preferred := svc.Spec.Path.PreferredSpine
	alternate := svc.Spec.Path.AlternateSpine
	if alternate == "" {
		// A site may declare more legs than the spec names; the alternate
		// series describes whichever known leg is not the preferred one.
		for spine := range view.Legs {
			if spine != preferred {
				alternate = spine
				break
			}
		}
	}
	for _, leg := range []struct{ spine, path string }{
		{spine: preferred, path: "preferred"},
		{spine: alternate, path: "alternate"},
	} {
		if leg.spine == "" {
			continue
		}
		v := 0.0
		if activePath != "" && activePath == leg.spine {
			v = 1
		}
		srv6ActivePath.WithLabelValues(svc.Name, svc.Namespace, view.Node, leg.path, leg.spine).Set(v)
	}
}

// clearSrv6Metrics drops every series of one service and returns how many
// series were deleted. The delete path calls it so a removed service stops
// claiming locator, SID and path state in Prometheus; gauges without this
// cleanup would keep a deleted service's last value forever (and its
// active-path series would keep the alert green or red about a service that no
// longer exists).
func clearSrv6Metrics(svc *v1alpha1.SRv6Service) int {
	match := prometheus.Labels{"service": svc.Name, "namespace": svc.Namespace}
	return srv6LocatorState.DeletePartialMatch(match) +
		srv6SIDState.DeletePartialMatch(match) +
		srv6ActivePath.DeletePartialMatch(match)
}
