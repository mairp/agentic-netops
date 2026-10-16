//go:build agentic_netops_k8s

// SPDX-License-Identifier: Apache-2.0
// metrics.go — the applied-op counter (T157).
//
// Every successfully applied op moves fabric_executor_ops_applied_total;
// verify never does (reads must not look like writes in the metrics). The
// counter is served on /metrics via promhttp (vendored client_golang).
package main

import (
	"github.com/prometheus/client_golang/prometheus"
)

var opsApplied = prometheus.NewCounter(prometheus.CounterOpts{
	Namespace: "fabric_executor",
	Name:      "ops_applied_total",
	Help:      "Ops successfully applied to fabric nodes (apply path only; verify is never counted).",
})

func init() {
	prometheus.MustRegister(opsApplied)
}
