// SPDX-License-Identifier: Apache-2.0
// Site compatibility pins: where the pin set comes from when the reconciled
// object does not carry it.
//
// The compat validators (matrix.go) read pins from the object's own
// annotations. Nothing in the pipeline ever stamped them, so every object
// failed with "missing sonic image pin" — a false SchemaMismatch: the schema is
// known and pinned, the annotation plumbing just never existed. The honest
// source for the site default is versions.lock.yaml, the same file that
// provisioned the fabric image; provision generates it into the
// agentic-netops-system/fabric-compat-pins ConfigMap (keys = annotation names).
// Object annotations still win when present, so a pinned object keeps
// overriding the site default.
package compat

import (
	"context"
	"fmt"
	"strings"

	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// PinsConfigMapName is the ConfigMap provision generates from versions.lock.yaml.
//
// ConfigMap keys cannot carry "/", so provision writes the short forms below;
// AnnotationFor maps them back to the agentic-netops.dev/* annotation names the
// validators consume.
const (
	PinsConfigMapName      = "fabric-compat-pins"
	PinsConfigMapNamespace = "agentic-netops-system"

	ContractTopologyLabel  = "agentic-netops.dev/topology-label-contract"
	ContractTelemetryLabel = "agentic-netops.dev/telemetry-label-contract"
)

// shortKeyToAnnotation maps the ConfigMap's short keys to annotation names.
// cap-* keys are capability assertions (site qualification, see
// versions.lock.yaml "SRv6/gNMI-qualified" + scripts/lib/qualify.sh) and land
// in SitePins.Labels where the capability validators read them.
var shortKeyToAnnotation = map[string]string{
	"sonic-image":              "agentic-netops.dev/sonic-image",
	"openconfig-commit":        "agentic-netops.dev/openconfig-commit",
	"sonic-native-commit":      "agentic-netops.dev/sonic-native-commit",
	"mapping-version":          "agentic-netops.dev/mapping-version",
	"kubenet-commit":           "agentic-netops.dev/kubenet-commit",
	"kuid-commit":              "agentic-netops.dev/kuid-commit",
	"sdc-release":              "agentic-netops.dev/sdc-release",
	"topology-label-contract":  ContractTopologyLabel,
	"telemetry-label-contract": ContractTelemetryLabel,
	"cap-sai-srv6":             "agentic-netops.dev/cap.sai.srv6",
}

// AnnotationFor returns the pin/contract name a ConfigMap key feeds.
func AnnotationFor(shortKey string) (string, bool) {
	name, ok := shortKeyToAnnotation[shortKey]
	return name, ok
}

// SitePins carries the resolved pin set plus where each pin came from, so logs
// and events never leave provenance ambiguous.
type SitePins struct {
	Annotations map[string]string
	Labels      map[string]string
	Sources     map[string]string // key -> "configmap" | "object"
}

// PinReader is the minimal read surface ResolveSitePins needs. client.Client
// satisfies it, and so does manager.GetAPIReader() — prefer the API reader:
// a cache-backed Get on ConfigMaps rides whatever informer the manager built,
// and the sdc.Config controller's cluster-scoped ConfigMap informer fails its
// list under this deployment's RBAC, which would make every cached read fail.
type PinReader interface {
	Get(ctx context.Context, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error
}

// ResolveSitePins reads the site ConfigMap and merges the object's own
// annotations/labels over it. A missing ConfigMap is not an error: the object's
// annotations alone are used (the pre-ConfigMap behavior), and the caller
// surfaces the resulting validation error with its source map intact.
func ResolveSitePins(ctx context.Context, c PinReader, objAnn, objLabels map[string]string) SitePins {
	pins := SitePins{
		Annotations: map[string]string{},
		Labels:      map[string]string{},
		Sources:     map[string]string{},
	}

	var cm corev1.ConfigMap
	err := c.Get(ctx, client.ObjectKey{Name: PinsConfigMapName, Namespace: PinsConfigMapNamespace}, &cm)
	if err == nil {
		for k, v := range cm.Data {
			name, ok := AnnotationFor(k)
			if !ok || v == "" {
				continue
			}
			// Capability assertions (agentic-netops.dev/cap.*) are labels
			// everywhere else in this package — the validators read them from
			// SitePins.Labels — so route them consistently here too.
			if name == ContractTopologyLabel || name == ContractTelemetryLabel || strings.HasPrefix(name, "agentic-netops.dev/cap.") {
				pins.Labels[name] = v
			} else {
				pins.Annotations[name] = v
			}
			pins.Sources[name] = "configmap"
		}
	}

	for k, v := range objAnn {
		if v != "" {
			pins.Annotations[k] = v
			pins.Sources[k] = "object"
		}
	}
	for k, v := range objLabels {
		if v != "" {
			pins.Labels[k] = v
			pins.Sources[k] = "object"
		}
	}
	return pins
}

// Provenance renders a short human-readable source summary for events.
func (p SitePins) Provenance() string {
	cm, obj := 0, 0
	for _, s := range p.Sources {
		switch s {
		case "configmap":
			cm++
		case "object":
			obj++
		}
	}
	return fmt.Sprintf("pins: %d from %s, %d from object annotations", cm, PinsConfigMapName, obj)
}
