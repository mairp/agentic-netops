// SPDX-License-Identifier: Apache-2.0
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/mairp/agentic-netops/pkg/migration"
)

// Deterministic CLI: reads a JSON array or object from stdin or --file, validates all-or-nothing,
// then emits a single concatenated YAML stream of Kubenet Network resources in stable order.
// No cluster interaction occurs in this phase.
func main() {
	var file string
	flag.StringVar(&file, "file", "", "Path to normalized service input JSON (object or array); default stdin")
	flag.Parse()

	var data []byte
	var err error
	if file == "" {
		data, err = io.ReadAll(os.Stdin)
	} else {
		data, err = os.ReadFile(file)
	}
	if err != nil {
		fatal(fmt.Errorf("read input: %w", err))
	}
	// Strict parsing rejects unknown fields and raw CLI leakage.
	inputs, err := migration.ParseStrictBatch(data)
	if err != nil {
		// Emit structured JSON error (consistent shape) before any output.
		msg := migration.MarshalError(err)
		fmt.Fprintln(os.Stderr, msg)
		os.Exit(2)
	}
	if err := processBatch(inputs); err != nil {
		fatal(err)
	}
}

func processBatch(inputs []migration.ServiceInput) error {
	// Detect duplicate IDs within the batch for collision reporting.
	ids := map[string]int{}
	for i, in := range inputs {
		if _, ok := ids[in.ServiceID]; ok {
			ids[in.ServiceID] = -1
		} else {
			ids[in.ServiceID] = i
		}
	}
	// Validate all-or-nothing; collect causes with stable ordering by index.
	var causes []string
	for i := range inputs {
		in := inputs[i]
		dup := false
		if idx, ok := ids[in.ServiceID]; ok && idx == -1 {
			dup = true
		}
		if err := in.ValidateAllOrNothing(i, dup); err != nil {
			if ve, ok := err.(*migration.ValidationError); ok {
				causes = append(causes, ve.Causes...)
			} else {
				causes = append(causes, err.Error())
			}
		}
	}
	if len(causes) > 0 {
		// Emit structured JSON error to stderr and exit non-zero.
		enc := json.NewEncoder(os.Stderr)
		enc.SetIndent("", "  ")
		_ = enc.Encode(map[string]any{"error": "validation", "causes": causes})
		os.Exit(2)
	}
	// Translate in order; separator is "---\n"
	for i := range inputs {
		in := inputs[i]
		bundle, err := migration.Translate(&in)
		if err != nil {
			return err
		}
		if i > 0 {
			fmt.Println("---")
		}
		fmt.Println(bundle.NetworkYAML)
	}
	return nil
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "migration-translator: %v\n", err)
	os.Exit(1)
}
