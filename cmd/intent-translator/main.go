// SPDX-License-Identifier: Apache-2.0
//
// intent-translator — feature 002 single-translation-implementation sidecar.
//
// A thin HTTP wrapper over pkg/migration so the Python allocator/deployer can
// reach the Go translator WITHOUT any translation logic being reimplemented in
// Python (FR-011, the pkg/migration single-translator rule). It adds no
// semantics: it calls the same migration.ParseStrictBatch ->
// ServiceInput.ValidateAllOrNothing -> migration.Translate path that
// cmd/migration-translator/main.go already calls.
//
// Deployment (contracts/translator-api.md): a sidecar container in the
// deployer Pod, bound to 127.0.0.1:8090. No Service, no NetworkPolicy
// allowance, no cluster-visible surface. The call is always pod-local.
//
// Behavior:
//   - POST /v1/translate accepts a NormalizedServiceIntent object or array
//     (normalized-service-intent.schema.json shape == ServiceInput JSON).
//   - 200: {"manifests": [...], "yaml": "..."} — deterministic, stable order.
//   - 422: {"error": "validation", "causes": [...]} — all-or-nothing; a single
//     rejection fails the whole batch and no manifest is returned.
//   - GET /healthz: pod-local liveness for the sidecar probes.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"

	"sigs.k8s.io/yaml"

	"github.com/mairp/ainetops/pkg/migration"
)

const (
	defaultAddr   = "127.0.0.1:8090" // pod-local only; never cluster-visible
	translatorID  = "intent-translator"
)

// translateResponse is the 200 body (contracts/translator-api.md).
type translateResponse struct {
	Manifests []map[string]any `json:"manifests"`
	YAML      string           `json:"yaml"`
}

func main() {
	addr := os.Getenv("INTENT_TRANSLATOR_ADDR")
	if addr == "" {
		addr = defaultAddr
	}

	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/translate", handleTranslate)
	mux.HandleFunc("GET /healthz", handleHealthz)

	srv := &http.Server{Addr: addr, Handler: mux}
	log.Printf("%s: listening on %s (pod-local; no cluster-visible surface)", translatorID, addr)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("%s: server: %v", translatorID, err)
	}
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// handleTranslate implements POST /v1/translate. All-or-nothing: validation
// runs over the whole batch before any output, exactly as the CLI does.
func handleTranslate(w http.ResponseWriter, r *http.Request) {
	data, err := io.ReadAll(r.Body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid", "causes": []string{fmt.Sprintf("read body: %v", err)}})
		return
	}

	// Strict parsing rejects unknown fields so the failure lands at the agent
	// boundary (FR-017): the Python model must be equally strict.
	inputs, err := migration.ParseStrictBatch(data)
	if err != nil {
		// MarshalError emits {"error": "validation", "causes": [...]} — the
		// exact 422 shape the contract requires.
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = w.Write([]byte(migration.MarshalError(err)))
		return
	}

	// Detect duplicate IDs within the batch for collision reporting (same as the CLI).
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
		dup := ids[in.ServiceID] == -1
		if err := in.ValidateAllOrNothing(i, dup); err != nil {
			if ve, ok := err.(*migration.ValidationError); ok {
				causes = append(causes, ve.Causes...)
			} else {
				causes = append(causes, err.Error())
			}
		}
	}
	if len(causes) > 0 {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "validation", "causes": causes})
		return
	}

	// Translate in order; the YAML stream uses the CLI's "---\n" separator.
	resp := translateResponse{Manifests: []map[string]any{}}
	var yamls []string
	for i := range inputs {
		in := inputs[i]
		bundle, err := migration.Translate(&in)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "translation", "causes": []string{err.Error()}})
			return
		}
		manifest, err := manifestFromYAML(bundle.NetworkYAML)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "translation", "causes": []string{fmt.Sprintf("input[%d]: %v", i, err)}})
			return
		}
		resp.Manifests = append(resp.Manifests, manifest)
		yamls = append(yamls, bundle.NetworkYAML)
	}
	resp.YAML = strings.Join(yamls, "---\n")

	writeJSON(w, http.StatusOK, resp)
}

// manifestFromYAML converts one deterministic Network YAML document into a
// JSON object for the "manifests" array. sigs.k8s.io/yaml is the same pinned
// converter pkg/migration itself uses to emit YAML.
func manifestFromYAML(doc string) (map[string]any, error) {
	jsonBytes, err := yaml.YAMLToJSON([]byte(doc))
	if err != nil {
		return nil, fmt.Errorf("convert manifest YAML to JSON: %w", err)
	}
	var m map[string]any
	if err := json.Unmarshal(jsonBytes, &m); err != nil {
		return nil, fmt.Errorf("parse manifest JSON: %w", err)
	}
	return m, nil
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	_ = enc.Encode(v)
}
