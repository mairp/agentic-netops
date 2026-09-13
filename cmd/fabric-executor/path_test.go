// SPDX-License-Identifier: Apache-2.0
package main

import (
	"reflect"
	"testing"

	gnmipb "github.com/openconfig/gnmi/proto/gnmi"
)

func elem(name string, kv ...string) *gnmipb.PathElem {
	e := &gnmipb.PathElem{Name: name}
	if len(kv) > 0 {
		e.Key = map[string]string{}
		for i := 0; i+1 < len(kv); i += 2 {
			e.Key[kv[i]] = kv[i+1]
		}
	}
	return e
}

func TestParsePath(t *testing.T) {
	cases := []struct {
		in   string
		want []*gnmipb.PathElem
	}{
		{"/", nil},
		{"", nil},
		{"/system/information/version", []*gnmipb.PathElem{elem("system"), elem("information"), elem("version")}},
		// The case that makes a naive '/' split wrong: the interface NAME
		// contains a slash, and ethernet-1 / 3 are not two path elements.
		{
			"/interface[name=ethernet-1/3]/subinterface[index=130]/oper-state",
			[]*gnmipb.PathElem{
				elem("interface", "name", "ethernet-1/3"),
				elem("subinterface", "index", "130"),
				elem("oper-state"),
			},
		},
		// Two keys on one element, the acl-filter shape the renderer emits.
		{
			"/acl/acl-filter[name=acl-svc-acl-ingress,type=ipv4]/entry[sequence-id=100]/statistics",
			[]*gnmipb.PathElem{
				elem("acl"),
				elem("acl-filter", "name", "acl-svc-acl-ingress", "type", "ipv4"),
				elem("entry", "sequence-id", "100"),
				elem("statistics"),
			},
		},
		// The same element written as two bracket groups means the same thing.
		{
			"/acl/acl-filter[name=f][type=ipv6]",
			[]*gnmipb.PathElem{elem("acl"), elem("acl-filter", "name", "f", "type", "ipv6")},
		},
		{
			"/tunnel-interface[name=vxlan1]/vxlan-interface[index=10150]/bridge-table/multicast-destinations/destination",
			[]*gnmipb.PathElem{
				elem("tunnel-interface", "name", "vxlan1"),
				elem("vxlan-interface", "index", "10150"),
				elem("bridge-table"), elem("multicast-destinations"), elem("destination"),
			},
		},
		// An afi-safi key whose value carries a hyphen and a colon-free name.
		{
			"/network-instance[name=default]/bgp-rib/afi-safi[afi-safi-name=evpn]/evpn/rib-in-out/rib-out-post/ip-prefix-routes",
			[]*gnmipb.PathElem{
				elem("network-instance", "name", "default"),
				elem("bgp-rib"),
				elem("afi-safi", "afi-safi-name", "evpn"),
				elem("evpn"), elem("rib-in-out"), elem("rib-out-post"), elem("ip-prefix-routes"),
			},
		},
		// A key value that is itself a path (the executor never emits this, but
		// a plan may name a leafref value and it must not be split).
		{
			"/network-instance[name=Vrf-a]/interface[name=ethernet-1/4.4018]",
			[]*gnmipb.PathElem{
				elem("network-instance", "name", "Vrf-a"),
				elem("interface", "name", "ethernet-1/4.4018"),
			},
		},
	}
	for _, tc := range cases {
		got, err := parsePath(tc.in)
		if err != nil {
			t.Errorf("parsePath(%q): %v", tc.in, err)
			continue
		}
		if !reflect.DeepEqual(got.GetElem(), tc.want) {
			t.Errorf("parsePath(%q) =\n  %v\nwant\n  %v", tc.in, got.GetElem(), tc.want)
		}
	}
}

func TestParsePathRefusesMalformed(t *testing.T) {
	for _, bad := range []string{
		"interface[name=x]",            // no leading slash
		"/interface[name=x",            // unterminated predicate
		"/interface[name]",             // not key=value
		"/interface[]",                 // empty predicate
		"/[name=x]",                    // keys with no element name
		"/interface[name=x]trailing",   // text after the predicate
		"/interface//subinterface",     // empty element
		"/interface[name=x]/sub]iface", // stray close bracket
		"/interface[=x]",               // key with no name
	} {
		if got, err := parsePath(bad); err == nil {
			t.Errorf("parsePath(%q) accepted a malformed path: %v", bad, got)
		}
	}
}

// pathString is what error messages use to point at the plan entry that failed,
// so it has to round-trip the notation the renderer wrote.
func TestPathStringRoundTrips(t *testing.T) {
	for _, in := range []string{
		"/",
		"/system/information/version",
		"/interface[name=ethernet-1/3]/subinterface[index=130]/oper-state",
		"/acl/acl-filter[name=f,type=ipv4]/entry[sequence-id=100]",
	} {
		p, err := parsePath(in)
		if err != nil {
			t.Fatalf("parsePath(%q): %v", in, err)
		}
		if got := pathString(p); got != in {
			t.Errorf("pathString(parsePath(%q)) = %q", in, got)
		}
	}
}
