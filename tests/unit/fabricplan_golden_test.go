// SPDX-License-Identifier: Apache-2.0
package unit

import (
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"sort"
	"testing"

	"github.com/mairp/agentic-netops/pkg/fabricplan"
)

// update regenerates the golden plans:
//
//	go test ./tests/unit -run TestFabricPlanGolden -update
//
// Regenerating is a deliberate act: the golden files are the exact JSON the
// provider POSTs to the fabric-executor, so a diff in them is a change in what
// the fabric is told to do. Review the diff before committing it.
var update = flag.Bool("update", false, "rewrite the golden plans under testdata/fabricplan")

const goldenDir = "testdata/fabricplan"

// TestFabricPlanGolden pins the rendered plan for each construct on the
// two-leaf SR Linux site. It compares canonical JSON (encoding/json sorts map
// keys), so key order inside a value is not part of the contract — but every
// path, every value and the ORDER of ops, checks and rollback are.
func TestFabricPlanGolden(t *testing.T) {
	for name, net := range constructNetworks() {
		t.Run(name, func(t *testing.T) {
			plan, err := fabricplan.ForNetwork(net, fabricplan.Options{Ports: srlinuxSitePorts(), VXLANTunnel: "vxlan1"})
			if err != nil {
				t.Fatalf("ForNetwork: %v", err)
			}
			got, err := canonicalPlan(plan)
			if err != nil {
				t.Fatalf("marshal plan: %v", err)
			}
			path := filepath.Join(goldenDir, name+".json")
			if *update {
				if err := os.MkdirAll(goldenDir, 0o755); err != nil {
					t.Fatalf("mkdir %s: %v", goldenDir, err)
				}
				if err := os.WriteFile(path, got, 0o644); err != nil {
					t.Fatalf("write %s: %v", path, err)
				}
				t.Logf("updated %s", path)
				return
			}
			want, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read %s (regenerate with: go test ./tests/unit -run TestFabricPlanGolden -update): %v", path, err)
			}
			if string(got) != string(want) {
				t.Errorf("rendered plan for %s differs from %s.\n--- got ---\n%s", name, path, got)
			}
		})
	}
}

// canonicalPlan renders the plan the way the provider sends it: node names
// sorted, everything else in render order, pretty-printed so a golden diff is
// readable line by line.
func canonicalPlan(plan *fabricplan.Plan) ([]byte, error) {
	names := make([]string, 0, len(plan.Nodes))
	for n := range plan.Nodes {
		names = append(names, n)
	}
	sort.Strings(names)
	nodes := make([]*fabricplan.NodePlan, 0, len(names))
	for _, n := range names {
		nodes = append(nodes, plan.Nodes[n])
	}
	b, err := json.MarshalIndent(map[string]any{"nodes": nodes}, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

// The golden plans are only evidence if they are byte-stable: the reconciler
// re-renders on every resync, and a plan that differed run to run would make
// every resync look like a change.
func TestFabricPlanGoldenIsStable(t *testing.T) {
	first := map[string][]byte{}
	for round := 0; round < 5; round++ {
		for name, net := range constructNetworks() {
			plan, err := fabricplan.ForNetwork(net, fabricplan.Options{Ports: srlinuxSitePorts(), VXLANTunnel: "vxlan1"})
			if err != nil {
				t.Fatalf("%s: ForNetwork: %v", name, err)
			}
			got, err := canonicalPlan(plan)
			if err != nil {
				t.Fatalf("%s: marshal: %v", name, err)
			}
			if prev, ok := first[name]; ok {
				if string(prev) != string(got) {
					t.Fatalf("%s: plan is not byte-stable across renders", name)
				}
				continue
			}
			first[name] = got
		}
	}
}
