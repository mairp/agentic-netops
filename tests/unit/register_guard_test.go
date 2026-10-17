// SPDX-License-Identifier: Apache-2.0
package unit

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	yaml "gopkg.in/yaml.v3"

	"github.com/mairp/agentic-netops/pkg/model"
	"github.com/mairp/agentic-netops/pkg/render"
	"github.com/mairp/agentic-netops/pkg/sdc"
)

func TestRegisterGuard_CatchesMissingPath(t *testing.T) {
	spec := map[string]any{
		"/interfaces/interface": map[string]any{"ok": true},
		"/unknown/path":         map[string]any{"bad": true},
	}
	if err := sdc.ValidateSpecAgainstRegister(spec, nil); err == nil {
		t.Fatalf("expected error for unregistered path")
	}
}

// registerPaths parses a register YAML and returns its entry paths, sorted.
func registerPaths(t *testing.T, data []byte) []string {
	t.Helper()
	reg := struct {
		Entries []struct {
			Path string `yaml:"path"`
		} `yaml:"entries"`
	}{}
	if err := yaml.Unmarshal(data, &reg); err != nil {
		t.Fatalf("parse register: %v", err)
	}
	paths := make([]string, 0, len(reg.Entries))
	for _, e := range reg.Entries {
		paths = append(paths, e.Path)
	}
	sort.Strings(paths)
	return paths
}

func srv6Paths(paths []string) []string {
	out := []string{}
	for _, p := range paths {
		if strings.HasPrefix(p, "/sonic-srv6:sonic-srv6/") {
			out = append(out, p)
		}
	}
	return out
}

// embeddedSRv6Paths extracts the SRv6 paths of the embedded default register
// by probing sdc.ValidateSpecAgainstRegister with candidate paths and keeping
// the ones it accepts as registered.
func embeddedSRv6Paths(t *testing.T) []string {
	t.Helper()
	candidates := []string{
		"/sonic-srv6:sonic-srv6/SRV6_MY_LOCATORS",
		"/sonic-srv6:sonic-srv6/SRV6_MY_SIDS",
	}
	known := []string{}
	for _, c := range candidates {
		if err := sdc.ValidateSpecAgainstRegister(map[string]any{c: map[string]any{}}, nil); err == nil {
			known = append(known, c)
		} else if !sdc.IsRegisterError(err) {
			t.Fatalf("probe %q: %v", c, err)
		}
	}
	return known
}

// TestRegisterGuard_SRv6CopiesMatch asserts the in-repo register and the
// embedded copy in pkg/sdc list exactly the same SRv6 paths, and that only
// the two schema-backed tables (SRV6_MY_LOCATORS, SRV6_MY_SIDS) remain.
func TestRegisterGuard_SRv6CopiesMatch(t *testing.T) {
	fileReg, err := os.ReadFile(filepath.Join("..", "..", "pkg", "register", "oc_vs_sonic.yaml"))
	if err != nil {
		t.Fatalf("read register: %v", err)
	}
	want := srv6Paths(registerPaths(t, fileReg))
	got := embeddedSRv6Paths(t)
	if len(got) == 0 {
		t.Fatalf("embedded register lists no SRv6 paths")
	}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("SRv6 register copies diverge:\n file:     %v\n embedded: %v", want, got)
	}
	for _, p := range want {
		switch p {
		case "/sonic-srv6:sonic-srv6/SRV6_MY_LOCATORS", "/sonic-srv6:sonic-srv6/SRV6_MY_SIDS":
		default:
			t.Fatalf("unexpected SRv6 register path %q; only SRV6_MY_LOCATORS and SRV6_MY_SIDS are schema-backed", p)
		}
	}
}

func TestRegisterGuard_PassesForRenderedPaths(t *testing.T) {
	// Build a representative spec using current renderers
	m := map[string]any{}
	for k, v := range render.RenderInterfaces([]model.Interface{{Name: "Ethernet1"}}, []model.Loopback{{Name: "Loopback0"}}) {
		m[k] = v
	}
	for k, v := range render.RenderBGP(model.BGPGlobal{ASN: 65000, RouterID: "1.1.1.1"}, []model.BGPNeighbor{{NeighborAddress: "10.0.0.2", PeerASN: 65001, EVPN: true}}) {
		m[k] = v
	}
	for k, v := range render.RenderVXLAN(model.VXLAN{SourceInterface: "Loopback0", UDPPort: 4789}, []model.VLAN{{ID: 10, Name: "blue", L2VNI: 10010}}) {
		m[k] = v
	}
	for k, v := range render.RenderSRv6MyLocators([]model.SRv6MyLocator{{Node: "leaf01", Prefix: "fcbb:bbbb:1::/48"}}) {
		m[k] = v
	}
	for k, v := range render.RenderSRv6MySids([]model.SRv6MySid{{Node: "leaf01", Prefix: "fcbb:bbbb:1:11::/64", Action: "uDT46", DecapVRF: "Vrf1"}}) {
		m[k] = v
	}
	if err := sdc.ValidateSpecAgainstRegister(m, nil); err != nil {
		if !sdc.IsRegisterError(err) {
			t.Fatalf("unexpected error type: %v", err)
		}
		t.Fatalf("expected register to cover current rendered paths, got: %v", err)
	}
}
