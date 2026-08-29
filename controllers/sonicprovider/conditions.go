package sonicprovider

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

// upsertConditionGeneric updates a generic map-status with a condition entry under 'conditions'.
// Kubenet NetworkDevice keeps status as an arbitrary object; we model conditions as a []metav1.Condition
// stored under the "conditions" key.
func upsertConditionGeneric(status map[string]any, c metav1.Condition) map[string]any {
	if status == nil {
		status = map[string]any{}
	}
	condsAny, ok := status["conditions"]
	var conds []metav1.Condition
	if ok {
		if typed, ok := condsAny.([]metav1.Condition); ok {
			conds = typed
		}
	}
	found := false
	for i := range conds {
		if conds[i].Type == c.Type {
			conds[i] = c
			found = true
			break
		}
	}
	if !found {
		conds = append(conds, c)
	}
	status["conditions"] = conds
	return status
}
