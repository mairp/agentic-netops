package unit

import (
	"testing"

	"github.com/mairp/agentic-netops/pkg/sdc"
)

func TestOfflineValidateRejectsNonPathKeys(t *testing.T) {
	spec := map[string]any{"interfaces": 123}
	if err := sdc.OfflineValidate(spec); err == nil {
		t.Fatalf("expected invalid path error")
	}
}
