// SPDX-License-Identifier: Apache-2.0
//
// Check naming (verify.go): a refusal or a drift observation must name the
// failed CHECK (quickstart Q6: "a message naming the node and the failed
// check"), not an index into the plan's check list. describeCheck names a
// check by what it asserts.

package srv6service

import (
	"fmt"
	"strings"
	"testing"

	"github.com/mairp/agentic-netops/pkg/fabricplan"
)

func TestDescribeCheckNamesWhatItAsserts(t *testing.T) {
	cases := []struct {
		name  string
		check fabricplan.Check
		want  []string // substrings the name must carry
	}{
		{
			name:  "steering encap route",
			check: fabricplan.Check{Type: "command", Command: "ip route show vrf Vrf1 | grep 'encap seg6'"},
			want:  []string{"command", "ip route show vrf Vrf1"},
		},
		{
			name:  "vrf table row",
			check: fabricplan.Check{Type: "redis-hget", RedisKey: "VRF_TABLE:Vrf1", RedisField: "vrf_name"},
			want:  []string{"redis-hget", "VRF_TABLE:Vrf1", "vrf_name"},
		},
		{
			name:  "attachment address",
			check: fabricplan.Check{Type: "ip-addr", Iface: "Ethernet12", Addr: "192.168.35.1/24"},
			want:  []string{"Ethernet12", "192.168.35.1/24"},
		},
		{
			name:  "type fallback",
			check: fabricplan.Check{Type: "redis-exists", RedisKey: "SRV6_MY_SIDS"},
			want:  []string{"redis-exists"},
		},
	}
	for _, tc := range cases {
		got := describeCheck(tc.check)
		for _, sub := range tc.want {
			if !strings.Contains(got, sub) {
				t.Errorf("%s: describeCheck = %q, want it to contain %q", tc.name, got, sub)
			}
		}
	}
	if l := len(describeCheck(fabricplan.Check{Type: "command",
		Command: strings.Repeat("x", 200)})); l > 80 {
		t.Errorf("describeCheck length = %d, want a bounded name", l)
	}
}

func TestCheckDisplayNamePrefersContentOverIndex(t *testing.T) {
	checks := []fabricplan.Check{
		{Type: "command", Command: "ip route show vrf Vrf1 | grep 'encap seg6'"},
	}
	got := checkDisplayName("checks[5].command", checks[0])
	if got == "checks[5].command" {
		t.Fatalf("checkDisplayName kept the index form %q", got)
	}
	if !strings.Contains(got, "ip route show vrf Vrf1") {
		t.Errorf("checkDisplayName = %q, want the asserted command", got)
	}
	if got := checkDisplayName("vrf-table-row", checks[0]); got != "vrf-table-row" {
		t.Errorf("checkDisplayName = %q, want the executor's own name kept", got)
	}
	fmt.Sprint() // keep fmt import if assertions above change
}
