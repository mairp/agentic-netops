//go:build agentic_netops_k8s

// SPDX-License-Identifier: Apache-2.0
// vrf_metrics_test.go — T560 unit tests for the scrape-time kernel VRF
// counter collector. The tests inject a fake transport through vrfStatsSource,
// so no test opens a real connection: the collector's contract is (a) the
// emitted series carry the node, device and direction of the kernel counters
// the transport returned, (b) a failing node contributes NO series while the
// rest still scrape, and (c) no FABRIC_NODE_MAP means no series at all.
package main

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
)

// scriptedTransport answers the collector's one command with canned stdout.
type scriptedTransport struct {
	stdout string
	err    error
}

func (s *scriptedTransport) run(_ context.Context, argv []string, _ []byte) (string, string, error) {
	if s.err != nil {
		return "", "", s.err
	}
	// The command must arrive as `bash -c <script>` (privilege-wrapped per
	// profile): anything else would break the parser's one-round-trip
	// contract.
	if len(argv) < 3 || argv[0] != "sudo" && (argv[0] != "bash" || argv[1] != "-c") {
		return "", "", errors.New("unexpected argv shape")
	}
	script := argv[len(argv)-1]
	if !strings.Contains(script, "grep -qw vrf") {
		return "", "", errors.New("command does not select VRF devices")
	}
	return s.stdout, "", nil
}

func (s *scriptedTransport) kind() string { return "ssh" }

func collectVRFSeries(t *testing.T) map[string]float64 {
	t.Helper()
	ch := make(chan prometheus.Metric, 64)
	go func() {
		vrfStatsCollector{}.Collect(ch)
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
		key := strings.Join([]string{labels["node"], labels["device"], labels["direction"]}, "|")
		series[key] = d.GetCounter().GetValue()
	}
	return series
}

func TestVRFStatsCollectorEmitsSeriesPerDeviceAndDirection(t *testing.T) {
	restore := vrfStatsSource
	defer func() { vrfStatsSource = restore }()
	vrfStatsSource = func() map[string]transport {
		return map[string]transport{
			"leaf01": &scriptedTransport{stdout: "Vrf1 7 3\nVrfBlue 0 0\n"},
		}
	}

	series := collectVRFSeries(t)
	if got := series["leaf01|Vrf1|rx"]; got != 7 {
		t.Fatalf("leaf01|Vrf1|rx = %v, want 7", got)
	}
	if got := series["leaf01|Vrf1|tx"]; got != 3 {
		t.Fatalf("leaf01|Vrf1|tx = %v, want 3", got)
	}
	if got, ok := series["leaf01|VrfBlue|rx"]; !ok || got != 0 {
		t.Fatalf("leaf01|VrfBlue|rx = %v (present %v), want a present 0", got, ok)
	}
}

func TestVRFStatsCollectorSkipsUnreachableNode(t *testing.T) {
	restore := vrfStatsSource
	defer func() { vrfStatsSource = restore }()
	vrfStatsSource = func() map[string]transport {
		return map[string]transport{
			"leaf01": &scriptedTransport{stdout: "Vrf1 7 3\n"},
			// A down node AND a node whose output is malformed: both must
			// contribute nothing, and neither may stop the healthy node.
			"spine01": &scriptedTransport{err: errors.New("exit code 1")},
			"leaf02":  &scriptedTransport{stdout: "garbage\n"},
		}
	}

	series := collectVRFSeries(t)
	if len(series) != 2 {
		t.Fatalf("emitted %d series (%v), want exactly leaf01's rx and tx", len(series), series)
	}
	if _, ok := series["spine01|Vrf1|rx"]; ok {
		t.Fatalf("unreachable node contributed a series")
	}
}

func TestVRFStatsCollectorEmitsNothingWithoutNodes(t *testing.T) {
	restore := vrfStatsSource
	defer func() { vrfStatsSource = restore }()
	vrfStatsSource = func() map[string]transport { return nil } // no FABRIC_NODE_MAP

	if series := collectVRFSeries(t); len(series) != 0 {
		t.Fatalf("emitted %d series with no node map, want 0", len(series))
	}
}

func TestParseVRFStatsSkipsMalformedLines(t *testing.T) {
	devices := parseVRFStats("Vrf1 7 3\nbroken\nVrf2 x 1\nVrf3 5 notanumber\n  \nVrf4 1 2\n")
	if len(devices) != 2 {
		t.Fatalf("parsed %d devices (%v), want 2", len(devices), devices)
	}
	if devices[0].device != "Vrf1" || devices[0].rxPackets != 7 || devices[0].txPackets != 3 {
		t.Fatalf("Vrf1 parsed wrong: %+v", devices[0])
	}
	if devices[1].device != "Vrf4" || devices[1].rxPackets != 1 || devices[1].txPackets != 2 {
		t.Fatalf("Vrf4 parsed wrong: %+v", devices[1])
	}
}
