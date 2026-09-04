// SPDX-License-Identifier: Apache-2.0
// Minimal client types for the Kubenet Network intent CR (network.kubenet.dev/v1alpha1).
//
// Like NetworkDevice, this is intentionally loose: Spec/Status stay untyped maps
// so the CRD schema (pinned upstream) remains the single source of truth and we
// never drift from it. The accessors below parse only the fields the SONiC
// provider's fabric reconciler consumes, tolerating absent/mistyped fields the
// same way the upstream API does (omit, not fail).
package kubenet

import (
	"encoding/json"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

// Schema for a single L3VPN router (VRF) intent, parsed from Spec["routers"].
type NetworkRouter struct {
	Name        string   `json:"name"`
	L3VNI       int64    `json:"l3vni"`
	RD          string   `json:"rd,omitempty"`
	RouteTargets *RouteTargets `json:"routeTargets,omitempty"`
	Prefixes    []string `json:"prefixes,omitempty"`
}

type RouteTargets struct {
	Import []string `json:"import,omitempty"`
	Export []string `json:"export,omitempty"`
}

// Schema for a single attachment (a port on a node joining a service).
type NetworkAttachment struct {
	Node       string `json:"node"`
	Attachment string `json:"attachment"`
	VRF        string `json:"vrf,omitempty"`
	VLAN       int64  `json:"vlan,omitempty"`
}

// Schema for a single L2 bridge domain, parsed from Spec["bridgeDomains"].
type BridgeDomain struct {
	Name  string `json:"name"`
	VLAN  int64  `json:"vlan,omitempty"`
	L2VNI int64  `json:"l2vni,omitempty"`
	EVPN  *struct {
		RouteTargets *RouteTargets `json:"routeTargets,omitempty"`
	} `json:"evpn,omitempty"`
}

// Network mirrors kubenet's network.kubenet.dev/v1alpha1 Network CR.
//
//nolint:revive // external API shape
type Network struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              map[string]any `json:"spec,omitempty"`
	Status            map[string]any `json:"status,omitempty"`
}

func (in *Network) DeepCopyObject() runtime.Object {
	if in == nil {
		return nil
	}
	out := new(Network)
	*out = *in
	return out
}

// NetworkList is required for the informer cache.
type NetworkList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Network `json:"items"`
}

func (in *NetworkList) DeepCopyObject() runtime.Object {
	if in == nil {
		return nil
	}
	out := new(NetworkList)
	*out = *in
	return out
}

// Routers parses Spec["routers"] as L3VPN router intent; unknown shapes yield nil.
func (n *Network) Routers() []NetworkRouter {
	return decodeList[NetworkRouter](n.Spec["routers"])
}

// Attachments parses Spec["attachments"].
func (n *Network) Attachments() []NetworkAttachment {
	return decodeList[NetworkAttachment](n.Spec["attachments"])
}

// BridgeDomains parses Spec["bridgeDomains"].
func (n *Network) BridgeDomains() []BridgeDomain {
	return decodeList[BridgeDomain](n.Spec["bridgeDomains"])
}

func decodeList[T any](v any) []T {
	raw, ok := v.([]any)
	if !ok {
		return nil
	}
	out := make([]T, 0, len(raw))
	for _, item := range raw {
		m, ok := item.(map[string]any)
		if !ok {
			continue
		}
		var t T
		b, err := json.Marshal(m)
		if err != nil {
			continue
		}
		if err := json.Unmarshal(b, &t); err == nil {
			out = append(out, t)
		}
	}
	return out
}

func init() {
	SchemeBuilder.Register(&Network{}, &NetworkList{})
}
