//go:build agentic_netops_k8s

// SPDX-License-Identifier: Apache-2.0
// srv6_sid_metrics_test.go — T560 unit tests for the kernel per-SID counter
// collector (fabric_executor_srv6_sid_packets_total). The tests inject a fake
// transport through vrfStatsSource (the same source the VRF collector uses),
// so no test opens a real connection. The contract under test: (a) the series
// carry the node, the SID prefix and the direction of the kernel counters the
// transport returned — read from `ip -s -6 route show`; (b) a seg6local route
// WITHOUT the plan's `count` flag contributes no series (counter off, not
// zero); (c) a failing node contributes NO series while the rest still
// scrape; (d) no FABRIC_NODE_MAP means no series at all.
package main

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
)

// sidScriptedTransport answers the collector's one command with canned
// stdout, and insists that command is exactly the route dump the parser is
// written against.
type sidScriptedTransport struct {
	stdout string
	err    error
}

func (s *sidScriptedTransport) run(_ context.Context, argv []string, _ []byte) (string, string, error) {
	if s.err != nil {
		return "", "", s.err
	}
	if len(argv) < 3 || (argv[0] != "sudo" && argv[0] != "bash") || argv[len(argv)-2] != "-c" {
		return "", "", errors.New("unexpected argv shape")
	}
	if argv[len(argv)-1] != srv6SIDCommand {
		return "", "", errors.New("command is not the per-route statistics dump")
	}
	return s.stdout, "", nil
}

func (s *sidScriptedTransport) kind() string { return "ssh" }

// routeDump is the recorded shape of `ip -s -6 route show` on a leaf with the
// steered service applied: the counted decap route, a seg6local route without
// count, and plain unicast/pin routes that must all be skipped.
const routeDump = `2001:db8:1::2/127 dev Ethernet0 proto kernel metric 256 pref medium
fcbb:bbbb:3:11::/64  encap seg6local action End.DT46 vrftable 1001 packets 4 bytes 592 errors 0 dev Vrf1 metric 1024 pref medium
fcbb:bbbb:9:99::/64  encap seg6local action End.DT46 vrftable 1002 dev Vrf9 metric 1024 pref medium
fcbb:bbbb:4:11:: from :: via 2001:db8:1::3 dev Ethernet0 metric 20 pref medium
fcbb:bbbb:3::/48 dev Loopback0 proto 196 metric 20 pref medium
`

func collectSIDSeries(t *testing.T) map[string]float64 {
	t.Helper()
	ch := make(chan prometheus.Metric, 64)
	go func() {
		srv6SIDCollector{}.Collect(ch)
		close(ch)
	}()
	series := map[string]float64{}
	for m := range ch {
		var d dto.Metric
		if err := m.Write(&d); err != nil {
			t.Fatalf("write metric: %v", err)
		}
		labels := map[string]string{}
		for _, lp := range d.GetLabel() {
			labels[lp.GetName()] = lp.GetValue()
		}
		key := strings.Join([]string{labels["node"], labels["sid"], labels["direction"]}, "|")
		series[key] = d.GetCounter().GetValue()
	}
	return series
}

func TestSRv6SIDCollectorEmitsSeriesPerCountedSID(t *testing.T) {
	restore := vrfStatsSource
	defer func() { vrfStatsSource = restore }()
	vrfStatsSource = func() map[string]transport {
		return map[string]transport{
			"leaf01": &sidScriptedTransport{stdout: routeDump},
		}
	}

	series := collectSIDSeries(t)
	if got := series["leaf01|fcbb:bbbb:3:11::/64|decap"]; got != 4 {
		t.Fatalf("leaf01|fcbb:bbbb:3:11::/64|decap = %v, want 4", got)
	}
	if len(series) != 1 {
		t.Fatalf("emitted %d series (%v), want exactly the one counted SID", len(series), series)
	}
}

func TestSRv6SIDCollectorScrapesEveryNode(t *testing.T) {
	restore := vrfStatsSource
	defer func() { vrfStatsSource = restore }()
	vrfStatsSource = func() map[string]transport {
		return map[string]transport{
			"leaf01": &sidScriptedTransport{stdout: routeDump},
			"leaf02": &sidScriptedTransport{stdout: strings.Replace(routeDump,
				"fcbb:bbbb:3:11::/64", "fcbb:bbbb:4:11::/64", 1)},
		}
	}

	series := collectSIDSeries(t)
	if got := series["leaf01|fcbb:bbbb:3:11::/64|decap"]; got != 4 {
		t.Fatalf("leaf01 series = %v, want 4", got)
	}
	if got := series["leaf02|fcbb:bbbb:4:11::/64|decap"]; got != 4 {
		t.Fatalf("leaf02 series = %v, want 4", got)
	}
}

func TestSRv6SIDCollectorSkipsUnreachableNode(t *testing.T) {
	restore := vrfStatsSource
	defer func() { vrfStatsSource = restore }()
	vrfStatsSource = func() map[string]transport {
		return map[string]transport{
			"leaf01": &sidScriptedTransport{stdout: routeDump},
			// A down node AND a node whose output is malformed: both must
			// contribute nothing, and neither may stop the healthy node.
			"spine01": &sidScriptedTransport{err: errors.New("exit code 1")},
			"leaf02":  &sidScriptedTransport{stdout: "garbage\n"},
		}
	}

	series := collectSIDSeries(t)
	if len(series) != 1 {
		t.Fatalf("emitted %d series (%v), want exactly leaf01's", len(series), series)
	}
	if _, ok := series["spine01|fcbb:bbbb:3:11::/64|decap"]; ok {
		t.Fatalf("unreachable node contributed a series")
	}
}

func TestSRv6SIDCollectorEmitsNothingWithoutNodes(t *testing.T) {
	restore := vrfStatsSource
	defer func() { vrfStatsSource = restore }()
	vrfStatsSource = func() map[string]transport { return nil } // no FABRIC_NODE_MAP

	if series := collectSIDSeries(t); len(series) != 0 {
		t.Fatalf("emitted %d series with no node map, want 0", len(series))
	}
}

func TestParseSRv6SIDStatsSkipsUncountedAndMalformedLines(t *testing.T) {
	stats := parseSRv6SIDStats(routeDump + "\nbroken\n")
	if len(stats) != 1 {
		t.Fatalf("parsed %d SID stats (%v), want 1", len(stats), stats)
	}
	if stats[0].sid != "fcbb:bbbb:3:11::/64" || stats[0].direction != "decap" || stats[0].packets != 4 {
		t.Fatalf("SID parsed wrong: %+v", stats[0])
	}
	// A zero counter is a real reading and must survive (the route counts,
	// it just has not forwarded yet).
	zero := parseSRv6SIDStats("fcbb:bbbb:3:11::/64  encap seg6local action End.DT46 vrftable 1001 packets 0 bytes 0 errors 0 dev Vrf1 metric 1024 pref medium\n")
	if len(zero) != 1 || zero[0].packets != 0 {
		t.Fatalf("zero counter lost: %+v", zero)
	}
	// A packets token that is not a number parses to nothing.
	bad := parseSRv6SIDStats("fcbb:bbbb:3:11::/64  encap seg6local action End.DT46 packets many dev Vrf1\n")
	if len(bad) != 0 {
		t.Fatalf("malformed counter accepted: %+v", bad)
	}
}
