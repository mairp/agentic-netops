// SPDX-License-Identifier: Apache-2.0
package sdc

import (
	"fmt"
	"strings"
)

// OfflineValidate performs a lightweight schema/path shape validation without contacting SDC.
// It rejects specs that contain keys that are not absolute gNMI-like paths (must start with '/').
// Future work: integrate with pinned SDC offline validator and SONiC/OpenConfig YANG models.
func OfflineValidate(spec map[string]any) error {
	for k := range spec {
		if !strings.HasPrefix(k, "/") {
			return fmt.Errorf("invalid rendered path (must start with '/'): %s", k)
		}
	}
	return nil
}
