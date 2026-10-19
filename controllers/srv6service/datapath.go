// SPDX-License-Identifier: Apache-2.0
//
// Data-path stage, T386/T387: the probe-ping client-to-client check runs
// ONCE, at first activation — the only time. status.dataPath.checkedAt is
// zero until the probe has passed, and it is set (with result "pass") on
// success; a failed ping gives a non-terminal DataPathFailed and is retried
// on the failure backoff, never treated as a config error.
//
// The missing-probe-host case never reaches this step: rule C8 refuses it
// terminally BEFORE any claim (controllers/srv6service/capability.go), so a
// service being rendered always has a registered probe host for each
// attachment. The datapath test asserts that pipeline property structurally:
// its fake capability record lacks srv6-probe-attachments and the pipeline
// stops at C8, never invoking the executor at all.
package srv6service

import (
	"context"
	"fmt"
	"net/netip"

	"github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/fabricplan"
	"github.com/mairp/agentic-netops/pkg/reasons"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Probe constants: the packet the recipe proves (data-model.md §8.7 —
// 8900-byte payload with DF passes both directions under the fabric MTU;
// count 3 keeps the check bounded).
const (
	probeSize     = 8900
	probeCount    = 3
	probeHostByte = 2 // the client container sits at .2 (§8.7); .1 is the leaf
)

// dataPathCheck builds the single probe-ping check: the probe host of the
// first attachment reaches the peer attachment's client address.
func dataPathCheck(svc *v1alpha1.SRv6Service, alloc *Allocation) (fabricplan.Check, error) {
	a0, a1 := svc.Spec.Attachments[0], svc.Spec.Attachments[1]
	peer, err := clientAddr(alloc.Allocations.ClientPrefixes[a1.Node])
	if err != nil {
		return fabricplan.Check{}, err
	}
	return fabricplan.Check{
		Type:      "probe-ping",
		ProbeFrom: a0.Node + "/" + a0.Port,
		ProbeTo:   a1.Node + "/" + a1.Port,
		Addr:      peer,
		Size:      probeSize,
		Count:     probeCount,
	}, nil
}

// clientAddr derives the client container address (host octet .2) from the
// attachment's claimed /24.
func clientAddr(prefix string) (string, error) {
	p, err := netip.ParsePrefix(prefix)
	if err != nil {
		return "", fmt.Errorf("client prefix %q: %w", prefix, err)
	}
	m := p.Masked().Addr().As4()
	m[3] = probeHostByte
	return netip.AddrFrom4(m).String(), nil
}

// runDataPath executes the probe once. Returns the pass verdict, a human
// detail for the condition message, and a transport error (transient).
func runDataPath(ctx context.Context, ex Executor, svc *v1alpha1.SRv6Service, alloc *Allocation) (bool, string, error) {
	chk, err := dataPathCheck(svc, alloc)
	if err != nil {
		return false, "", err
	}
	res, err := ex.Verify(ctx, svc.Spec.Attachments[0].Node, []fabricplan.Check{chk})
	if err != nil {
		return false, "", err
	}
	if res == nil || len(res.Results) == 0 {
		return false, "probe produced no result", nil
	}
	r := res.Results[0]
	if r.OK {
		return true, fmt.Sprintf("probe %s -> %s (%d bytes x%d, DF): pass", chk.ProbeFrom, chk.Addr, probeSize, probeCount), nil
	}
	detail := r.Error
	if detail == "" {
		detail = r.Actual
	}
	if detail == "" {
		detail = "no echoes received"
	}
	return false, fmt.Sprintf("probe %s -> %s failed: %s", chk.ProbeFrom, chk.Addr, detail), nil
}

// dataPathRefusal is the DataPathFailed refusal (non-terminal: the failure
// is traffic, not configuration).
func dataPathRefusal(detail string) *Refusal {
	return &Refusal{
		Reason:  reasons.ReasonDataPathFailed,
		Message: detail,
		Kind:    refusalDataPath,
	}
}

// dataPathPassed reports whether the first-activation probe already passed.
func dataPathPassed(svc *v1alpha1.SRv6Service) bool {
	return svc.Status.DataPath != nil && !svc.Status.DataPath.CheckedAt.IsZero()
}

// setDataPathPassed stamps the successful first-activation probe.
func setDataPathPassed(st *v1alpha1.SRv6ServiceStatus) {
	// nowFunc is the package's clock seam (tests pin it).
	st.DataPath = &v1alpha1.DataPathStatus{
		CheckedAt: metav1.NewTime(nowFunc()),
		Result:    "pass",
	}
}
