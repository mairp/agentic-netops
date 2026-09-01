package gnmi

import (
	"encoding/json"
	"fmt"
	"strings"
)

// scalarStr renders a JSON value as a string (numbers/strings/bools).
func scalarStr(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case float64:
		if x == float64(int64(x)) {
			return fmt.Sprintf("%d", int64(x))
		}
		return fmt.Sprintf("%v", x)
	case bool:
		return fmt.Sprintf("%v", x)
	default:
		b, _ := json.Marshal(x)
		return string(b)
	}
}

// scalarJSON renders a value as a stable string for redis storage.
func scalarJSON(v any) string {
	return scalarStr(v)
}

// extractScalar returns the value when it is a bare scalar, else "".
func extractScalar(v any) string {
	switch v.(type) {
	case string, float64, bool:
		return scalarStr(v)
	default:
		return ""
	}
}

// asList normalizes a value to a list of elements.
func asList(v any) ([]any, bool) {
	switch x := v.(type) {
	case []any:
		return x, true
	case map[string]any:
		// OpenConfig list convention: {"element": [...]}
		for _, k := range []string{"element", "item", "entry"} {
			if l, ok := x[k].([]any); ok {
				return l, true
			}
		}
		return []any{x}, true
	default:
		return nil, false
	}
}

// joinList renders a list (or scalar) as a comma-separated string.
func joinList(v any) string {
	if v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	if l, ok := v.([]any); ok {
		parts := make([]string, 0, len(l))
		for _, e := range l {
			parts = append(parts, scalarStr(e))
		}
		return strings.Join(parts, ",")
	}
	return scalarStr(v)
}
