// SPDX-License-Identifier: Apache-2.0
package sdc

import (
	"errors"
	"fmt"
	"sort"

	yaml "gopkg.in/yaml.v3"
)

// RegisterError reports missing register coverage for rendered paths.
type RegisterError struct {
	MissingPaths []string
}

func (e *RegisterError) Error() string {
	return fmt.Sprintf("unregistered rendered paths: %v", e.MissingPaths)
}

// IsRegisterError returns true when err is a RegisterError.
func IsRegisterError(err error) bool {
	var re *RegisterError
	return errors.As(err, &re)
}

// ValidateSpecAgainstRegister ensures each rendered path is present in the OpenConfig-vs-SONiC register
// and prefers OpenConfig when available. This is a lightweight CI-friendly guard; the full
// SDC schema validation is integrated later.
func ValidateSpecAgainstRegister(spec map[string]any, registerYAML []byte) error {
	paths := make([]string, 0, len(spec))
	for p := range spec {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	reg := struct {
		Entries []struct {
			Path          string `yaml:"path"`
			Prefer        string `yaml:"prefer"`
			NativePath    string `yaml:"native_path"`
			Justification string `yaml:"justification"`
		} `yaml:"entries"`
	}{}
	var data []byte
	var err error
	if registerYAML == nil || len(registerYAML) == 0 {
		data, err = defaultRegister()
		if err != nil {
			return fmt.Errorf("load default register: %w", err)
		}
	} else {
		data = registerYAML
	}
	if err := yaml.Unmarshal(data, &reg); err != nil {
		return fmt.Errorf("parse register: %w", err)
	}
	byPath := map[string]string{}
	for _, e := range reg.Entries {
		byPath[e.Path] = e.Prefer
	}
	missing := []string{}
	for _, p := range paths {
		if _, ok := byPath[p]; !ok {
			missing = append(missing, p)
		}
	}
	if len(missing) > 0 {
		return &RegisterError{MissingPaths: missing}
	}
	return nil
}

func defaultRegister() ([]byte, error) {
	return []byte(`# default embedded register (generated from pkg/register/oc_vs_sonic.yaml in repo)
entries:
  - path: /interfaces/interface
    prefer: openconfig
  - path: /interfaces/interface[vtep]
    prefer: openconfig
  - path: /network-instances/network-instance
    prefer: openconfig
  - path: /network-instances/network-instance/protocols/bgp/neighbors
    prefer: openconfig
  - path: /network-instances/network-instance/bridges
    prefer: openconfig
  - path: /sonic-bgp:sonic-bgp/BGP_GLOBALS
    prefer: sonic
    native_path: /sonic-bgp:sonic-bgp/BGP_GLOBALS
    justification: SONiC BGP global settings not fully covered by OpenConfig on pinned image
  - path: /sonic-srv6:sonic-srv6/SRV6_MY_LOCATORS
    prefer: sonic
    native_path: /sonic-srv6:sonic-srv6/SRV6_MY_LOCATORS
    justification: Locator rows (key loc-<node>, /48 prefix) are SONiC-native and bootstrap-owned (FR-006); no OpenConfig equivalent on pinned image
  - path: /sonic-srv6:sonic-srv6/SRV6_MY_SIDS
    prefer: sonic
    native_path: /sonic-srv6:sonic-srv6/SRV6_MY_SIDS
    justification: Row key loc-<node>|<sid>/64 with action=uDT46 and decap_vrf; accepted by the image YANG but measured NOT to program the dataplane (spike-sid-write), so as-built uses kernel routes
`), nil
}
