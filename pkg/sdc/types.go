// SPDX-License-Identifier: Apache-2.0
// Package sdc contains minimal typed stubs for SDC CRDs used by controllers for watches and SSA.
package sdc

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

// GroupVersion for SDC APIs.
var GroupVersion = schema.GroupVersion{Group: "sdc.sdcio.dev", Version: "v1alpha1"}

// Config models the minimal SDC Config resource required to apply device intent.
// We model Spec as an opaque object whose contents are the rendered paths/payloads.
// Status is modeled only to allow Deviation/Ready aggregation by controllers.
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced
// +kubebuilder:validation:Type=object
// +kubebuilder:validation:PreserveUnknownFields=true
// +kubebuilder:printcolumn:name="Ready",type=string,JSONPath=`.status.ready`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
type Config struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              map[string]any `json:"spec,omitempty"`
	Status            ConfigStatus   `json:"status,omitempty"`
}

type ConfigStatus struct {
	Ready     bool              `json:"ready,omitempty"`
	Deviation []DeviationRecord `json:"deviation,omitempty"`
}

// Policy encodes SDC apply/transaction policies.
// Included under spec["$policy"] when applying via SSA.
// Fields are intentionally unvalidated here; SDC performs server-side validation.
// Serialization uses lower-case keys to match SDC's expected schema.
// Example:
//   {"priority":100, "operation":"replace", "revertive":true, "deletionPolicy":"retain"}
// (T037 explicit policy fields)

type Policy struct {
	Priority       int    `json:"priority"`
	Operation      string `json:"operation"`
	Revertive      bool   `json:"revertive"`
	DeletionPolicy string `json:"deletionPolicy"`
}

// BuildPolicy constructs a Policy as a generic map ready to embed into Config.Spec["$policy"].
func BuildPolicy(priority int, operation string, revertive bool, deletionPolicy string) map[string]any {
	return map[string]any{
		"priority":       priority,
		"operation":      operation,
		"revertive":      revertive,
		"deletionPolicy": deletionPolicy,
	}
}

type DeviationRecord struct {
	Path    string `json:"path"`
	Message string `json:"message,omitempty"`
}

// +kubebuilder:object:root=true
type ConfigList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Config `json:"items"`
}

// Target is a minimal stub to watch target readiness if needed.
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
type Target struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              map[string]any `json:"spec,omitempty"`
	Status            TargetStatus   `json:"status,omitempty"`
}

type TargetStatus struct {
	Ready bool `json:"ready,omitempty"`
}

// +kubebuilder:object:root=true
type TargetList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Target `json:"items"`
}

var (
	// SchemeBuilder registers SDC types.
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}
	// AddToScheme adds SDC types.
	AddToScheme = SchemeBuilder.AddToScheme
)

func init() {
	SchemeBuilder.Register(&Config{}, &ConfigList{}, &Target{}, &TargetList{})
}

// DeepCopyObject implementations (manual, minimal) so these types satisfy runtime.Object.
func (in *Config) DeepCopyObject() runtime.Object {
	if in == nil {
		return nil
	}
	out := new(Config)
	*out = *in
	return out
}
func (in *ConfigList) DeepCopyObject() runtime.Object {
	if in == nil {
		return nil
	}
	out := new(ConfigList)
	*out = *in
	return out
}
func (in *Target) DeepCopyObject() runtime.Object {
	if in == nil {
		return nil
	}
	out := new(Target)
	*out = *in
	return out
}
func (in *TargetList) DeepCopyObject() runtime.Object {
	if in == nil {
		return nil
	}
	out := new(TargetList)
	*out = *in
	return out
}
