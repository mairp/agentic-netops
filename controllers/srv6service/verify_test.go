// SPDX-License-Identifier: Apache-2.0
package srv6service

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/mairp/agentic-netops/pkg/executorclient"
	"github.com/mairp/agentic-netops/pkg/fabricplan"
	"github.com/mairp/agentic-netops/pkg/reasons"
)

// fakeExecutor records the checks it was asked to verify and answers from a
// scripted function, so verify stages are tested without an HTTP endpoint.
type fakeExecutor struct {
	verified []fabricplan.Check
	answer   func(node string, checks []fabricplan.Check) *executorclient.VerifyResult
}

func (f *fakeExecutor) Apply(ctx context.Context, node string, ops []fabricplan.Op) (*executorclient.ApplyResult, error) {
	return nil, errors.New("not implemented")
}

func (f *fakeExecutor) Verify(ctx context.Context, node string, checks []fabricplan.Check) (*executorclient.VerifyResult, error) {
	f.verified = append(f.verified, checks...)
	if f.answer == nil {
		return nil, errors.New("no script")
	}
	return f.answer(node, checks), nil
}

func verifyAnswer(ok bool, actual, errText string) func(string, []fabricplan.Check) *executorclient.VerifyResult {
	return func(node string, checks []fabricplan.Check) *executorclient.VerifyResult {
		res := &executorclient.VerifyResult{Node: node, OK: ok}
		for range checks {
			res.Results = append(res.Results, struct {
				Check  string `json:"check"`
				OK     bool   `json:"ok"`
				Actual string `json:"actual,omitempty"`
				Error  string `json:"error,omitempty"`
			}{Check: "checks[0].redis-hget", OK: ok, Actual: actual, Error: errText})
		}
		return res
	}
}

func TestLocatorCheckReadsTheBootstrapRowField(t *testing.T) {
	// The bootstrap writes SRV6_MY_LOCATORS|loc-<node> with field `prefix`
	// carrying the BARE /48 address (configure-fabric.sh writes `${loc%/*}`:
	// `fcbb:bbbb:3::`, never `fcbb:bbbb:3::/48`). The probe must read that
	// field and expect the bare address — a key-name scan can never carry a
	// prefix length, and the /48 form made the bring-up sample report
	// LocatorMissing on a healthy lab.
	ck := locatorCheck("leaf01", "fcbb:bbbb:3::/48")
	if ck.Type != "redis-hget" {
		t.Fatalf("check type = %q, want redis-hget", ck.Type)
	}
	if ck.RedisKey != "SRV6_MY_LOCATORS|loc-leaf01" {
		t.Fatalf("redisKey = %q, want SRV6_MY_LOCATORS|loc-leaf01", ck.RedisKey)
	}
	if ck.RedisField != "prefix" {
		t.Fatalf("redisField = %q, want prefix", ck.RedisField)
	}
	if ck.Expect != "fcbb:bbbb:3::" {
		t.Fatalf("expect = %q, want the bare address fcbb:bbbb:3::", ck.Expect)
	}
}

func TestVerifyNodeAcceptsTheBareAddressRow(t *testing.T) {
	ex := &fakeExecutor{answer: verifyAnswer(true, "fcbb:bbbb:3::", "")}
	res := verifyNode(context.Background(), ex, "leaf01", nil, "fcbb:bbbb:3::/48")
	if res.Err != nil {
		t.Fatalf("unexpected error: %v", res.Err)
	}
	if res.Refusal != nil {
		t.Fatalf("unexpected refusal: %+v", res.Refusal)
	}
	if !res.Verified {
		t.Fatal("node with the bare-address locator row must verify")
	}
	if len(ex.verified) != 1 || ex.verified[0].Type != "redis-hget" {
		t.Fatalf("locator probe = %+v, want a single redis-hget check", ex.verified)
	}
}

func TestVerifyNodeRefusesLocatorMissingNamingTheNode(t *testing.T) {
	ex := &fakeExecutor{answer: verifyAnswer(false, "", `observed "" != expect "fcbb:bbbb:4::"`)}
	res := verifyNode(context.Background(), ex, "leaf02", nil, "fcbb:bbbb:4::/48")
	if res.Refusal == nil {
		t.Fatal("a missing locator row must refuse")
	}
	if res.Refusal.Reason != reasons.ReasonLocatorMissing {
		t.Fatalf("reason = %q, want LocatorMissing", res.Refusal.Reason)
	}
	if !strings.Contains(res.Refusal.Message, "leaf02") {
		t.Fatalf("message %q must name the node", res.Refusal.Message)
	}
}

func TestVerifyNodeReportsFailingPlanCheck(t *testing.T) {
	checks := []fabricplan.Check{{Type: "vtysh-contains", Command: "show ip vrf", Expect: "Vrf1"}}
	calls := 0
	ex := &fakeExecutor{answer: func(node string, checks []fabricplan.Check) *executorclient.VerifyResult {
		calls++
		if calls == 1 {
			// The locator probe passes; the failure must come from the plan's
			// own check.
			return verifyAnswer(true, "fcbb:bbbb:3::", "")(node, checks)
		}
		res := &executorclient.VerifyResult{Node: node, OK: false}
		for i := range checks {
			res.Results = append(res.Results, struct {
				Check  string `json:"check"`
				OK     bool   `json:"ok"`
				Actual string `json:"actual,omitempty"`
				Error  string `json:"error,omitempty"`
			}{Check: "checks[0]." + checks[i].Type, OK: false, Error: "observed output missing Vrf1"})
		}
		return res
	}}
	res := verifyNode(context.Background(), ex, "leaf01", checks, "fcbb:bbbb:3::/48")
	if res.Refusal == nil {
		t.Fatal("a failing plan check must refuse")
	}
	if res.Refusal.Reason != reasons.ReasonCheckFailed {
		t.Fatalf("reason = %q, want CheckFailed", res.Refusal.Reason)
	}
	if !strings.Contains(res.Refusal.Message, "checks[0].vtysh-contains") ||
		!strings.Contains(res.Refusal.Message, "leaf01") {
		t.Fatalf("message %q must name the check and the node", res.Refusal.Message)
	}
}
