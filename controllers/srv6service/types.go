// SPDX-License-Identifier: Apache-2.0
//
// Shared refusal type and constants for the SRv6Service controller. A Refusal
// is one terminal (or, for the non-terminal rows of the table, retryable)
// condition reason of data-model.md §6, with the message the table requires.
package srv6service

import (
	"fmt"
	"time"

	"github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/reasons"
)

// nowFunc is the clock seam the tests pin.
var nowFunc = time.Now

// Requeue behavior constants (T396: no requeue storm).
const (
	// resyncInterval is the Ready steady-state resync (drift check).
	resyncInterval = 5 * time.Minute
	// failureBackoff backs off every non-terminal failure requeue.
	failureBackoff = 30 * time.Second
)

// refusalKind says which pipeline stage produced a refusal; it is internal
// bookkeeping (the condition reason alone reaches the API).
type refusalKind int

const (
	refusalSite refusalKind = iota // InvalidSite (C1-C3)
	refusalPort                    // PortInUse (C4, C7)
	refusalCap                     // CapabilityMissing (C5) / DataPathUnverifiable (C8)
	refusalVariant                 // UnsupportedVariant (C6)
	refusalPool                    // PoolExhausted
	refusalVlan                    // VlanInUse
	refusalApply                   // ApplyFailed
	refusalCheck                   // CheckFailed
	refusalLocator                 // LocatorMissing
	refusalDataPath                // DataPathFailed
	refusalPath                    // PathDown
	refusalFinalizing              // Finalizing
)

// terminal reports whether the controller stops retrying until the spec or
// the site changes (data-model.md §6). Terminal refusals do NOT requeue.
func (k refusalKind) terminal() bool {
	switch k {
	case refusalSite, refusalPort, refusalCap, refusalVariant, refusalPool, refusalVlan:
		return true
	default:
		return false
	}
}

// Refusal is one reason with its message (and terminal/retryable behavior).
type Refusal struct {
	Reason  string // a data-model.md §6 reason
	Message string
	Kind    refusalKind
}

// Terminal reports whether the refusal stops retrying.
func (r *Refusal) Terminal() bool { return r == nil || r.Kind.terminal() }

// Error implements error so a Refusal can travel the (nil, error) return
// path of the pipeline stages; errors.As unwraps it back to the reason.
func (r *Refusal) Error() string {
	if r == nil {
		return "<nil refusal>"
	}
	return fmt.Sprintf("%s: %s", r.Reason, r.Message)
}

// correlationID returns the id stamped on every claim of this service: the
// deployer's agentic-netops.io/correlation-id label, else the object UID.
func correlationID(svc *v1alpha1.SRv6Service) string {
	if v := svc.Labels[v1alpha1.CorrelationIDLabel]; v != "" {
		return v
	}
	return string(svc.UID)
}

// reasonFor maps a refusal kind to its §6 reason string (kept next to the
// kind table so the two cannot drift apart unnoticed).
func (k refusalKind) reason() string {
	switch k {
	case refusalSite:
		return reasons.ReasonInvalidSite
	case refusalPort:
		return reasons.ReasonPortInUse
	case refusalCap:
		return reasons.ReasonCapabilityMissing
	case refusalVariant:
		return reasons.ReasonUnsupportedVariant
	case refusalPool:
		return reasons.ReasonPoolExhausted
	case refusalApply:
		return reasons.ReasonApplyFailed
	case refusalCheck:
		return reasons.ReasonCheckFailed
	case refusalLocator:
		return reasons.ReasonLocatorMissing
	case refusalDataPath:
		return reasons.ReasonDataPathFailed
	case refusalPath:
		return reasons.ReasonPathDown
	case refusalFinalizing:
		return reasons.ReasonFinalizing
	default:
		return reasons.ReasonCheckFailed
	}
}
