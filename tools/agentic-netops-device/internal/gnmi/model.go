// Package gnmi implements the Agentic NetOps SONiC device gNMI server: a gRPC gNMI
// endpoint (Capabilities/Get/Set/Subscribe) that bridges the SONiC redis
// database (CONFIG_DB / STATE_DB) to gNMI paths under the models the
// qualification and acceptance suites consume. JSON_IETF encoding is
// supported. Set writes are recorded as the intended (managed) state for
// drift restoration when the request carries the agentic-netops-intended metadata.
package gnmi

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// Element is one path element: a list instance (with keys) or a leaf/leafref.
type Element struct {
	Name string
	Keys map[string]string
}

// Path is a parsed gNMI model path.
type Path struct {
	Model    string
	Elements []Element
}

var elemRe = regexp.MustCompile(`([A-Za-z0-9_$.-]+)(?:\[([^\]]*)\])?`)

// ParsePath parses a gNMI path string like
// /openconfig-interfaces:interfaces/interface[name=x]/state/counters.
func ParsePath(p string) (*Path, error) {
	p = strings.TrimPrefix(p, "/")
	if p == "" {
		return nil, fmt.Errorf("empty path")
	}
	rest := p
	model := ""
	if i := strings.Index(p, ":"); i >= 0 {
		model = p[:i]
		rest = p[i+1:]
	} else {
		// first element is the model root container
	}
	out := &Path{Model: model}
	for rest != "" {
		m := elemRe.FindStringSubmatchIndex(rest)
		if m == nil {
			return nil, fmt.Errorf("unparseable path element in %q", rest)
		}
		name := rest[m[2]:m[3]]
		el := Element{Name: name}
		if m[4] >= 0 {
			kvStr := rest[m[4]:m[5]]
			for _, kv := range strings.Split(kvStr, ",") {
				kv = strings.TrimSpace(kv)
				if kv == "" {
					continue
				}
				eq := strings.Index(kv, "=")
				if eq < 0 {
					return nil, fmt.Errorf("bad key %q in %q", kv, p)
				}
				k := strings.TrimSpace(kv[:eq])
				v := strings.TrimSpace(kv[eq+1:])
				if el.Keys == nil {
					el.Keys = map[string]string{}
				}
				el.Keys[k] = v
			}
		}
		out.Elements = append(out.Elements, el)
		rest = rest[m[1]:]
	}
	return out, nil
}

// Join returns the list of element names (no keys).
func (p *Path) Names() []string {
	names := make([]string, 0, len(p.Elements))
	for _, e := range p.Elements {
		names = append(names, e.Name)
	}
	return names
}

// KeyAt returns the key of element i, or "" if absent/not keyed.
func (p *Path) KeyAt(i int, key string) string {
	if i < 0 || i >= len(p.Elements) {
		return ""
	}
	return p.Elements[i].Keys[key]
}

// StrAt is a convenience: element name at index i.
func (p *Path) StrAt(i int) string {
	if i < 0 || i >= len(p.Elements) {
		return ""
	}
	return p.Elements[i].Name
}

// json helper: build a nested object from ordered key/values.
func jobj(pairs ...any) map[string]any {
	m := map[string]any{}
	for i := 0; i+1 < len(pairs); i += 2 {
		m[fmt.Sprint(pairs[i])] = pairs[i+1]
	}
	return m
}

// sortedKeys returns sorted keys of a map (for stable output).
func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
