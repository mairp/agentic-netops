// SPDX-License-Identifier: Apache-2.0
// Package reasons defines stable reason codes used in Conditions and Events.
//
// The service-state reason set is the §6 table of
// specs/004-srv6-service-requests/data-model.md. There is deliberately no
// dependencies-pending reason in it: the data model has no such entry, and a
// service that is merely waiting is Ready=False with the reason that names
// what is actually missing.
package reasons

// Service-state reasons (data-model.md §6).
const (
	ReasonVerified             = "Verified"
	ReasonInvalidSite          = "InvalidSite"
	ReasonPortInUse            = "PortInUse"
	ReasonCapabilityMissing    = "CapabilityMissing"
	ReasonUnsupportedVariant   = "UnsupportedVariant"
	ReasonPoolExhausted        = "PoolExhausted"
	ReasonApplyFailed          = "ApplyFailed"
	ReasonCheckFailed          = "CheckFailed"
	ReasonLocatorMissing       = "LocatorMissing"
	ReasonDataPathFailed       = "DataPathFailed"
	ReasonDataPathUnverifiable = "DataPathUnverifiable"
	ReasonVlanInUse            = "VlanInUse"
	ReasonPathDown             = "PathDown"
	ReasonFinalizing           = "Finalizing"
)

// Pre-existing reasons still referenced by current callers (Network and
// NetworkDevice reconcilers, pkg/compat mapping).
const (
	ReasonSchemaMismatch = "SchemaMismatch"
	ReasonValidated      = "Validated"
	ReasonApplySucceeded = "ApplySucceeded"
	ReasonFinalized      = "Finalized"
)
