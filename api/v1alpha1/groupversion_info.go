// Package v1alpha1 contains API Schema definitions for the agentic-netops.io v1alpha1 API group.
// +kubebuilder:object:generate=true
// +groupName=agentic-netops.io
package v1alpha1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	// GroupVersion is group version used to register these objects
	GroupVersion = schema.GroupVersion{Group: "agentic-netops.io", Version: "v1alpha1"}

	// SchemeBuilder is used to add go types to the GroupVersionKind scheme
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}

	// AddToScheme adds this group-version to a scheme
	AddToScheme = SchemeBuilder.AddToScheme
)
