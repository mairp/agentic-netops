package sonicprovider

import (
	"context"

	"github.com/mairp/ainetops/pkg/kubenet"
	"sigs.k8s.io/controller-runtime/pkg/client"
	ctrl "sigs.k8s.io/controller-runtime"
)

// SetupIndexes declares controller-runtime field indexes used by watches and dependency lookups.
func SetupIndexes(ctx context.Context, mgr ctrl.Manager) error {
	idx := mgr.GetFieldIndexer()
	// Index NetworkDevices by the 'network.kubenet.dev/derived' label presence
	return idx.IndexField(ctx, &kubenet.NetworkDevice{}, "metadata.labels.network.kubenet.dev/derived", func(o client.Object) []string {
		if o == nil {
			return nil
		}
		labels := o.GetLabels()
		if labels == nil {
			return nil
		}
		if v, ok := labels["network.kubenet.dev/derived"]; ok && v == "true" {
			return []string{"true"}
		}
		return nil
	})
}
