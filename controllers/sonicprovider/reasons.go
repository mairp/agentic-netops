//go:build agentic_netops_k8s

package sonicprovider

// Re-export the stable reason codes from pkg/reasons so evidence can cite
// controllers/sonicprovider/reasons.go explicitly per FR-003, and every
// condition message speaks construct terms consistently.
import "github.com/mairp/agentic-netops/pkg/reasons"

const (
	// Note: there is no dependencies-pending reason here. The §6 reason table
	// has no such entry (the data model says so in as many words), so
	// pkg/reasons does not carry one and this re-export does not either. The
	// NetworkDevice gate condition uses the package-local reasonPendingGates
	// (conditions.go): that kind sits outside the §6 service-state table, and
	// its message names what is actually missing.
	ReasonSchemaMismatch = reasons.ReasonSchemaMismatch
	ReasonValidated      = reasons.ReasonValidated
	ReasonApplySucceeded = reasons.ReasonApplySucceeded
	ReasonApplyFailed    = reasons.ReasonApplyFailed
	ReasonFinalizing     = reasons.ReasonFinalizing
	ReasonFinalized      = reasons.ReasonFinalized
)
