// SPDX-License-Identifier: Apache-2.0
//
// The executor surface this controller consumes (T378): a small interface the
// tests stub to count apply calls (zero-write re-apply, T390) and to script
// failures. The concrete pkg/executorclient.Client satisfies it unchanged —
// pkg/executorclient is consumed, never edited.
package srv6service

import (
	"context"

	"github.com/mairp/agentic-netops/pkg/executorclient"
	"github.com/mairp/agentic-netops/pkg/fabricplan"
)

// Executor applies and verifies per-node device work through the
// fabric-executor (contracts/executor-transport.md).
type Executor interface {
	Apply(ctx context.Context, node string, ops []fabricplan.Op) (*executorclient.ApplyResult, error)
	Verify(ctx context.Context, node string, checks []fabricplan.Check) (*executorclient.VerifyResult, error)
}

// compile-time proof the concrete client satisfies the interface.
var _ Executor = (*executorclient.Client)(nil)
