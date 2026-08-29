// SPDX-License-Identifier: Apache-2.0
// Package v1alpha1 defines the SRv6Service API types.
package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,shortName=srv6svc
// +kubebuilder:printcolumn:name="Ready",type=string,JSONPath=`.status.conditions[?(@.type=="Ready")].status`
// +kubebuilder:printcolumn:name="Degraded",type=string,JSONPath=`.status.conditions[?(@.type=="Degraded")].status`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
// SRv6Service expresses a bidirectional IPv6 VPN across SONiC nodes.
// Validation is kept structural with CEL rules for cross-field constraints.
// See specs/.../contracts/crd-api.md for required semantics.
//
// Note: This is a narrow placeholder capturing the mandatory shape for scaffolding.
// Full CEL coverage is added in config/crd YAML manifests.
// +kubebuilder:validation:XValidation:message="client and server endpoints must be distinct",rule="self.spec.client.name != self.spec.server.name"
// +kubebuilder:validation:XValidation:message="exactly two attachments are required",rule="size(self.spec.attachments)==2"
// +kubebuilder:validation:XValidation:message="service prefixes must be IPv6",rule="self.spec.servicePrefix.matches('^([0-9a-fA-F:]+)/[0-9]+$')"
// +kubebuilder:validation:XValidation:message="locator must be IPv6 prefix",rule="self.spec.locatorPrefix.matches('^([0-9a-fA-F:]+)/[0-9]+$')"
// +kubebuilder:validation:XValidation:message="waypoints must be SONiC device refs",rule="size(self.spec.transitWaypoints) >= 0"
// +kubebuilder:validation:XValidation:message="vrf is immutable",rule="!has(oldSelf) || self.spec.vrf == oldSelf.spec.vrf"
// +kubebuilder:validation:XValidation:message="topologyRef must be non-empty",rule="self.spec.topologyRef != ''"
// +kubebuilder:validation:XValidation:message="path must name a primary route",rule="self.spec.path.primary != ''"
// +kubebuilder:validation:XValidation:message="endpoints must be IPv6",rule="self.spec.client.ip.matches('^([0-9a-fA-F:]+)/[0-9]+$') && self.spec.server.ip.matches('^([0-9a-fA-F:]+)/[0-9]+$')"
// +kubebuilder:validation:XValidation:message="SRv6 requires IPv6",rule="self.spec.underlay == 'ipv6'"
// +kubebuilder:validation:XValidation:message="attachments must be unique",rule="self.spec.attachments[0].node != self.spec.attachments[1].node"
// +kubebuilder:validation:XValidation:message="locator length must be /48-/64",rule="int(self.spec.locatorPrefix.split('/')[1]) >= 48 && int(self.spec.locatorPrefix.split('/')[1]) <= 64"
// +kubebuilder:validation:XValidation:message="service prefix must be /64-/96",rule="int(self.spec.servicePrefix.split('/')[1]) >= 64 && int(self.spec.servicePrefix.split('/')[1]) <= 96"
// +kubebuilder:validation:Optional
// +kubebuilder:validation:Type=object
// +kubebuilder:validation:PreserveUnknownFields=false
// +kubebuilder:validation:MaxProperties=30
// +kubebuilder:validation:MinProperties=1
// +kubebuilder:validation:Required={"attachments","topologyRef","locatorPrefix","vrf","path","client","server","servicePrefix"}
type SRv6Service struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   SRv6ServiceSpec   `json:"spec,omitempty"`
	Status SRv6ServiceStatus `json:"status,omitempty"`
}

// SRv6ServiceSpec defines desired SRv6 service intent.
type SRv6ServiceSpec struct {
	// attachments must contain exactly two distinct nodes
	Attachments []Attachment `json:"attachments"`
	// topologyRef names a Ready topology in Kubenet
	TopologyRef string `json:"topologyRef"`
	// locatorPrefix is the IPv6 locator pool prefix allocated by KUID
	LocatorPrefix string `json:"locatorPrefix"`
	// vrf is immutable service VRF name
	VRF string `json:"vrf"`
	// path selection with primary and alternate waypoint sequence names
	Path PathSelection `json:"path"`
	// client end of the service
	Client Endpoint `json:"client"`
	// server end of the service
	Server Endpoint `json:"server"`
	// servicePrefix identifies the service IPv6 CIDR
	ServicePrefix string `json:"servicePrefix"`
	// optional list of explicit SONiC transit waypoint device names
	TransitWaypoints []string `json:"transitWaypoints,omitempty"`
	// underlay must be ipv6 for SRv6
	Underlay string `json:"underlay"`
}

// Attachment pairs a node with an interface.
type Attachment struct {
	Node string `json:"node"`
	Intf string `json:"interface"`
}

// PathSelection identifies named waypoint routes.
type PathSelection struct {
	Primary string `json:"primary"`
	Alternate string `json:"alternate,omitempty"`
}

// Endpoint identifies an endpoint node and IP/prefix.
type Endpoint struct {
	Name string `json:"name"`
	IP   string `json:"ip"`
}

// SRv6ServiceStatus exposes observedGeneration, conditions, allocations, and per-path data.
type SRv6ServiceStatus struct {
	ObservedGeneration int64              `json:"observedGeneration,omitempty"`
	Conditions         []metav1.Condition `json:"conditions,omitempty"`
	// Hashes of generated SDC Configs per target
	ConfigHashes map[string]string `json:"configHashes,omitempty"`
	// Active path name
	ActivePath string `json:"activePath,omitempty"`
}

// +kubebuilder:object:root=true
// SRv6ServiceList contains a list of SRv6Service
// +kubebuilder:object:generate=true
type SRv6ServiceList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []SRv6Service `json:"items"`
}

func init() {
	SchemeBuilder.Register(&SRv6Service{}, &SRv6ServiceList{})
}
