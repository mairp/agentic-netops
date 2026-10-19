// SPDX-License-Identifier: Apache-2.0
//
// srv6-plan-dump — render the bring-up SRv6Service sample through
// pkg/fabricplan.ForSRv6Service and print the per-node plan as JSON.
// Diagnostic harness only: it renders, it never touches a device or the
// cluster. Allocations are passed on the command line so the dump can mirror
// exactly what the live service was allocated.
//
// Usage:
//
//	srv6-plan-dump [-id 1] [-p0 192.168.90.0/24] [-p1 192.168.97.0/24] \
//	    [-steer spine01] [-kind sonic-vm]
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/controllers/srv6service"
	"github.com/mairp/agentic-netops/pkg/fabricplan"
)

// sidForLocator mirrors controllers/srv6service's service SID derivation
// (fcbb:bbbb:<node>:<fn>::/64 from the /48; function 11 per §8.2).
func sidForLocator(loc string) string {
	return strings.TrimSuffix(loc, "::/48") + ":11::/64"
}

func main() {
	id := flag.Int64("id", 1, "allocated service id")
	p0 := flag.String("p0", "192.168.90.0/24", "allocated client /24 for leaf01")
	p1 := flag.String("p1", "192.168.97.0/24", "allocated client /24 for leaf02")
	steer := flag.String("steer", "", "preferred spine (enables the §3.2 preferred pin)")
	kind := flag.String("kind", "sonic-vm", "node kind")
	flag.Parse()

	svc := &v1alpha1.SRv6Service{
		Spec: v1alpha1.SRv6ServiceSpec{
			Tenant:     "acme",
			Construct:  "ip-vrf",
			Signalling: "vpn",
			Attachments: []v1alpha1.Attachment{
				{Node: "leaf01", Port: "wan1", Gateway: []v1alpha1.GatewayPrefix{"192.168.1.1/24"}},
				{Node: "leaf02", Port: "wan1", Gateway: []v1alpha1.GatewayPrefix{"192.168.2.1/24"}},
			},
		},
	}
	if *steer != "" {
		svc.Spec.Path.PreferredSpine = *steer
	}
	facts := srv6service.DefaultSiteFacts()
	facts.NodeKind = *kind
	sids := map[string]string{}
	for n, loc := range facts.Locators {
		sids[n] = sidForLocator(loc)
	}
	plan, err := fabricplan.ForSRv6Service(svc, fabricplan.Allocations{
		ServiceID:      *id,
		VRF:            fmt.Sprintf("Vrf%d", *id),
		ServiceSIDs:    sids,
		ClientPrefixes: map[string]string{"leaf01": *p0, "leaf02": *p1},
	}, fabricplan.SRv6Options{
		Ports:      facts.PortMap,
		NodeKind:   facts.NodeKind,
		SpineLinks: facts.SpineLinks,
		Locators:   facts.Locators,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(plan); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
