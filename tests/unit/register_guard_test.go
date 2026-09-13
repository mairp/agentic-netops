// SPDX-License-Identifier: Apache-2.0
package unit

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mairp/agentic-netops/pkg/sdc"
)

// A guard that cannot fail is not a guard. This proves the register check
// rejects a path nothing declares.
func TestRegisterGuard_CatchesMissingPath(t *testing.T) {
	reg, err := os.ReadFile(filepath.Join("..", "..", "pkg", "register", "oc_vs_srlinux.yaml"))
	if err != nil {
		t.Fatalf("read register: %v", err)
	}
	spec := map[string]any{
		"/network-instance":       map[string]any{"ok": true},
		"/not/a/declared/surface": map[string]any{"bad": true},
	}
	err = sdc.ValidateSpecAgainstRegister(spec, reg)
	if err == nil {
		t.Fatal("expected an error for an unregistered path")
	}
	if !sdc.IsRegisterError(err) {
		t.Fatalf("unexpected error type: %v", err)
	}
	if !strings.Contains(err.Error(), "/not/a/declared/surface") {
		t.Errorf("the failure does not name the offending path: %v", err)
	}
}

// ...and that it fails for a family the RENDERER really emits when that family
// is taken out of the register. Removing one entry from the real file and
// re-running the real derivation is the only way to show the guard is wired to
// the renderer rather than to a copy of its output.
func TestRegisterGuard_FailsWhenARenderedFamilyIsUnregistered(t *testing.T) {
	families, err := renderedPathFamilies()
	if err != nil {
		t.Fatalf("render constructs: %v", err)
	}
	reg, err := os.ReadFile(filepath.Join("..", "..", "pkg", "register", "oc_vs_srlinux.yaml"))
	if err != nil {
		t.Fatalf("read register: %v", err)
	}
	// The vxlan-interface family: the one surface that carries the overlay, and
	// the one with no OpenConfig equivalent at all.
	const drop = "/tunnel-interface/vxlan-interface"
	if _, ok := families[drop]; !ok {
		t.Fatalf("the renderer no longer emits %s; this test needs updating", drop)
	}
	stripped := removeEntry(string(reg), drop)
	if stripped == string(reg) {
		t.Fatalf("the register no longer declares %s; this test needs updating", drop)
	}
	err = sdc.ValidateSpecAgainstRegister(families, []byte(stripped))
	if err == nil {
		t.Fatal("the guard passed with a rendered family missing from the register")
	}
	if !strings.Contains(err.Error(), "/tunnel-interface/vxlan-interface") {
		t.Errorf("the failure does not name the missing family: %v", err)
	}
}

// removeEntry drops the YAML list item whose `path:` is exactly want, leaving
// every other entry (including the longer paths that start with it) in place.
func removeEntry(reg, want string) string {
	lines := strings.Split(reg, "\n")
	var out []string
	skipping := false
	for _, l := range lines {
		trimmed := strings.TrimSpace(l)
		if strings.HasPrefix(trimmed, "- path:") {
			got := strings.Trim(strings.TrimSpace(strings.TrimPrefix(trimmed, "- path:")), `"`)
			skipping = got == want
		} else if skipping && (trimmed == "" || strings.HasPrefix(trimmed, "#")) {
			skipping = false
		}
		if !skipping {
			out = append(out, l)
		}
	}
	return strings.Join(out, "\n")
}
