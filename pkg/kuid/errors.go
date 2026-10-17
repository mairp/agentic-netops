// SPDX-License-Identifier: Apache-2.0
package kuid

import (
	"errors"
	"fmt"
	"strings"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
)

// CollisionError reports that a claimed value is already taken by someone
// else. The message names the pool.
type CollisionError struct {
	Pool   string
	Detail string
}

func (e *CollisionError) Error() string {
	return fmt.Sprintf("kuid collision in pool %s: %s", e.Pool, e.Detail)
}

// ExhaustionError reports that a pool has no value left to allocate. The
// message names the pool, as the spec requires for PoolExhausted.
type ExhaustionError struct {
	Pool   string
	Detail string
}

func (e *ExhaustionError) Error() string {
	return fmt.Sprintf("kuid pool %s exhausted: %s", e.Pool, e.Detail)
}

// TimeoutError reports that a claim never produced its allocated value
// within the deadline.
type TimeoutError struct {
	Pool       string
	Name       string
	LastStatus string
}

func (e *TimeoutError) Error() string {
	return fmt.Sprintf("kuid claim %s (pool %s) not ready within deadline (last status: %s)",
		e.Name, e.Pool, e.LastStatus)
}

// UnavailableError reports that the served claim authority itself could not
// serve the claim — not that a value is taken or the pool spent. On the
// pinned kuid-server the GENID family fails this way at runtime: the index
// is never stored (docs/CLUSTER_REBUILD_FINDINGS.md §2 — every
// genidindices.genid.be.kuid.dev post ends ServiceUnavailable), so a claim
// against it dies with `index kuid-system.srv6-service-ids not initialized`
// at CREATE time, before any wait could time out. This is the second
// trigger of the Lease fallback (research.md Decision 11): the served path
// cannot allocate, so the fallback must.
type UnavailableError struct {
	Pool   string
	Detail string
}

func (e *UnavailableError) Error() string {
	return fmt.Sprintf("kuid authority for pool %s unavailable: %s", e.Pool, e.Detail)
}

// IsCollision reports whether err is (or wraps) a CollisionError.
func IsCollision(err error) bool {
	var e *CollisionError
	return errors.As(err, &e)
}

// IsExhaustion reports whether err is (or wraps) an ExhaustionError.
func IsExhaustion(err error) bool {
	var e *ExhaustionError
	return errors.As(err, &e)
}

// IsTimeout reports whether err is (or wraps) a TimeoutError.
func IsTimeout(err error) bool {
	var e *TimeoutError
	return errors.As(err, &e)
}

// IsUnavailable reports whether err is (or wraps) an UnavailableError —
// the "the served claim path itself cannot allocate" class that triggers
// the Lease fallback alongside the wait timeout.
func IsUnavailable(err error) bool {
	var e *UnavailableError
	return errors.As(err, &e)
}

// looksLikeExists recognises the exists answers that do not carry the
// "already exists" spelling. The pinned kuid-server answers a duplicate
// claim create with reason=InternalError and the message
// `Internal error occurred: AlreadyExists` (measured live 2026-10-16,
// GENID create on an index it considers present): apierrors.IsAlreadyExists
// is false for it and the phrase search misses it because the message folds
// the words together, so the comparison runs over a squashed form.
func looksLikeExists(lowerDetail string) bool {
	var b strings.Builder
	for _, r := range lowerDetail {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		}
	}
	return strings.Contains(b.String(), "alreadyexists")
}

// classify maps a raw Kubernetes API error from a kuid claim or fallback
// Lease operation onto a typed error that names the pool. Anything that is
// neither a collision nor exhaustion is returned unchanged.
func classify(pool string, err error) error {
	if err == nil {
		return nil
	}
	detail := err.Error()
	low := strings.ToLower(detail)
	if apierrors.IsAlreadyExists(err) || looksLikeExists(low) ||
		strings.Contains(low, "collision") ||
		strings.Contains(low, "conflict") {
		return &CollisionError{Pool: pool, Detail: detail}
	}
	if strings.Contains(low, "exhaust") ||
		strings.Contains(low, "no available") ||
		strings.Contains(low, "no ids") ||
		strings.Contains(low, "no free") {
		return &ExhaustionError{Pool: pool, Detail: detail}
	}
	// The authority-is-dead class, after collision/exhaustion because those
	// phrases decide what the caller may retry about first. The pinned
	// server's strings for it are the ServiceUnavailable status and
	// `index <ns>.<name> not initialized` (verified live on the GENID
	// family; docs/CLUSTER_REBUILD_FINDINGS.md §2).
	if apierrors.IsServiceUnavailable(err) ||
		strings.Contains(low, "not initialized") ||
		strings.Contains(low, "service unavailable") ||
		strings.Contains(low, "server is currently unable") {
		return &UnavailableError{Pool: pool, Detail: detail}
	}
	return err
}
