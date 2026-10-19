// SPDX-License-Identifier: Apache-2.0
//
// Path stage, T520/T521 (plan 10-05/10-06): the device-observed spine a
// steered service rides. Called from the reconcile AFTER verify.
//
//   - the observation is one READ-ONLY command check (`ip -6 route show`,
//     empty Expect — the executor's strings.Contains against "" always
//     passes, so the check only carries the observed table back) against the
//     ingress leaf: data-model §8.6, "preferred" is the pin's via address;
//   - `status.activePath` names the spine whose leg the pin points at — the
//     device, never the spec echo; empty when not steered (data-model §2);
//   - a pin that names NEITHER leg (deleted, or via an unknown address)
//     refuses `PathDown` naming the missing path — a repair here would
//     re-create the preferred pin the operator's failure action removed;
//   - a pin on the ALTERNATE leg means the preferred-pin checks fail BY
//     DESIGN (FR-026: traffic moves to the other spine): the stage tells the
//     reconcile to treat that failure as the failover state, not drift, so
//     the drift repair cannot undo the operator's switch.
package srv6service

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/fabricplan"
	"github.com/mairp/agentic-netops/pkg/reasons"
)

// pathObservation is what the device says about a steered service's pin.
type pathObservation struct {
	// Active is the spine whose leg the pin's via address names; empty when
	// no known leg serves the pin.
	Active string
	// Via is the observed via address; empty when no pin line was found.
	Via string
	// Down is true when no usable pin exists: no route, or a via matching
	// no leg of this node.
	Down bool
}

// pathView is the context the pin lives in: the ingress leaf (the attachment
// node that sorts first — the node the renderer pinned), the peer function
// prefix the pin routes to, and that node's own spine legs.
type pathView struct {
	Node   string
	PeerFn string
	Legs   map[string]string
}

// steeredPathView builds the stage's read context for a steered service, or
// nil when the service is not steered (steering keys on the preferred spine —
// an alternateSpine-only service renders no pin and has nothing to read).
// order is the plan's sorted node order, sids the claimed service SIDs per
// attachment node, spineLinks the site's per-node spine legs.
func steeredPathView(svc *v1alpha1.SRv6Service, order []string, sids map[string]string,
	spineLinks map[string]map[string]string) *pathView {
	if svc.Spec.Path.PreferredSpine == "" {
		return nil
	}
	if len(order) != 2 {
		return nil
	}
	ingress, peer := order[0], order[1]
	sid, ok := sids[peer]
	if !ok || sid == "" {
		return nil
	}
	legs, ok := spineLinks[ingress]
	if !ok || len(legs) == 0 {
		return nil
	}
	return &pathView{
		Node:   ingress,
		PeerFn: strings.TrimSuffix(sid, "/64"),
		Legs:   legs,
	}
}

// observePath reads the ingress leaf's kernel route table through the
// executor and decides which spine's leg the pin points at.
func observePath(ctx context.Context, ex Executor, view pathView) (pathObservation, error) {
	res, err := ex.Verify(ctx, view.Node, []fabricplan.Check{{
		Type:    "command",
		Command: pathReadCommand,
		// Empty Expect: the executor's strings.Contains against "" always
		// passes, so the check never asserts — it only carries the observed
		// route table back in Actual.
	}})
	if err != nil {
		return pathObservation{}, fmt.Errorf("path read on %s: %w", view.Node, err)
	}
	table := ""
	if res != nil && len(res.Results) > 0 {
		table = res.Results[0].Actual
	}
	return readPathTable(table, view), nil
}

// pathReadCommand is the read-only observation command (data-model §8.6).
const pathReadCommand = "ip -6 route show"

// readPathTable finds the pin line (data-model §8.6: `fcbb:bbbb:<peer>:11::
// from :: via <spine-link-v6> ... metric 20`) in an `ip -6 route show`
// output and matches its via address against the node's spine legs.
func readPathTable(table string, view pathView) pathObservation {
	for _, line := range strings.Split(table, "\n") {
		if !strings.HasPrefix(line, view.PeerFn+" ") {
			continue
		}
		via, ok := viaAddress(line)
		if !ok {
			continue
		}
		for spine, addr := range view.Legs {
			if addr != "" && addr == via {
				return pathObservation{Active: spine, Via: via}
			}
		}
		// A pin exists but its via matches no leg of this node: no known
		// path is served by it.
		return pathObservation{Via: via, Down: true}
	}
	return pathObservation{Down: true}
}

// viaAddress extracts the `via <addr>` token of a route line.
func viaAddress(line string) (string, bool) {
	fields := strings.Fields(line)
	for i, field := range fields {
		if field == "via" && i+1 < len(fields) {
			return fields[i+1], true
		}
	}
	return "", false
}

// pathDownRefusal is the §6 PathDown refusal for a service whose pin serves
// no known path: the message names the node and BOTH missing paths — each
// spine with the leg address the pin is missing (sorted for determinism).
func pathDownRefusal(view pathView, o pathObservation) *Refusal {
	spines := make([]string, 0, len(view.Legs))
	for spine := range view.Legs {
		spines = append(spines, spine)
	}
	sort.Strings(spines)
	missing := make([]string, 0, len(spines))
	for _, spine := range spines {
		missing = append(missing, fmt.Sprintf("no route to %s via %s (%s)", view.PeerFn, spine, view.Legs[spine]))
	}
	detail := ""
	if o.Via != "" {
		detail = fmt.Sprintf("; the pin's via address %s matches no spine of this site", o.Via)
	}
	return &Refusal{
		Reason: reasons.ReasonPathDown,
		Message: fmt.Sprintf("path down on node %s: %s — preferred and alternate paths are both unusable%s",
			view.Node, strings.Join(missing, ", "), detail),
		Kind: refusalPath,
	}
}

// steerPath is the path stage's verdict for one reconcile.
type steerPath struct {
	// ActivePath is what status.activePath becomes: the device-observed
	// spine for a steered service, empty when not steered (data-model §2).
	ActivePath string
	// Refusal carries the PathDown verdict; the reconcile raises it as is.
	Refusal *Refusal
	// SkipRepair tells the reconcile the verify refusal is the failover
	// state (the pin rides the alternate), not drift.
	SkipRepair bool
}

// steerPathOutcome decides the reconcile's next move from the observation and
// the verify refusal. view is nil for an unsteered service: the stage is a
// no-op there and activePath stays empty.
func steerPathOutcome(svc *v1alpha1.SRv6Service, view *pathView, o pathObservation, vref *Refusal) steerPath {
	if view == nil {
		return steerPath{}
	}
	if o.Down {
		return steerPath{Refusal: pathDownRefusal(*view, o)}
	}
	out := steerPath{ActivePath: o.Active}
	if vref != nil && vref.Kind == refusalCheck && o.Active != "" &&
		o.Active != svc.Spec.Path.PreferredSpine {
		// The preferred-pin checks fail by design while the pin rides the
		// alternate: that is the failover, not drift — re-applying would
		// re-install the preferred pin and undo the operator's switch.
		out.SkipRepair = true
	}
	return out
}
