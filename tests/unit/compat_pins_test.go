package unit

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/mairp/agentic-netops/pkg/compat"
)

// T026 — the pins loader knows the derived capability keys provision writes
// (contracts/capability-record.md §2/§5): `srv6-supported` feeds the label
// `agentic-netops.dev/cap.srv6.supported` (sibling of cap.sai.srv6), and
// `lab-profile` is read as informational provenance.
func TestCompat_AnnotationForDerivedCapabilityKeys(t *testing.T) {
	name, ok := compat.AnnotationFor("srv6-supported")
	if !ok || name != "agentic-netops.dev/cap.srv6.supported" {
		t.Fatalf("srv6-supported must map to agentic-netops.dev/cap.srv6.supported, got %q (ok=%v)", name, ok)
	}
	name, ok = compat.AnnotationFor("lab-profile")
	if !ok || name != "agentic-netops.dev/lab-profile" {
		t.Fatalf("lab-profile must map to agentic-netops.dev/lab-profile, got %q (ok=%v)", name, ok)
	}
}

type fakePinReader struct {
	cm *corev1.ConfigMap
}

func (f fakePinReader) Get(_ context.Context, _ types.NamespacedName, obj client.Object, _ ...client.GetOption) error {
	if f.cm == nil {
		return client.IgnoreNotFound(nil)
	}
	*(obj.(*corev1.ConfigMap)) = *f.cm
	return nil
}

func TestCompat_ResolveSitePinsRoutesDerivedKeys(t *testing.T) {
	cm := &corev1.ConfigMap{
		Data: map[string]string{
			"srv6-supported": "false",
			"lab-profile":    "sonic-vm",
		},
	}
	pins := compat.ResolveSitePins(context.Background(), fakePinReader{cm: cm}, nil, nil)
	if got := pins.Labels["agentic-netops.dev/cap.srv6.supported"]; got != "false" {
		t.Fatalf("srv6-supported must land in SitePins.Labels as cap.srv6.supported, got %q", got)
	}
	if got := pins.Annotations["agentic-netops.dev/lab-profile"]; got != "sonic-vm" {
		t.Fatalf("lab-profile must land in SitePins.Annotations, got %q", got)
	}
}
