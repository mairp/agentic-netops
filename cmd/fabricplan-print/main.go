// SPDX-License-Identifier: Apache-2.0
// fabricplan-print — render one Kubenet Network through pkg/fabricplan and
// print the per-node plan as JSON.
//
// This is the trial harness for the construct-parity work (spec 004 plan
// 4-05..4-19): the p4-*-trial proofs apply the RENDERED plan (the same
// ForNetwork output the provider applies) to the lab through the
// fabric-executor, so the renderer must be invocable outside the controller.
// The tool renders only — it never touches a device or the cluster.
//
// Usage:
//
//	fabricplan-print -f network.yaml -portmap port-map.json \
//	    [-kind sonic-vm] [-vtep vtep1] [-asn 65000]
//
// Output: a JSON array of NodePlan (node, ops, checks, rollback), sorted by
// node name so the output is byte-stable for a given input.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"sort"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/yaml"

	"github.com/mairp/agentic-netops/pkg/fabricplan"
	"github.com/mairp/agentic-netops/pkg/kubenet"
)

// envelope mirrors the Network CR wire shape (apiVersion/kind/metadata/spec);
// Spec stays an untyped map exactly like pkg/kubenet.Network.
type envelope struct {
	APIVersion string            `json:"apiVersion,omitempty"`
	Kind       string            `json:"kind,omitempty"`
	Metadata   metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec       map[string]any    `json:"spec,omitempty"`
}

func main() {
	netPath := flag.String("f", "", "Network manifest (YAML or JSON), required")
	pmPath := flag.String("portmap", "", "port map JSON (logical attachment -> port), required")
	kind := flag.String("kind", "sonic-vs", "node kind the plan targets: sonic-vs or sonic-vm")
	vtep := flag.String("vtep", "vtep1", "VXLAN tunnel name the site baseline creates")
	asn := flag.String("asn", "", "fabric ASN for best-effort per-vrf FRR config")
	flag.Parse()
	if *netPath == "" || *pmPath == "" {
		fmt.Fprintln(os.Stderr, "usage: fabricplan-print -f network.yaml -portmap port-map.json [-kind sonic-vm] [-vtep vtep1] [-asn ASN]")
		os.Exit(2)
	}

	rawNet, err := os.ReadFile(*netPath)
	if err != nil {
		fatal("read network: %v", err)
	}
	var env envelope
	// sigs.k8s.io/yaml accepts JSON too, so one decode path covers both.
	if err := yaml.Unmarshal(rawNet, &env); err != nil {
		fatal("decode network %s: %v", *netPath, err)
	}

	rawPM, err := os.ReadFile(*pmPath)
	if err != nil {
		fatal("read port map: %v", err)
	}
	var pmRaw map[string]string
	if err := json.Unmarshal(rawPM, &pmRaw); err != nil {
		fatal("decode port map %s: %v", *pmPath, err)
	}
	// Keys beginning with "_" are annotation (e.g. _comment), never ports.
	pm := fabricplan.PortMapper{}
	for k, v := range pmRaw {
		if len(k) > 0 && k[0] == '_' {
			continue
		}
		pm[k] = v
	}

	net := &kubenet.Network{ObjectMeta: env.Metadata, Spec: env.Spec}
	plan, err := fabricplan.ForNetwork(net, fabricplan.Options{
		Ports:    pm,
		NodeKind: *kind,
		VTEPName: *vtep,
		BGPASN:   *asn,
	})
	if err != nil {
		fatal("render: %v", err)
	}

	names := make([]string, 0, len(plan.Nodes))
	for n := range plan.Nodes {
		names = append(names, n)
	}
	sort.Strings(names)
	out := make([]*fabricplan.NodePlan, 0, len(names))
	for _, n := range names {
		out = append(out, plan.Nodes[n])
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(out); err != nil {
		fatal("encode plan: %v", err)
	}
}

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "fabricplan-print: "+format+"\n", args...)
	os.Exit(1)
}
