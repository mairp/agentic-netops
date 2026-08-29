package unit

import (
	"testing"

	"github.com/mairp/ainetops/pkg/model"
	"github.com/mairp/ainetops/pkg/render"
)

func TestRenderInterfaces_OrderStable(t *testing.T) {
	ifs := []model.Interface{{Name: "Ethernet2"}, {Name: "Ethernet1", MTU: 9000}}
	res := render.RenderInterfaces(ifs, nil)
	arr, ok := res["/interfaces/interface"].([]map[string]any)
	if !ok { t.Fatalf("unexpected type") }
	if len(arr) != 2 { t.Fatalf("expected 2 entries") }
	if arr[0]["name"] != "Ethernet1" { t.Fatalf("expected Ethernet1 first, got %v", arr[0]["name"]) }
}
