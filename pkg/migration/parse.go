// SPDX-License-Identifier: Apache-2.0
package migration

import (
	"bytes"
	"encoding/json"
	"fmt"
)

// ParseStrictBatch decodes a JSON object or array of ServiceInput with
// DisallowUnknownFields to ensure unknown properties are rejected.
func ParseStrictBatch(data []byte) ([]ServiceInput, error) {
	trim := bytes.TrimSpace(data)
	if len(trim) == 0 {
		return nil, fmt.Errorf("empty input")
	}
	switch trim[0] {
	case '[':
		var raws []json.RawMessage
		if err := json.Unmarshal(trim, &raws); err != nil {
			return nil, err
		}
		out := make([]ServiceInput, 0, len(raws))
		for i := range raws {
			var in ServiceInput
			if err := strictUnmarshal(raws[i], &in); err != nil {
				return nil, fmt.Errorf("item %d: %w", i, err)
			}
			out = append(out, in)
		}
		return out, nil
	case '{':
		var in ServiceInput
		if err := strictUnmarshal(trim, &in); err != nil {
			return nil, err
		}
		return []ServiceInput{in}, nil
	default:
		return nil, fmt.Errorf("invalid JSON: expected object or array")
	}
}

func strictUnmarshal(b []byte, v any) error {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return err
	}
	return nil
}
