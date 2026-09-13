// SPDX-License-Identifier: Apache-2.0
// gNMI path parsing for the fabric-executor.
//
// The renderer emits SR Linux native paths in the notation gnmic and the node's
// own CLI use: `/interface[name=ethernet-1/3]/subinterface[index=130]/oper-state`.
// gNMI wants that as a structured Path (a list of elements, each with its keys),
// so something has to translate. The obvious library for it (openconfig/ygot's
// xpath helpers) is not vendored here, and vendoring the whole ygot tree to
// parse a bracketed string is not a trade this repository should make — so the
// parser lives here, with the two properties that actually matter on this
// fabric:
//
//   - a key VALUE may contain '/' (ethernet-1/3 is an interface name, not two
//     path elements), so element splitting has to respect bracket depth;
//   - several keys may share one element, either as `[a=b,c=d]` (the acl-filter
//     name/type pair) or as `[a=b][c=d]`, and both spellings mean the same
//     element.
package main

import (
	"fmt"
	"strings"

	gnmipb "github.com/openconfig/gnmi/proto/gnmi"
)

// parsePath turns an xpath-style SR Linux path into a gNMI Path.
//
// The empty path (and "/") is the root: a Path with no elements, which is what
// gNMI itself uses to address the whole tree.
func parsePath(p string) (*gnmipb.Path, error) {
	out := &gnmipb.Path{}
	trimmed := strings.TrimSpace(p)
	if trimmed == "" || trimmed == "/" {
		return out, nil
	}
	if !strings.HasPrefix(trimmed, "/") {
		return nil, fmt.Errorf("path %q must start with /", p)
	}
	for _, raw := range splitElems(trimmed) {
		if raw == "" {
			// A doubled separator is a typo in a rendered path, and silently
			// dropping it would address a different node than the plan named.
			return nil, fmt.Errorf("path %q has an empty element", p)
		}
		elem, err := parseElem(raw)
		if err != nil {
			return nil, fmt.Errorf("path %q: %w", p, err)
		}
		out.Elem = append(out.Elem, elem)
	}
	return out, nil
}

// splitElems splits on '/' at bracket depth zero, so key values that contain a
// slash (ethernet-1/3) stay inside the element that owns them.
func splitElems(p string) []string {
	var out []string
	var cur strings.Builder
	depth := 0
	for _, r := range strings.TrimPrefix(p, "/") {
		switch r {
		case '[':
			depth++
			cur.WriteRune(r)
		case ']':
			if depth > 0 {
				depth--
			}
			cur.WriteRune(r)
		case '/':
			if depth == 0 {
				out = append(out, cur.String())
				cur.Reset()
				continue
			}
			cur.WriteRune(r)
		default:
			cur.WriteRune(r)
		}
	}
	out = append(out, cur.String())
	return out
}

// parseElem reads one element: a name, then zero or more bracketed key groups.
func parseElem(raw string) (*gnmipb.PathElem, error) {
	name, rest, found := strings.Cut(raw, "[")
	if !found {
		if strings.Contains(raw, "]") {
			return nil, fmt.Errorf("element %q closes a bracket it never opened", raw)
		}
		return &gnmipb.PathElem{Name: name}, nil
	}
	if name == "" {
		return nil, fmt.Errorf("element %q has keys but no name", raw)
	}
	elem := &gnmipb.PathElem{Name: name, Key: map[string]string{}}
	rest = "[" + rest
	for len(rest) > 0 {
		if rest[0] != '[' {
			return nil, fmt.Errorf("element %q has trailing text %q after its keys", raw, rest)
		}
		end := strings.IndexByte(rest, ']')
		if end < 0 {
			return nil, fmt.Errorf("element %q has an unterminated key predicate", raw)
		}
		group := rest[1:end]
		rest = rest[end+1:]
		if strings.TrimSpace(group) == "" {
			return nil, fmt.Errorf("element %q has an empty key predicate", raw)
		}
		for _, pair := range strings.Split(group, ",") {
			k, v, ok := strings.Cut(pair, "=")
			if !ok {
				return nil, fmt.Errorf("element %q key %q is not key=value", raw, pair)
			}
			k = strings.TrimSpace(k)
			if k == "" {
				return nil, fmt.Errorf("element %q has a key with no name", raw)
			}
			elem.Key[k] = v
		}
	}
	return elem, nil
}

// pathString renders a gNMI Path back into the notation the plan used. It is
// the only way an error message about a path the node rejected can be matched
// against the plan that produced it.
func pathString(p *gnmipb.Path) string {
	if p == nil || len(p.GetElem()) == 0 {
		return "/"
	}
	var b strings.Builder
	for _, e := range p.GetElem() {
		b.WriteByte('/')
		b.WriteString(e.GetName())
		if len(e.GetKey()) == 0 {
			continue
		}
		keys := make([]string, 0, len(e.GetKey()))
		for k := range e.GetKey() {
			keys = append(keys, k)
		}
		sortStrings(keys)
		b.WriteByte('[')
		for i, k := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(k)
			b.WriteByte('=')
			b.WriteString(e.GetKey()[k])
		}
		b.WriteByte(']')
	}
	return b.String()
}

// sortStrings is an insertion sort: the slices here are key names of one path
// element (never more than a handful), and keeping it local avoids pulling
// "sort" into a file whose whole job is string handling.
func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}
