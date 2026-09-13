//go:build agentic_netops_k8s

package srlprovider

// Re-export the stable reason codes from pkg/reasons so evidence can cite
// controllers/srlprovider/reasons.go explicitly per FR-003, and every
// condition message speaks construct terms consistently.
import "github.com/mairp/agentic-netops/pkg/reasons"

const (
	ReasonWaitingDependencies = reasons.ReasonWaitingDependencies
	ReasonSchemaMismatch      = reasons.ReasonSchemaMismatch
	ReasonValidated           = reasons.ReasonValidated
	ReasonApplySucceeded      = reasons.ReasonApplySucceeded
	ReasonApplyFailed         = reasons.ReasonApplyFailed
	ReasonFinalizing          = reasons.ReasonFinalizing
	ReasonFinalized           = reasons.ReasonFinalized
)
