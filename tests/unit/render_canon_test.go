package unit

import (
	"testing"

	"github.com/mairp/ainetops/pkg/render"
)

func TestCanonicalHash_Deterministic(t *testing.T) {
	a := map[string]any{"/a": 1, "/b": 2}
	b := map[string]any{"/b": 2, "/a": 1}
	h1, err := render.CanonicalHash(a)
	if err != nil { t.Fatal(err) }
	h2, err := render.CanonicalHash(b)
	if err != nil { t.Fatal(err) }
	if h1 != h2 {
		t.Fatalf("expected hashes equal, got %s != %s", h1, h2)
	}
}
