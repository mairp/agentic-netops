// SPDX-License-Identifier: Apache-2.0
package kuid

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// PollInterval is how often WaitForClaim re-reads the claim.
const PollInterval = 100 * time.Millisecond

// ClaimResult is the value a served claim produced: the allocated integer
// (`status.id`, the GENID shape) and/or the allocated address or prefix
// (`status.address`, the ipam shape).
type ClaimResult struct {
	ID      int
	Address string
}

// WaitForClaim polls the claim until an allocated value appears in its
// status, or until the deadline (or ctx) expires. A TimeoutError names the
// pool and the claim and carries the last observed status summary. The
// correlation id is assumed to have been stamped at creation time (CreateClaim
// does that before any wait).
func WaitForClaim(ctx context.Context, c client.Client, ref ClaimRef, timeout time.Duration) (ClaimResult, error) {
	deadline := time.Now().Add(timeout)
	var last *unstructured.Unstructured
	for {
		u, err := getClaim(ctx, c, ref)
		if err == nil {
			last = u
			if res, done := claimValue(u); done {
				return res, nil
			}
		} else {
			last = nil
			if ctx.Err() != nil {
				return ClaimResult{}, &TimeoutError{Pool: ref.Pool.Name, Name: ref.Name, LastStatus: "<claim unread: " + err.Error() + ">"}
			}
		}
		if !time.Now().Before(deadline) {
			return ClaimResult{}, &TimeoutError{
				Pool:       ref.Pool.Name,
				Name:       ref.Name,
				LastStatus: statusSummary(last),
			}
		}
		select {
		case <-ctx.Done():
			return ClaimResult{}, &TimeoutError{Pool: ref.Pool.Name, Name: ref.Name, LastStatus: statusSummary(last)}
		case <-time.After(PollInterval):
		}
	}
}

// claimValue extracts the allocated value from a claim's status. The served
// `*.be.kuid.dev` claims report the integer in status.id (GENID) and the
// address or prefix in status.address / status.prefix (ipam — the live
// IPClaim shape measured 2026-10-16 was `prefix: 192.168.0.0/24` next to a
// Ready=True condition). Not-ready is (result, false).
func claimValue(u *unstructured.Unstructured) (ClaimResult, bool) {
	status, ok := u.Object["status"].(map[string]any)
	if !ok {
		return ClaimResult{}, false
	}
	res := ClaimResult{}
	done := false
	if raw, ok := status["id"]; ok && raw != nil {
		if id, err := toInt(raw); err == nil {
			res.ID = id
			done = true
		}
	}
	for _, key := range []string{"address", "prefix"} {
		raw, ok := status[key]
		if !ok {
			continue
		}
		if s, ok := raw.(string); ok && s != "" {
			res.Address = s
			done = true
		}
	}
	return res, done
}

// toInt converts a status scalar (JSON number or string) to an int,
// mirroring kuid.py's _claim_id tolerance.
func toInt(raw any) (int, error) {
	switch v := raw.(type) {
	case int:
		return v, nil
	case int64:
		return int(v), nil
	case float64:
		return int(v), nil
	case string:
		return strconv.Atoi(v)
	default:
		return 0, fmt.Errorf("not an integer: %v", raw)
	}
}

// statusSummary renders the last observed status for error messages.
func statusSummary(u *unstructured.Unstructured) string {
	if u == nil {
		return "<none>"
	}
	status, ok := u.Object["status"].(map[string]any)
	if !ok {
		return "<empty>"
	}
	b, err := json.Marshal(status)
	if err != nil {
		return "<unencodable>"
	}
	return string(b)
}
