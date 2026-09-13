package unit

import (
	"regexp"
	"strings"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/mairp/agentic-netops/pkg/fabricplan"
	"github.com/mairp/agentic-netops/pkg/kubenet"
	"github.com/mairp/agentic-netops/pkg/migration"
)

// T034: DeviceACLTableName determinism and regex match; and the same derived name is used across apply/verify/rollback.
func TestDeviceACLTableName_DeterminismAndUsageAcrossPlanPhases(t *testing.T) {
	serviceID := "svc-1234567890abcdef"
	stage := "ingress"
	name1, err := migration.DeviceACLTableName(serviceID, stage)
	if err != nil {
		t.Fatalf("DeviceACLTableName: %v", err)
	}
	name2, err := migration.DeviceACLTableName(serviceID, stage)
	if err != nil {
		t.Fatalf("DeviceACLTableName(second): %v", err)
	}
	if name1 != name2 {
		t.Fatalf("DeviceACLTableName not deterministic: %q vs %q", name1, name2)
	}
	re := regexp.MustCompile(`^[a-zA-Z0-9]{1}([-a-zA-Z0-9_]{1,63})$`)
	if !re.MatchString(name1) {
		t.Fatalf("derived name does not match pattern: %q", name1)
	}
	// Build a minimal ACL-only network plan and prove the same name appears in ops, checks and rollback
	net := &kubenet.Network{
		ObjectMeta: metav1.ObjectMeta{Name: serviceID, Namespace: "tenant-x"},
		Spec: map[string]any{
			"accessLists": []any{map[string]any{
				"name": "allow-https", "stage": stage, "type": "l3",
				"rules": []any{map[string]any{"name": "allow", "priority": float64(100), "action": "permit"}},
			}},
			"attachments": []any{map[string]any{"node": "leaf01", "attachment": "ethernet1"}},
		},
	}
	plan, err := fabricplan.ForNetwork(net, fabricplan.Options{Ports: srlinuxSitePorts(), VXLANTunnel: "vxlan1"})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	np := plan.Nodes["leaf01"]
	if np == nil {
		t.Fatal("leaf01 plan missing")
	}
	filter := "/acl/acl-filter[name=" + name1 + ",type=ipv4]"
	// Apply: the filter is written at the derived name.
	var applySeen bool
	for _, op := range np.Ops {
		if op.GNMI == nil {
			continue
		}
		for _, u := range op.GNMI.Updates {
			if u.Path == filter || strings.Contains(u.Path, "name="+name1+",") {
				applySeen = true
			}
		}
	}
	if !applySeen {
		t.Fatalf("derived ACL filter name %q not present in the gNMI updates: %#v", name1, np.Ops)
	}
	// Verify: the checks read back the same derived name.
	var verifySeen bool
	for _, ck := range np.Checks {
		if strings.Contains(ck.Path, "name="+name1) {
			verifySeen = true
		}
	}
	if !verifySeen {
		t.Fatalf("derived ACL filter name %q not present in checks: %#v", name1, np.Checks)
	}
	// Rollback: the binding is removed before the filter, both by the same name.
	var rbBinding, rbFilter int = -1, -1
	for i, op := range np.Rollback {
		if op.GNMI == nil {
			continue
		}
		for _, d := range op.GNMI.Deletes {
			switch {
			case d == filter:
				rbFilter = i
			case strings.Contains(d, "/acl/") && strings.Contains(d, "name="+name1):
				if rbBinding < 0 {
					rbBinding = i
				}
			}
		}
	}
	if rbBinding < 0 || rbFilter < 0 {
		t.Fatalf("rollback does not remove binding then filter for %q: %#v", name1, np.Rollback)
	}
	if rbBinding > rbFilter {
		t.Fatalf("rollback deletes the filter while it is still bound: binding=%d filter=%d", rbBinding, rbFilter)
	}
}
