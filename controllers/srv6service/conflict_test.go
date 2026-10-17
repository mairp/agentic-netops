// SPDX-License-Identifier: Apache-2.0
//
// Unit tests for the C4/C7 conflict checks (conflict.go): a terminally
// refused object holds nothing, and the FIRST resource is the holder (a
// younger twin is refused, never the older one). Live evidence 2026-10-16:
// the q9-port-in-use fixture's refusal held the ports AGAINST the older
// Ready service and refused it (PortInUse naming the refused object) until
// the refused object was deleted.

package srv6service

import (
	"context"
	"testing"
	"time"

	agenticnetopsv1alpha1 "github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/reasons"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func conflictSvc(name string, at time.Time, uid string, gw string) *agenticnetopsv1alpha1.SRv6Service {
	svc := &agenticnetopsv1alpha1.SRv6Service{
		Spec: agenticnetopsv1alpha1.SRv6ServiceSpec{
			Tenant:      "acme",
			Construct:   "ip-vrf",
			Signalling:  "vpn",
			Attachments: []agenticnetopsv1alpha1.Attachment{{Node: "leaf01", Port: "wan1", Gateway: []agenticnetopsv1alpha1.GatewayPrefix{agenticnetopsv1alpha1.GatewayPrefix(gw)}}, {Node: "leaf02", Port: "wan1", Gateway: []agenticnetopsv1alpha1.GatewayPrefix{agenticnetopsv1alpha1.GatewayPrefix(gw)}}},
		},
	}
	svc.Name = name
	svc.Namespace = "intent"
	svc.CreationTimestamp = metav1.NewTime(at)
	svc.UID = types.UID(uid)
	return svc
}

func refused(svc *agenticnetopsv1alpha1.SRv6Service, reason string) *agenticnetopsv1alpha1.SRv6Service {
	svc.Generation = 1
	svc.Status.Conditions = []metav1.Condition{{
		Type:               "Ready",
		Status:             metav1.ConditionFalse,
		Reason:             reason,
		Message:            "terminal",
		ObservedGeneration: svc.Generation,
	}}
	return svc
}

func TestRefusedObjectHoldsNothing(t *testing.T) {
	now := time.Now()
	holder := conflictSvc("holder", now.Add(-time.Minute), "uid-holder", "192.168.1.1/24")
	refusedTwin := refused(conflictSvc("twin", now, "uid-twin", "192.168.11.1/24"), reasons.ReasonUnsupportedVariant)

	scheme := runtime.NewScheme()
	_ = agenticnetopsv1alpha1.AddToScheme(scheme)
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(holder, refusedTwin).Build()

	if ref := checkConflicts(context.Background(), c, holder); ref != nil {
		t.Fatalf("the older live service must not be refused by a terminally refused twin, got %s: %s", ref.Reason, ref.Message)
	}
}

func TestFirstResourceHoldsServiceIdentity(t *testing.T) {
	now := time.Now()
	older := conflictSvc("older", now.Add(-time.Minute), "uid-older", "192.168.1.1/24")
	younger := conflictSvc("younger", now, "uid-younger", "192.168.11.1/24")

	scheme := runtime.NewScheme()
	_ = agenticnetopsv1alpha1.AddToScheme(scheme)
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(older, younger).Build()

	ref := checkConflicts(context.Background(), c, younger)
	if ref == nil || ref.Reason != reasons.ReasonPortInUse {
		t.Fatalf("the younger twin must be refused PortInUse, got %+v", ref)
	}
	if ref.Message != `attachments leaf01/wan1, leaf02/wan1 for tenant "acme" already held by SRv6Service "older"` {
		t.Fatalf("the refusal must name the first resource, got: %s", ref.Message)
	}
	if ref := checkConflicts(context.Background(), c, older); ref != nil {
		t.Fatalf("the first resource must hold, got %s: %s", ref.Reason, ref.Message)
	}
}
