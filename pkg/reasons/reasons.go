// SPDX-License-Identifier: Apache-2.0
// Package reasons defines stable reason codes used in Conditions and Events.
package reasons

const (
	ReasonWaitingDependencies = "WaitingDependencies"
	ReasonSchemaMismatch      = "SchemaMismatch"
	ReasonValidated           = "Validated"
	ReasonApplySucceeded      = "ApplySucceeded"
	ReasonApplyFailed         = "ApplyFailed"
	ReasonFinalizing          = "Finalizing"
	ReasonFinalized           = "Finalized"
)
