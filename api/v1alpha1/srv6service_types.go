// SPDX-License-Identifier: Apache-2.0
// Package v1alpha1 defines the SRv6Service API types.
//
// The SRv6Service expresses a direct per-service request (user story 3): the
// operator names tenant, construct and attachments only — identifiers (service
// id, VRF name, per-attachment client /24) are ALLOCATED, never typed
// (contracts/srv6service-crd.md rule A12). Spec fields follow data-model.md §1,
// status fields data-model.md §2, admission rules contracts/srv6service-crd.md
// §2 (A1-A12) as root-level CEL validation markers.
package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Construct values for spec.construct.
const (
	// ConstructIPVRF is the routed L3 VPN construct (the one variant with a
	// proven lab recipe: ip-vrf/vpn).
	ConstructIPVRF = "ip-vrf"
	// ConstructMACVRF is the bridged L2 construct (its EVPN recipe is
	// not achievable on the pinned image; the controller refuses it by name).
	ConstructMACVRF = "mac-vrf"
)

// Signalling values for spec.signalling.
const (
	// SignallingVPN is the vpn signalling mode (no control-plane AF; the
	// as-built data plane is kernel seg6).
	SignallingVPN = "vpn"
	// SignallingEVPN is the evpn signalling mode (not achievable on the
	// pinned image; refused by name).
	SignallingEVPN = "evpn"
)

// Attachment node/port/capability reason strings shared with pkg/reasons.
const (
	// SRv6Finalizer is added before the first claim and removed only after
	// every node's rollback is confirmed and every claim is released
	// (contracts/srv6service-crd.md §5).
	SRv6Finalizer = "agentic-netops.dev/srv6"
	// CorrelationIDLabel is the label whose value identifies every claim the
	// controller makes for one service; it falls back to the object UID.
	CorrelationIDLabel = "agentic-netops.io/correlation-id"
)

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,shortName=srv6svc
// +kubebuilder:printcolumn:name="Ready",type=string,JSONPath=`.status.conditions[?(@.type=="Ready")].status`
// +kubebuilder:printcolumn:name="Construct",type=string,JSONPath=`.spec.construct`
// +kubebuilder:printcolumn:name="Signalling",type=string,JSONPath=`.spec.signalling`
// +kubebuilder:printcolumn:name="Path",type=string,JSONPath=`.status.activePath`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
//
// Admission rules (contracts/srv6service-crd.md §2, A1-A11; A12 is the
// structural schema itself). Every rule is TOTAL: a field the rule reads is
// has()-guarded, because field access on a structured object without that
// field is a CEL evaluation error ("no such key") rather than a clean
// rejection — measured live 2026-10-16 when the pre-004 stub object (no
// tenant/construct/vlan) hit every unguarded rule at once. Absent required
// fields still fail the structural schema; the rules below decide only the
// present-and-invalid case.
// +kubebuilder:validation:XValidation:message="tenant must be a DNS label",rule="!has(self.spec.tenant) || self.spec.tenant.matches('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')"
// +kubebuilder:validation:XValidation:message="construct must be ip-vrf or mac-vrf",rule="!has(self.spec.construct) || self.spec.construct == 'ip-vrf' || self.spec.construct == 'mac-vrf'"
// +kubebuilder:validation:XValidation:message="signalling must be vpn or evpn",rule="!has(self.spec.signalling) || self.spec.signalling == 'vpn' || self.spec.signalling == 'evpn'"
// +kubebuilder:validation:XValidation:message="mac-vrf over srv6 uses evpn signalling",rule="!has(self.spec.construct) || !(self.spec.construct == 'mac-vrf' && has(self.spec.signalling) && self.spec.signalling == 'vpn')"
// +kubebuilder:validation:XValidation:message="exactly two attachments are required",rule="has(self.spec.attachments) && size(self.spec.attachments) == 2"
// +kubebuilder:validation:XValidation:message="attachments must be on distinct nodes",rule="!has(self.spec.attachments) || size(self.spec.attachments) != 2 || self.spec.attachments[0].node != self.spec.attachments[1].node"
// +kubebuilder:validation:XValidation:message="gateway must be an IP prefix",rule="!has(self.spec.attachments) || self.spec.attachments.all(a, !has(a.gateway) || a.gateway.all(g, g.matches('^[0-9a-fA-F:.]+/[0-9]{1,3}$')))"
// +kubebuilder:validation:XValidation:message="vlan is required for mac-vrf and not allowed for ip-vrf",rule="(has(self.spec.vlan) && self.spec.vlan >= 1 && self.spec.vlan <= 4094) == (has(self.spec.construct) && self.spec.construct == 'mac-vrf')"
// +kubebuilder:validation:XValidation:message="ip-vrf attachments need a gateway prefix",rule="!has(self.spec.construct) || self.spec.construct != 'ip-vrf' || (has(self.spec.attachments) && size(self.spec.attachments) == 2 && has(self.spec.attachments[0].gateway) && has(self.spec.attachments[1].gateway) && size(self.spec.attachments[0].gateway) > 0 && size(self.spec.attachments[1].gateway) > 0)"
// +kubebuilder:validation:XValidation:message="preferred and alternate spine must differ",rule="!has(self.spec.path) || !has(self.spec.path.preferredSpine) || !has(self.spec.path.alternateSpine) || self.spec.path.preferredSpine != self.spec.path.alternateSpine"
// +kubebuilder:validation:XValidation:message="tenant is immutable",rule="(!has(self.spec.tenant) && !has(oldSelf.spec.tenant)) || (has(self.spec.tenant) && has(oldSelf.spec.tenant) && self.spec.tenant == oldSelf.spec.tenant)"
// +kubebuilder:validation:XValidation:message="construct is immutable",rule="(!has(self.spec.construct) && !has(oldSelf.spec.construct)) || (has(self.spec.construct) && has(oldSelf.spec.construct) && self.spec.construct == oldSelf.spec.construct)"
// +kubebuilder:validation:XValidation:message="signalling is immutable",rule="(!has(self.spec.signalling) && !has(oldSelf.spec.signalling)) || self.spec.signalling == oldSelf.spec.signalling"
type SRv6Service struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   SRv6ServiceSpec   `json:"spec,omitempty"`
	Status SRv6ServiceStatus `json:"status,omitempty"`
}

// SRv6ServiceSpec is the desired service intent: identifiers are allocated,
// not typed. There is no locator, SID or VRF field here.
type SRv6ServiceSpec struct {
	// tenant is the operator's tenant name as an RFC 1123 label (A1). It is
	// immutable (A11).
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=63
	Tenant string `json:"tenant"`
	// construct selects the service construct: ip-vrf or mac-vrf (A2).
	// Immutable (A11).
	Construct string `json:"construct"`
	// signalling selects vpn or evpn (A3); when omitted the controller
	// defaults it (vpn for ip-vrf, evpn for mac-vrf). mac-vrf with vpn is
	// refused at admission (A4). Immutable (A11).
	// +kubebuilder:validation:MinLength=1
	Signalling string `json:"signalling,omitempty"`
	// attachments names exactly two distinct fabric leaves and the ports the
	// service attaches to (A5, A6).
	// +kubebuilder:validation:MinItems=2
	// +kubebuilder:validation:MaxItems=2
	Attachments []Attachment `json:"attachments"`
	// vlan is the operator-named tag carried on the attachment ports
	// (mac-vrf only; A8). The controller reserves it in the allocation
	// authority under the service's correlation id before any device write.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=4094
	VLAN *int64 `json:"vlan,omitempty"`
	// path optionally pins a preferred spine with an alternate (A10).
	Path PathSelection `json:"path,omitempty"`
}

// Attachment names one leaf port the service attaches to.
type Attachment struct {
	// node is the fabric leaf the attachment sits on (C1 validates it is a
	// leaf of the fabric).
	// +kubebuilder:validation:MinLength=1
	Node string `json:"node"`
	// port is the attachment port name as the site port map writes it
	// (e.g. wan1; C2 resolves it through the site port map).
	// +kubebuilder:validation:MinLength=1
	Port string `json:"port"`
	// gateway holds the leaf-side prefixes of the attachment for an ip-vrf
	// (A9 requires at least one on both attachments for ip-vrf). A7 checks
	// the prefix format. An update may change them (US3 scenario 9): the
	// controller re-renders from status.appliedSpec, and the claimed
	// identifiers stay. The GatewayPrefix element type bounds each prefix so
	// the A7 CEL cost estimate stays inside the API-server budget (a full
	// IPv6 prefix with /128 is 43 characters).
	// +kubebuilder:validation:MinItems=1
	// +kubebuilder:validation:MaxItems=4
	Gateway []GatewayPrefix `json:"gateway,omitempty"`
}

// GatewayPrefix is one leaf-side gateway prefix of an attachment. The bounds
// here are what keep the A7 admission rule's CEL cost estimate (a regex
// match over each element) inside the API server's per-rule budget.
// +kubebuilder:validation:MinLength=3
// +kubebuilder:validation:MaxLength=45
type GatewayPrefix string

// PathSelection optionally pins the service to a preferred spine with an
// alternate (steering).
type PathSelection struct {
	// preferredSpine is the spine the service prefers (C3 validates it is a
	// spine of the fabric).
	// +kubebuilder:validation:MinLength=1
	PreferredSpine string `json:"preferredSpine,omitempty"`
	// alternateSpine is the spine used when the preferred one fails (A10:
	// must differ from preferredSpine).
	// +kubebuilder:validation:MinLength=1
	AlternateSpine string `json:"alternateSpine,omitempty"`
}

// SRv6ServiceStatus is the observed state (data-model.md §2).
type SRv6ServiceStatus struct {
	// observedGeneration is the generation the conditions describe.
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`
	// conditions carry Ready and the terminal refusal conditions.
	// +listType=map
	// +listMapKey=type
	// +kubebuilder:validation:MaxItems=32
	Conditions []metav1.Condition `json:"conditions,omitempty"`
	// allocations lists every identifier the controller claimed for this
	// service, each traceable to a claim carrying status.correlationId.
	Allocations *Allocations `json:"allocations,omitempty"`
	// nodes is the per-attachment-node apply/verify state.
	// +kubebuilder:validation:MaxItems=4
	Nodes []NodeStatus `json:"nodes,omitempty"`
	// activePath names the spine in use (preferred or alternate).
	// +kubebuilder:validation:MinLength=1
	ActivePath string `json:"activePath,omitempty"`
	// dataPath is the client-to-client check result at first activation.
	DataPath *DataPathStatus `json:"dataPath,omitempty"`
	// configHashes maps node name to the rendered plan hash; an unchanged
	// re-apply matches it and produces zero device writes.
	ConfigHashes map[string]string `json:"configHashes,omitempty"`
	// appliedSpec is the spec the currently applied plan was rendered from;
	// updates re-render it to compute what must be removed per node.
	AppliedSpec *SRv6ServiceSpec `json:"appliedSpec,omitempty"`
	// correlationId identifies every claim this service holds: the value of
	// the deployer's agentic-netops.io/correlation-id label, else the object
	// UID.
	// +kubebuilder:validation:MinLength=1
	CorrelationID string `json:"correlationId,omitempty"`
}

// Allocations reports the identifiers claimed for this service
// (data-model.md §8.1, the ip-vrf/vpn profile).
type Allocations struct {
	// serviceID is the claimed generic identifier; the VRF name is built as
	// Vrf<ServiceID>.
	// +kubebuilder:validation:Minimum=1
	ServiceID int64 `json:"serviceId,omitempty"`
	// vrf is the rendered VRF name (Vrf<ServiceID>).
	// +kubebuilder:validation:MinLength=1
	VRF string `json:"vrf,omitempty"`
	// clientPrefixes maps attachment node to the claimed per-attachment
	// client /24 the client container sits in.
	// +kubebuilder:validation:MinProperties=1
	// +kubebuilder:validation:MaxProperties=4
	ClientPrefixes map[string]string `json:"clientPrefixes,omitempty"`
	// vlan, for a mac-vrf, is the operator-named value reserved under the
	// correlation id (kept in the schema for the mac-vrf profile; its EVPN
	// recipe is not achievable and the controller refuses the variant).
	VLAN *int64 `json:"vlan,omitempty"`
}

// NodeStatus is the apply/verify state of one attachment node.
type NodeStatus struct {
	// node is the fabric node this state describes.
	// +kubebuilder:validation:MinLength=1
	Node string `json:"node"`
	// applied reports the executor accepted the node's plan.
	Applied bool `json:"applied"`
	// verified reports every per-node check passed on device-observed state.
	Verified bool `json:"verified"`
	// failedCheck names the check that failed on this node, when one did.
	// +kubebuilder:validation:MinLength=1
	FailedCheck string `json:"failedCheck,omitempty"`
}

// DataPathStatus records the client-to-client probe at first activation.
type DataPathStatus struct {
	// checkedAt is when the probe ran; it is never later than the Ready
	// transition for the generation it belongs to.
	CheckedAt metav1.Time `json:"checkedAt,omitempty"`
	// result is pass or fail (the probe-ping outcome).
	// +kubebuilder:validation:Enum=pass;fail
	Result string `json:"result"`
}

// +kubebuilder:object:root=true
// SRv6ServiceList contains a list of SRv6Service
type SRv6ServiceList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []SRv6Service `json:"items"`
}

func init() {
	SchemeBuilder.Register(&SRv6Service{}, &SRv6ServiceList{})
}
