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
	plan, err := fabricplan.ForNetwork(net, fabricplan.Options{Ports: fabricplan.PortMapper{"ethernet1": "Eth1"}})
	if err != nil {
		t.Fatalf("ForNetwork: %v", err)
	}
	np := plan.Nodes["leaf01"]
	if np == nil {
		t.Fatal("leaf01 plan missing")
	}
	// Apply: Redis ops must write ACL_TABLE|<name1> and ACL_RULE|<name1>|*
	var applySeen bool
	for _, op := range np.Ops {
		for _, cmd := range op.Redis {
			if strings.Contains(cmd, "ACL_TABLE|"+name1) || strings.Contains(cmd, "ACL_RULE|"+name1+"|") {
				applySeen = true
			}
		}
	}
	if !applySeen {
		t.Fatalf("derived ACL table name %q not present in Redis ops: %#v", name1, np.Ops)
	}
	// Verify: config-side checks target ACL_TABLE|<name1>
	var verifySeen bool
	for _, ck := range np.Checks {
		if strings.Contains(ck.RedisKey, "ACL_TABLE|"+name1) || strings.Contains(ck.RedisKey, "ACL_RULE|"+name1+"|") {
			verifySeen = true
		}
	}
	if !verifySeen {
		t.Fatalf("derived ACL table name %q not present in checks: %#v", name1, np.Checks)
	}
	// Rollback: deletes ACL_RULE|<name1>|* then ACL_TABLE|<name1>
	var rbSeen bool
	for _, op := range np.Rollback {
		for _, cmd := range op.Redis {
			if strings.Contains(cmd, "del 'ACL_TABLE|"+name1+"'") || strings.Contains(cmd, "del 'ACL_RULE|"+name1+"|") {
				rbSeen = true
			}
		}
	}
	if !rbSeen {
		t.Fatalf("derived ACL table name %q not present in rollback: %#v", name1, np.Rollback)
	}
}
