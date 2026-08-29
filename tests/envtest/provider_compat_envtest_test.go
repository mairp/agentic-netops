//go:build !integration

package envtest

import (
	"context"
	"testing"

	"github.com/mairp/ainetops/pkg/compat"
)

func TestCompat_ReasonFor(t *testing.T) {
	t.Parallel()
	set := compat.Set{}
	err := compat.Validate(set, map[string]bool{"sai.srv6": false})
	if err == nil {
		t.Fatalf("expected error")
	}
	if compat.ReasonFor(err) == "ValidationFailed" {
		t.Fatalf("expected typed reason, got ValidationFailed")
	}
	_ = context.TODO()
}
