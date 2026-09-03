// SPDX-License-Identifier: Apache-2.0
// Package kubenet provides minimal pinned upstream Kubenet types required for watches/indexes.
// This avoids importing the full upstream module while allowing controller-runtime to
// watch NetworkDevice resources and reconcile against them.
package kubenet

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

// GroupVersion for pinned Kubenet APIs (see deploy/kubenet/crds/kubenet-crds.yaml).
var GroupVersion = schema.GroupVersion{Group: "network.kubenet.dev", Version: "v1alpha1"}

// NetworkDevice is a minimal representation of Kubenet's derived per-device intent.
// We preserve unknown fields and do not attempt to model the full schema here.
//
// +k8s:deepcopy-gen=false
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced
// +kubebuilder:printcolumn:name="Ready",type=string,JSONPath=`.status.conditions[?(@.type=="Ready")].status`
// +kubebuilder:validation:Optional
// +kubebuilder:validation:Type=object
// +kubebuilder:validation:PreserveUnknownFields=true
// +kubebuilder:validation:MaxProperties=0
// +kubebuilder:validation:MinProperties=0
// NOTE: This type is intentionally loose — controllers read metadata and labels and do
// not modify upstream status directly.
//
// We implement only the minimal fields needed to act as a client.Object.
// Spec/Status remain untyped to avoid drift.
//
//nolint:tagliatelle // external API shape
//nolint:revive // external API shape
//nolint:stylecheck // external API shape
//nolint:godox
type NetworkDevice struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              map[string]any `json:"spec,omitempty"`
	Status            map[string]any `json:"status,omitempty"`
}

// DeepCopyObject implements runtime.Object (manual since we skip codegen here).
func (in *NetworkDevice) DeepCopyObject() runtime.Object {
	if in == nil {
		return nil
	}
	out := new(NetworkDevice)
	*out = *in
	// shallow copy of maps is sufficient for our read-only use in watches
	return out
}

// NetworkDeviceList is required for informer cache.
type NetworkDeviceList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []NetworkDevice `json:"items"`
}

// DeepCopyObject implements runtime.Object.
func (in *NetworkDeviceList) DeepCopyObject() runtime.Object {
	if in == nil {
		return nil
	}
	out := new(NetworkDeviceList)
	*out = *in
	return out
}

var (
	// SchemeBuilder registers Kubenet types.
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}
)

// AddToScheme adds Kubenet types and sets the group-version metadata so unstructured/typed clients work.
func AddToScheme(s *runtime.Scheme) error {
	if err := SchemeBuilder.AddToScheme(s); err != nil {
		return err
	}
	metav1.AddToGroupVersion(s, GroupVersion)
	return nil
}

func init() {
	SchemeBuilder.Register(&NetworkDevice{}, &NetworkDeviceList{})
}
