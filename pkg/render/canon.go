// SPDX-License-Identifier: Apache-2.0
package render

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"sort"
	"strings"
)

// CanonicalJSON marshals a map[string]any into a canonical JSON string with
// stable key ordering so equal logical content yields byte-identical output.
// We implement a deterministic serializer that sorts map keys recursively.
func CanonicalJSON(spec map[string]any) (string, error) {
	b, err := marshalCanonical(spec)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// CanonicalHash returns a hex-encoded SHA-256 of the canonical JSON.
func CanonicalHash(spec map[string]any) (string, error) {
	j, err := CanonicalJSON(spec)
	if err != nil { return "", err }
	s := sha256.Sum256([]byte(j))
	return hex.EncodeToString(s[:]), nil
}

// marshalCanonical encodes v into JSON with deterministic map-key ordering.
func marshalCanonical(v any) ([]byte, error) {
	switch x := v.(type) {
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x { keys = append(keys, k) }
		sort.Strings(keys)
		parts := make([]string, 0, len(keys))
		for _, k := range keys {
			vb, err := marshalCanonical(x[k])
			if err != nil { return nil, err }
			kb, _ := json.Marshal(k)
			parts = append(parts, string(kb)+":"+string(vb))
		}
		return []byte("{" + strings.Join(parts, ",") + "}"), nil
	case []any:
		parts := make([]string, 0, len(x))
		for _, e := range x {
			b, err := marshalCanonical(e)
			if err != nil { return nil, err }
			parts = append(parts, string(b))
		}
		return []byte("[" + strings.Join(parts, ",") + "]"), nil
	case []map[string]any:
		parts := make([]string, 0, len(x))
		for _, e := range x {
			b, err := marshalCanonical(e)
			if err != nil { return nil, err }
			parts = append(parts, string(b))
		}
		return []byte("[" + strings.Join(parts, ",") + "]"), nil
	default:
		return json.Marshal(x)
	}
}
