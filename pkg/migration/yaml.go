// SPDX-License-Identifier: Apache-2.0
package migration

import (
	"sigs.k8s.io/yaml"
)

// jsonToYAML converts JSON to YAML deterministically using pinned sigs.k8s.io/yaml.
func jsonToYAML(j []byte) ([]byte, error) {
	return yaml.JSONToYAML(j)
}
