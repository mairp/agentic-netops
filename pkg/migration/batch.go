// SPDX-License-Identifier: Apache-2.0
package migration

import (
	"bytes"
	"encoding/json"
	"fmt"
)

// RenderBatch validates a batch all-or-nothing and returns one YAML document per
// valid service in the input order. On validation failure, returns a ValidationError
// with aggregated causes and no output documents.
func RenderBatch(inputs []ServiceInput) ([]string, error) {
	// Detect duplicates
	ids := map[string]int{}
	for i, in := range inputs {
		if _, ok := ids[in.ServiceID]; ok {
			ids[in.ServiceID] = -1
		} else {
			ids[in.ServiceID] = i
		}
	}
	var causes []string
	for i := range inputs {
		in := inputs[i]
		dup := false
		if idx, ok := ids[in.ServiceID]; ok && idx == -1 {
			dup = true
		}
		if err := in.ValidateAllOrNothing(i, dup); err != nil {
			if ve, ok := err.(*ValidationError); ok {
				causes = append(causes, ve.Causes...)
			} else {
				causes = append(causes, err.Error())
			}
		}
	}
	if len(causes) > 0 {
		return nil, &ValidationError{Causes: causes}
	}
	out := make([]string, 0, len(inputs))
	for i := range inputs {
		in := inputs[i]
		bundle, err := Translate(&in)
		if err != nil {
			return nil, err
		}
		out = append(out, bundle.NetworkYAML)
	}
	return out, nil
}

// MarshalError produces a deterministic JSON string for structured validation errors.
// It disables HTML escaping so comparison substrings like ">=1" remain readable
// and stable in tests and CLI output.
func MarshalError(err error) string {
	if err == nil {
		return ""
	}
	m := map[string]any{"error": "validation"}
	if ve, ok := err.(*ValidationError); ok {
		m["causes"] = ve.Causes
	} else {
		m["causes"] = []string{err.Error()}
	}
	// Use an Encoder with HTML escaping disabled to avoid sequences like \u003e
	// for '>' which make human/fixture comparison brittle.
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	_ = enc.Encode(m)
	// json.Encoder adds a trailing newline; trim it for stable output.
	out := buf.String()
	if len(out) > 0 && out[len(out)-1] == '\n' {
		out = out[:len(out)-1]
	}
	return out
}

// DescribeInput produces a canonical description for provenance/testing.
func DescribeInput(in *ServiceInput) string {
	if in == nil {
		return "<nil>"
	}
	return fmt.Sprintf("%s/%s", in.Tenant, in.ServiceID)
}
