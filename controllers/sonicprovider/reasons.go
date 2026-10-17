//go:build agentic_netops_k8s

package sonicprovider

// Re-export the stable reason codes from pkg/reasons so evidence can cite
// controllers/sonicprovider/reasons.go explicitly per FR-003, and every
// condition message speaks construct terms consistently.
import "github.com/mairp/agentic-netops/pkg/reasons"

const (
	// Note: no WaitingDependencies here. The §6 reason table has no such
	// reason (data-model: "There is no WaitingDependencies"), so pkg/reasons
	// no longer carries it and this re-export was dropped. The NetworkDevice
	// gate condition uses the package-local reasonWaitingDependencies
	// (conditions.go) until that controller's gating is reworked.
	ReasonSchemaMismatch = reasons.ReasonSchemaMismatch
	ReasonValidated      = reasons.ReasonValidated
	ReasonApplySucceeded = reasons.ReasonApplySucceeded
	ReasonApplyFailed    = reasons.ReasonApplyFailed
	ReasonFinalizing     = reasons.ReasonFinalizing
	ReasonFinalized      = reasons.ReasonFinalized
)
