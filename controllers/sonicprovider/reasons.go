package sonicprovider

// Deprecated: moved to pkg/reasons for reuse across controllers.
const (
	ReasonWaitingDependencies = "WaitingDependencies"
	ReasonSchemaMismatch      = "SchemaMismatch"
	ReasonValidated           = "Validated"
	ReasonApplySucceeded      = "ApplySucceeded"
	ReasonApplyFailed         = "ApplyFailed"
	ReasonFinalizing          = "Finalizing"
	ReasonFinalized           = "Finalized"
)
