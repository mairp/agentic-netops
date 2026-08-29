package sonicprovider

import (
	ctrl "sigs.k8s.io/controller-runtime"
)

// AddToManager wires all sonicprovider reconcilers to the given manager.
func AddToManager(mgr ctrl.Manager) error {
	// placeholder for wiring more reconcilers as they are implemented
	return nil
}
