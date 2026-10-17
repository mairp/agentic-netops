// SPDX-License-Identifier: Apache-2.0
// Package executorclient is the HTTP client for the fabric-executor service
// (/v1/node/apply, /v1/node/verify). It was extracted verbatim from
// controllers/sonicprovider so other reconcilers (e.g. the SRv6Service
// controller) can drive the same executor with the same error semantics:
// a 4xx is a PermanentError the executor will repeat on every retry, any
// other failure is transient.
package executorclient

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/mairp/agentic-netops/pkg/fabricplan"
)

// defaultLimit is the response body cap (4 MiB): the executor echoes op
// output, which on a pathological op could otherwise be unbounded.
const defaultLimit = 4 << 20

// Client calls the fabric-executor HTTP API. The zero value is not usable;
// construct with New.
type Client struct {
	// BaseURL is the executor's root, e.g. ExecutorURL's service DNS name.
	BaseURL string
	// HTTP is the underlying transport. nil means http.DefaultClient's
	// behavior via a lazily created client (the sonicprovider reconciler
	// previously used a 120s timeout; New keeps that default).
	HTTP *http.Client
	// limit caps how much of a response body is read. 0 means defaultLimit.
	limit int64
}

// New returns a Client for baseURL. A nil hc selects a client with the
// 120-second timeout the reconcilers have always used for executor calls.
func New(baseURL string, hc *http.Client) *Client {
	if hc == nil {
		hc = &http.Client{Timeout: 120 * time.Second}
	}
	return &Client{BaseURL: baseURL, HTTP: hc}
}

// ApplyResult mirrors fabric-executor's ApplyResponse.
type ApplyResult struct {
	Node    string `json:"node"`
	OK      bool   `json:"ok"`
	Results []struct {
		Kind   string `json:"kind"`
		OK     bool   `json:"ok"`
		Output string `json:"output,omitempty"`
		Error  string `json:"error,omitempty"`
	} `json:"results"`
}

// VerifyResult mirrors fabric-executor's VerifyResponse.
type VerifyResult struct {
	Node    string `json:"node"`
	OK      bool   `json:"ok"`
	Results []struct {
		Check  string `json:"check"`
		OK     bool   `json:"ok"`
		Actual string `json:"actual,omitempty"`
		Error  string `json:"error,omitempty"`
	} `json:"results"`
}

// Apply posts the node's rendered operations to /v1/node/apply.
func (c *Client) Apply(ctx context.Context, node string, ops []fabricplan.Op) (*ApplyResult, error) {
	payload, err := json.Marshal(map[string]any{"node": node, "ops": ops})
	if err != nil {
		return nil, err
	}
	return postJSON[ApplyResult](c.HTTP, ctx, c.BaseURL+"/v1/node/apply", payload, c.bodyLimit())
}

// Verify posts the node's rendered checks to /v1/node/verify.
func (c *Client) Verify(ctx context.Context, node string, checks []fabricplan.Check) (*VerifyResult, error) {
	payload, err := json.Marshal(map[string]any{"node": node, "checks": checks})
	if err != nil {
		return nil, err
	}
	return postJSON[VerifyResult](c.HTTP, ctx, c.BaseURL+"/v1/node/verify", payload, c.bodyLimit())
}

func (c *Client) bodyLimit() int64 {
	if c.limit > 0 {
		return c.limit
	}
	return defaultLimit
}

func postJSON[T any](hc *http.Client, ctx context.Context, url string, body []byte, limit int64) (*T, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, limit))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 300 {
		err := fmt.Errorf("executor %s: %d %s", url, resp.StatusCode, truncateStr(string(raw), 200))
		if resp.StatusCode >= 400 && resp.StatusCode < 500 {
			// The executor understood and refused: the request itself is wrong
			// (an unknown node, a malformed op). Retrying cannot change that,
			// and the caller needs to tell it apart from an outage.
			return nil, &PermanentError{err: err}
		}
		return nil, err
	}
	var out T
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("executor response: %v", err)
	}
	return &out, nil
}

// PermanentError marks a refusal the executor will give every time — a node
// the site does not have, a request it cannot parse. A transport failure is
// NOT one of these: the executor may simply be restarting.
type PermanentError struct{ err error }

func (e *PermanentError) Error() string { return e.err.Error() }
func (e *PermanentError) Unwrap() error { return e.err }

// IsPermanent reports whether err is an executor refusal (HTTP 4xx).
func IsPermanent(err error) bool {
	var perm *PermanentError
	return errors.As(err, &perm)
}

func truncateStr(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
