// SPDX-License-Identifier: Apache-2.0
//
// Identifier claims, T374-T377. The profile of data-model.md §8.1: one
// service id (the VRF name id, Vrf<service-id>), one client /24 per
// attachment, and — for a mac-vrf — the operator-named VLAN reserved under
// the service's correlation id. Every claim is labelled with the correlation
// id (label agentic-netops.io/correlation-id, else the object UID).
//
// Order guarantees the spec demands:
//   - claims are created only after site validation and the capability check
//     pass (the caller's pipeline stage order, T396);
//   - pool exhaustion releases every partial claim
//     (kuid.ReleaseByCorrelationID) BEFORE any device write — claiming is a
//     pipeline stage before apply, and the exhaustion path releases here;
//   - a VLAN value held by another correlation id is a terminal VlanInUse
//     naming the holder; reserving OUR own value again is a no-op.
package srv6service

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/kuid"
	"github.com/mairp/agentic-netops/pkg/reasons"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// srv6SIDFunction is the service SID function the lab proves end to end
// (data-model.md §8.2, function 11): the /64 in the node locator's function
// space the service decapsulates on.
const srv6SIDFunction = "11"

// claimWaitTimeout bounds one WaitForClaim poll loop. The GENID family's
// broken served path is the kuid Lease fallback's trigger, so the first wait
// is short by design.
const claimWaitTimeout = 2 * time.Second

// leaseIDRange is the fallback service-id range (1..999) pkg/kuid provides
// when the served claim API cannot allocate (research.md Decision 11).
const (
	leaseIDFirst = 1
	leaseIDLast  = 999
)

// Allocation is what Allocate produces and the plan consumes: the §2 status
// allocations plus the per-node service SIDs derived from the bootstrap
// locators (read-only; the controller never writes a locator).
type Allocation struct {
	Allocations *v1alpha1.Allocations
	// ServiceSIDs maps attachment node to its service SID /64
	// (fcbb:bbbb:<node>:<function>::/64).
	ServiceSIDs map[string]string
}

// serviceSIDFromLocator derives fcbb:bbbb:<node>:<fn>::/64 from the /48.
func serviceSIDFromLocator(locator string) (string, error) {
	if !strings.HasSuffix(locator, "::/48") {
		return "", fmt.Errorf("locator %q is not a /48", locator)
	}
	return strings.TrimSuffix(locator, "::/48") + ":" + srv6SIDFunction + "::/64", nil
}

// serviceSIDs derives every attachment node's service SID from the facts'
// bootstrap locators. A node without a locator is an error (FR-006: the
// locator is bootstrap-owned; it is read, never written).
func serviceSIDs(svc *v1alpha1.SRv6Service, locators map[string]string) (map[string]string, error) {
	out := map[string]string{}
	for _, att := range svc.Spec.Attachments {
		loc, ok := locators[att.Node]
		if !ok || loc == "" {
			return nil, fmt.Errorf("no bootstrap locator carried for attachment node %s", att.Node)
		}
		sid, err := serviceSIDFromLocator(loc)
		if err != nil {
			return nil, err
		}
		out[att.Node] = sid
	}
	return out, nil
}

// reuseAllocation reports whether the status allocations still serve this
// object: same correlation id, a client prefix for every attachment and,
// for a mac-vrf, the same VLAN reservation. Claims are deterministic per
// correlation id, so re-claiming would be a no-op; reusing skips the wait.
func reuseAllocation(svc *v1alpha1.SRv6Service, corrID string, locators map[string]string) *Allocation {
	st := svc.Status.Allocations
	if st == nil || svc.Status.CorrelationID != corrID || st.ServiceID <= 0 || st.VRF == "" {
		return nil
	}
	for _, att := range svc.Spec.Attachments {
		if st.ClientPrefixes[att.Node] == "" {
			return nil
		}
	}
	if svc.Spec.VLAN != nil && (st.VLAN == nil || *st.VLAN != *svc.Spec.VLAN) {
		return nil
	}
	sids, err := serviceSIDs(svc, locators)
	if err != nil {
		return nil
	}
	return &Allocation{Allocations: st, ServiceSIDs: sids}
}

// Allocate claims the §8.1 profile for the service. On failure it releases
// every partial claim where the spec requires it and returns a *Refusal
// (terminal) or a plain error (transient — requeue with backoff).
func Allocate(ctx context.Context, c client.Client, svc *v1alpha1.SRv6Service, corrID string, locators map[string]string) (*Allocation, error) {
	sids, err := serviceSIDs(svc, locators)
	if err != nil {
		// Bootstrap prerequisite missing: the §6 reason for a bootstrap-owned
		// locator problem is LocatorMissing, never a repair by this
		// controller.
		return nil, &Refusal{Reason: reasons.ReasonLocatorMissing, Message: err.Error(), Kind: refusalLocator}
	}

	// Service id: served claim first, Lease fallback when the served path
	// cannot allocate (pkg/kuid's documented GENID fallback over 1..999).
	// The fallback has TWO triggers: the wait timeout, and the authority
	// itself refusing to serve the claim — on the pinned server the GENID
	// family fails at CREATE time (`index kuid-system.srv6-service-ids not
	// initialized`; the index was never stored, docs/CLUSTER_REBUILD_FINDINGS.md
	// §2), so the wait is never even reached.
	ref, cerr := kuid.CreateServiceIDClaim(ctx, c, corrID)
	var res kuid.ClaimResult
	switch {
	case cerr == nil:
		if werr := waitServiceClaim(ctx, c, ref, &res); werr != nil {
			return nil, werr
		}
	case kuid.IsUnavailable(cerr):
		// The served path is dead: straight to the fallback.
	default:
		return nil, transientOrRefusal(cerr)
	}
	// res.ID == 0 is "no value yet": kuid ids start at 1 (the Lease range
	// 1..999, kuid.py's range too), so a served claim can never produce 0.
	if res.ID == 0 {
		id, ferr := kuid.AllocateLeaseID(ctx, c, "service", kuid.ServiceIDPool.Name, leaseIDFirst, leaseIDLast, corrID)
		if ferr != nil {
			if kuid.IsExhaustion(ferr) {
				return nil, exhausted(ctx, c, corrID, kuid.ServiceIDPool.Name, ferr)
			}
			return nil, transientOrRefusal(ferr)
		}
		res.ID = id
	}

	// Client /24 per attachment.
	prefixes := map[string]string{}
	for _, att := range orderedAttachments(svc) {
		cref, err := kuid.CreateClientPrefixClaim(ctx, c, corrID, att.Node+"-"+att.Port)
		if err != nil {
			return nil, transientOrRefusal(err)
		}
		cres, err := kuid.WaitForClaim(ctx, c, cref, claimWaitTimeout)
		if err != nil {
			// The ipam family works on the pinned server; a timeout here is
			// a slow authority, not an exhaustion: requeue with backoff.
			return nil, fmt.Errorf("client /24 claim for %s not ready: %w", att.Node, err)
		}
		prefixes[att.Node] = cres.Address
	}

	alloc := &v1alpha1.Allocations{
		ServiceID:      int64(res.ID),
		VRF:            fmt.Sprintf("Vrf%d", res.ID),
		ClientPrefixes: prefixes,
	}

	// mac-vrf: reserve the operator-named VLAN under the correlation id.
	if svc.Spec.VLAN != nil {
		if _, err := kuid.ReserveVLAN(ctx, c, corrID, *svc.Spec.VLAN); err != nil {
			if kuid.IsCollision(err) {
				// FR-020a: the claims already made for this service are
				// released, still before any device write.
				_ = releaseAll(ctx, c, corrID)
				return nil, &Refusal{
					Reason:  reasons.ReasonVlanInUse,
					Message: fmt.Sprintf("vlan %d is reserved by another holder: %v", *svc.Spec.VLAN, err),
					Kind:    refusalVlan,
				}
			}
			return nil, transientOrRefusal(err)
		}
		v := *svc.Spec.VLAN
		alloc.VLAN = &v
	}

	return &Allocation{Allocations: alloc, ServiceSIDs: sids}, nil
}

// waitServiceClaim waits out the served service-id claim into res. A wait
// timeout — or the authority dying mid-wait (UnavailableError) — leaves res
// untouched and returns nil, so the caller's `res.ID == 0` check drives the
// Lease fallback. Any other error is mapped and returned.
func waitServiceClaim(ctx context.Context, c client.Client, ref kuid.ClaimRef, res *kuid.ClaimResult) error {
	out, err := kuid.WaitForClaim(ctx, c, ref, claimWaitTimeout)
	if err == nil {
		*res = out
		return nil
	}
	if kuid.IsTimeout(err) || kuid.IsUnavailable(err) {
		return nil
	}
	return transientOrRefusal(err)
}

// exhausted releases the partial claims and returns the terminal
// PoolExhausted refusal naming the pool.
func exhausted(ctx context.Context, c client.Client, corrID, pool string, err error) *Refusal {
	_ = releaseAll(ctx, c, corrID)
	return &Refusal{
		Reason:  reasons.ReasonPoolExhausted,
		Message: fmt.Sprintf("pool %s is exhausted: %v (partial claims released)", pool, err),
		Kind:    refusalPool,
	}
}

// releaseAll releases every claim carrying the correlation id. Best effort
// on paths that already hold a Refusal to report.
func releaseAll(ctx context.Context, c client.Client, corrID string) error {
	_, err := kuid.ReleaseByCorrelationID(ctx, c, corrID)
	return err
}

// orderedAttachments returns the attachments in deterministic (sorted node)
// order so claim creation order is stable across reconciles.
func orderedAttachments(svc *v1alpha1.SRv6Service) []v1alpha1.Attachment {
	out := append([]v1alpha1.Attachment(nil), svc.Spec.Attachments...)
	sort.Slice(out, func(i, j int) bool { return out[i].Node < out[j].Node })
	return out
}

// transientOrRefusal maps a kuid error onto the pipeline's vocabulary:
// exhaustion -> terminal PoolExhausted; anything else stays a plain
// (transient) error and requeues with backoff.
func transientOrRefusal(err error) error {
	if kuid.IsExhaustion(err) {
		return &Refusal{Reason: reasons.ReasonPoolExhausted, Message: err.Error(), Kind: refusalPool}
	}
	return err
}
