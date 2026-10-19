//go:build agentic_netops_k8s

// SPDX-License-Identifier: Apache-2.0
// metrics.go — executor instrumentation: the applied-op counter (T157) and
// the kernel forwarding counters read at scrape time (T560).
//
// Every successfully applied op moves fabric_executor_ops_applied_total;
// verify never does (reads must not look like writes in the metrics). Both
// metric families are served on /metrics via promhttp (vendored
// client_golang).
//
// T560 has two families, matching the two kernel granularities this build
// actually has:
//
//   - fabric_executor_srv6_sid_packets_total — the kernel PER-SID counters.
//     The plan's decap op installs the End.DT46 route with the seg6local
//     `count` flag (pkg/fabricplan/srv6.go); the kernel then keeps the
//     behavior's own counters, visible as `packets N bytes M errors 0` on
//     the route line of `ip -s -6 route show`. The stored spike
//     (spike-counters §4) read a route WITHOUT the flag, saw no counter
//     fields, and concluded per-SID counters do not exist on this build —
//     falsified 2026-10-18 on the running sonic-vm guest (kernel
//     6.1.0-29-2-amd64, iproute2 6.1.0, which lists `count` in the SEG6LOCAL
//     grammar): enabling it made 4 client pings decapsulated by
//     fcbb:bbbb:3:11::/64 raise that route's own packets counter 0 → 4 on
//     both leaves at 0% loss. This family is the series the SRv6 dashboard
//     plots and the observability suite asserts.
//
//   - fabric_executor_node_vrf_packets_total — the VRF devices' own
//     interface stats (spike-counters §6), the coarser companion granularity
//     (per VRF device and direction, not per SID).
//
// Both are read through the SAME node transports the write path uses — no
// second channel into the fabric — at scrape time, so a scrape never serves
// stale numbers. A node that cannot answer within the per-node budget simply
// reports no series for that scrape.
package main

import (
	"context"
	"encoding/json"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

var opsApplied = prometheus.NewCounter(prometheus.CounterOpts{
	Namespace: "fabric_executor",
	Name:      "ops_applied_total",
	Help:      "Ops successfully applied to fabric nodes (apply path only; verify is never counted).",
})

// vrfPacketsDesc describes the per-node kernel VRF forwarding counters — the
// coarser companion granularity to the per-SID counters below.
var vrfPacketsDesc = prometheus.NewDesc(
	"fabric_executor_node_vrf_packets_total",
	"Kernel packets on the node's VRF devices, read through the node transport at scrape time (T560). Per VRF device and direction — the per-SID granularity is fabric_executor_srv6_sid_packets_total, which reads the seg6local `count` counters the plan installs on each service SID's decap route.",
	[]string{"node", "device", "direction"}, nil,
)

// vrfStatsSource returns the node transports the collector reads at scrape
// time. The default builds them from the same environment main() does
// (FABRIC_NODE_MAP plus loadTransportConfig); tests inject fakes here so a
// unit test never opens a real connection.
var vrfStatsSource = nodeTransportsFromEnv

// nodeTransportsFromEnv mirrors main()'s transport construction one-for-one:
// ssh where the transport config says ssh, docker otherwise. It lives here so
// the collector needs no hook in main() — the two constructors must stay in
// step (the collector's reads ride the same keys and credentials the write
// path uses; a second construction of anything else would drift).
func nodeTransportsFromEnv() map[string]transport {
	raw := os.Getenv("FABRIC_NODE_MAP")
	if raw == "" {
		return nil
	}
	nm := map[string]string{}
	if err := json.Unmarshal([]byte(raw), &nm); err != nil {
		return nil
	}
	cfg, err := loadTransportConfig(os.Getenv)
	if err != nil {
		return nil
	}
	trans := map[string]transport{}
	for node := range nm {
		if sp, ok := cfg.spec(node); ok && sp.Kind == "ssh" {
			trans[node] = &sshTransport{
				node:        node,
				spec:        sp,
				keyPath:     cfg.sshKey,
				knownHosts:  cfg.knownHosts,
				controlPath: os.Getenv("FABRIC_SSH_CONTROL_PATH"),
			}
		} else {
			trans[node] = &dockerTransport{container: nm[node]}
		}
	}
	return trans
}

// vrfStatsCommand enumerates the node's VRF devices and their kernel packet
// counters in one round trip: one line per device, "device rx tx". The vrf
// kind comes from `ip -o -d link show` (word "vrf"), the counters from the
// device's sysfs statistics — both world-readable on the guest, and the ssh
// profile's `sudo -n` wrap applies as to every other command.
const vrfStatsCommand = `for d in /sys/class/net/*; do dev=${d##*/}; ` +
	`if ip -o -d link show "$dev" 2>/dev/null | grep -qw vrf; then ` +
	`echo "$dev $(cat "$d/statistics/rx_packets") $(cat "$d/statistics/tx_packets")"; fi; done`

// vrfStatsReadTimeout bounds one node's read inside a scrape: a wedged node
// must not stretch the scrape past Prometheus' patience; it just reports no
// series this scrape.
const vrfStatsReadTimeout = 8 * time.Second

type vrfStatsCollector struct{}

func init() {
	prometheus.MustRegister(opsApplied, vrfStatsCollector{}, srv6SIDCollector{})
}

// Describe uses DescribeByCollect: the collector's output is not fixed (a
// node that cannot be read contributes no series), so the collect walk is the
// description.
func (vrfStatsCollector) Describe(ch chan<- *prometheus.Desc) {
	prometheus.DescribeByCollect(vrfStatsCollector{}, ch)
}

// Collect reads every node's VRF device counters concurrently, each read
// bounded by vrfStatsReadTimeout, and emits one series per device and
// direction. Reads are best-effort by design: the executor's /metrics must
// stay available when a node is down — an unreachable node is visible as a
// MISSING series, which is exactly how the observability suite treats it.
func (vrfStatsCollector) Collect(ch chan<- prometheus.Metric) {
	trans := vrfStatsSource()
	nodes := make([]string, 0, len(trans))
	for node := range trans {
		nodes = append(nodes, node)
	}
	sort.Strings(nodes)

	type read struct {
		node    string
		devices []vrfDeviceStats
	}
	results := make(chan read, len(nodes))
	var wg sync.WaitGroup
	for _, node := range nodes {
		wg.Add(1)
		go func(node string, tr transport) {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), vrfStatsReadTimeout)
			defer cancel()
			argv := wrapPrivilege([]string{"bash", "-c", vrfStatsCommand}, profileFor(tr.kind()))
			out, _, err := tr.run(ctx, argv, nil)
			if err != nil {
				return // no series for this node this scrape
			}
			results <- read{node: node, devices: parseVRFStats(out)}
		}(node, trans[node])
	}
	wg.Wait()
	close(results)

	for r := range results {
		for _, d := range r.devices {
			ch <- prometheus.MustNewConstMetric(vrfPacketsDesc, prometheus.CounterValue, d.rxPackets,
				r.node, d.device, "rx")
			ch <- prometheus.MustNewConstMetric(vrfPacketsDesc, prometheus.CounterValue, d.txPackets,
				r.node, d.device, "tx")
		}
	}
}

// vrfDeviceStats is one VRF device's kernel counters as scraped.
type vrfDeviceStats struct {
	device    string
	rxPackets float64
	txPackets float64
}

// parseVRFStats reads the command's "device rx tx" lines. Malformed lines are
// skipped, not fatal: a partial read is still better than no read.
func parseVRFStats(out string) []vrfDeviceStats {
	devices := []vrfDeviceStats{}
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) != 3 || fields[0] == "" {
			continue
		}
		rx, err := strconv.ParseFloat(fields[1], 64)
		if err != nil {
			continue
		}
		tx, err := strconv.ParseFloat(fields[2], 64)
		if err != nil {
			continue
		}
		devices = append(devices, vrfDeviceStats{device: fields[0], rxPackets: rx, txPackets: tx})
	}
	return devices
}

// srv6SIDPacketsDesc describes the kernel per-SID counters (the count branch
// of T560 — the series the SRv6 dashboard plots).
var srv6SIDPacketsDesc = prometheus.NewDesc(
	"fabric_executor_srv6_sid_packets_total",
	"Kernel packets counted by each SRv6 seg6local behavior route, read through the node transport at scrape time (T560). The plan installs the End.DT46 decap route with the seg6local `count` flag, so the kernel keeps the behavior's own counters, visible as `packets N bytes M errors 0` on the route line of `ip -s -6 route show`. One series per service SID; direction is the behavior's role in the service path.",
	[]string{"node", "sid", "direction"}, nil,
)

// srv6SIDCommand dumps every IPv6 route WITH its per-route statistics in one
// round trip. Only seg6local routes installed with the `count` flag carry
// counter fields; routes without them parse to nothing.
const srv6SIDCommand = "ip -s -6 route show"

type srv6SIDCollector struct{}

// Describe uses DescribeByCollect, like the VRF collector: a node that
// cannot be read contributes no series, so the collect walk is the
// description.
func (srv6SIDCollector) Describe(ch chan<- *prometheus.Desc) {
	prometheus.DescribeByCollect(srv6SIDCollector{}, ch)
}

// Collect reads every node's per-route statistics concurrently, each read
// bounded by vrfStatsReadTimeout, and emits one series per counted SID.
// Same best-effort contract as the VRF collector: an unreachable node is
// visible as a MISSING series, never as a scrape failure.
func (srv6SIDCollector) Collect(ch chan<- prometheus.Metric) {
	trans := vrfStatsSource()
	nodes := make([]string, 0, len(trans))
	for node := range trans {
		nodes = append(nodes, node)
	}
	sort.Strings(nodes)

	type read struct {
		node string
		sids []srv6SIDStats
	}
	results := make(chan read, len(nodes))
	var wg sync.WaitGroup
	for _, node := range nodes {
		wg.Add(1)
		go func(node string, tr transport) {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), vrfStatsReadTimeout)
			defer cancel()
			argv := wrapPrivilege([]string{"bash", "-c", srv6SIDCommand}, profileFor(tr.kind()))
			out, _, err := tr.run(ctx, argv, nil)
			if err != nil {
				return // no series for this node this scrape
			}
			results <- read{node: node, sids: parseSRv6SIDStats(out)}
		}(node, trans[node])
	}
	wg.Wait()
	close(results)

	for r := range results {
		for _, s := range r.sids {
			ch <- prometheus.MustNewConstMetric(srv6SIDPacketsDesc, prometheus.CounterValue, s.packets,
				r.node, s.sid, s.direction)
		}
	}
}

// srv6SIDStats is one seg6local route's per-SID counter as scraped.
type srv6SIDStats struct {
	sid       string
	direction string
	packets   float64
}

// parseSRv6SIDStats reads `ip -s -6 route show` lines of the recorded shape
//
//	fcbb:bbbb:3:11::/64  encap seg6local action End.DT46 vrftable 1001 packets 4 bytes 592 errors 0 dev Vrf1 metric 1024 pref medium
//
// Only routes installed with the seg6local `count` flag carry the
// packets/bytes/errors fields; a route without them contributes no series —
// the counter is off, not zero. (The `from ::` pin routes and plain
// unicast routes have no seg6local token and are skipped by the same test.)
// Malformed lines are skipped, not fatal.
func parseSRv6SIDStats(out string) []srv6SIDStats {
	stats := []srv6SIDStats{}
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 || fields[0] == "" {
			continue
		}
		seg6local, packetsIdx := false, -1
		for i, f := range fields {
			switch f {
			case "seg6local":
				seg6local = true
			case "packets":
				packetsIdx = i
			}
		}
		if !seg6local || packetsIdx < 0 || packetsIdx+1 >= len(fields) {
			continue
		}
		pkts, err := strconv.ParseFloat(fields[packetsIdx+1], 64)
		if err != nil {
			continue
		}
		stats = append(stats, srv6SIDStats{sid: fields[0], direction: "decap", packets: pkts})
	}
	return stats
}
