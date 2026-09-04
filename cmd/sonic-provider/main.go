//go:build agentic_netops_k8s

package main

import (
	"context"
	"flag"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/go-logr/logr"
	"github.com/go-logr/zapr"
	"go.uber.org/zap"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/leaderelection/resourcelock"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	"github.com/mairp/agentic-netops/controllers/sonicprovider"
	"github.com/mairp/agentic-netops/pkg/kubenet"
	"github.com/mairp/agentic-netops/pkg/sdc"
)

var (
	scheme   = runtime.NewScheme()
	setupLog logr.Logger
)

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
}

func main() {
	var metricsAddr, probeAddr string
	var enableLeaderElection bool
	flag.StringVar(&metricsAddr, "metrics-bind", ":8080", "The address the metric endpoint binds to.")
	flag.StringVar(&probeAddr, "health-probe-bind", ":8081", "The address the probe endpoint binds to.")
	flag.BoolVar(&enableLeaderElection, "leader-elect", true, "Enable leader election for controller manager.")
	flag.Parse()

	zapLog, _ := zap.NewProduction()
	defer zapLog.Sync()
	setupLog = zapr.NewLogger(zapLog).WithName("setup")
	// controller-runtime's own logs (controller errors, leader events) route
	// through log.SetLogger; without this they vanish and reconcile failures
	// are invisible except as requeue silence.
	ctrl.SetLogger(zapr.NewLogger(zapLog))

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	options := manager.Options{
		Scheme:                        scheme,
		Metrics:                       metricsserver.Options{BindAddress: metricsAddr},
		HealthProbeBindAddress:        probeAddr,
		LeaderElection:                enableLeaderElection,
		LeaderElectionID:              "agentic-netops-sonic-provider",
		LeaderElectionReleaseOnCancel: true,
		LeaseDuration:                 ptrDuration(50 * time.Second),
		RenewDeadline:                 ptrDuration(40 * time.Second),
		RetryPeriod:                   ptrDuration(15 * time.Second),
		LeaderElectionResourceLock:    resourcelock.LeasesResourceLock,
		// The provider's RBAC is namespaced to the intent tier (Role
		// sonic-provider-networks), so the Network informer must not list at
		// cluster scope. Scoping the cache per-GVK keeps that alignment and
		// bounds the watch to where the deployer submits Networks.
		Cache: cache.Options{
			ByObject: map[client.Object]cache.ByObject{
				&kubenet.Network{}: {
					Namespaces: map[string]cache.Config{
						"agentic-netops-intent": {},
					},
				},
			},
		},
	}

	// Register schemes BEFORE manager creation: the cache's per-GVK namespace
	// scoping (options.Cache.ByObject below) needs the scheme to know whether
	// kubenet.Network is namespaced at NewManager time.
	if err := kubenet.AddToScheme(scheme); err != nil {
		setupLog.Error(err, "unable to add Kubenet scheme")
		os.Exit(1)
	}
	if err := sdc.AddToScheme(scheme); err != nil {
		setupLog.Error(err, "unable to add SDC scheme")
		os.Exit(1)
	}

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), options)
	if err != nil {
		setupLog.Error(err, "unable to start manager")
		os.Exit(1)
	}

	// Register field indexes used by reconcilers
	if err := sonicprovider.SetupIndexes(ctx, mgr); err != nil {
		setupLog.Error(err, "unable to set up indexes")
		os.Exit(1)
	}

	// Pins read uncached: the sdc.Config informer's cluster-scoped ConfigMap
	// list is RBAC-denied and would poison any cache-backed pin lookup.
	reconciler := &sonicprovider.Reconciler{Client: mgr.GetClient(), Scheme: mgr.GetScheme(), Log: setupLog.WithName("sonicprovider"), Recorder: mgr.GetEventRecorderFor("agentic-netops-sonic-provider"), APIReader: mgr.GetAPIReader()}
	if err := reconciler.SetupWithManager(mgr); err != nil {
		setupLog.Error(err, "unable to create controller", "controller", "NetworkDevice")
		os.Exit(1)
	}

	// Network intent reconciler: the intent-to-fabric loop. Watches
	// network.kubenet.dev Networks in agentic-netops-intent, applies them to the
	// fabric through the fabric-executor, and reports verified convergence on
	// the Network's Ready condition.
	networkReconciler := &sonicprovider.NetworkReconciler{Client: mgr.GetClient(), Scheme: mgr.GetScheme(), Log: setupLog.WithName("networkfabric"), Recorder: mgr.GetEventRecorderFor("agentic-netops-sonic-provider"), APIReader: mgr.GetAPIReader()}
	if err := networkReconciler.SetupWithManager(mgr); err != nil {
		setupLog.Error(err, "unable to create controller", "controller", "Network")
		os.Exit(1)
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		setupLog.Error(err, "unable to set up health check")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Checker(func(req *http.Request) error { return nil })); err != nil {
		setupLog.Error(err, "unable to set up ready check")
		os.Exit(1)
	}

	setupLog.Info("starting manager")
	if err := mgr.Start(ctx); err != nil {
		setupLog.Error(err, "problem running manager")
		os.Exit(1)
	}
}

func ptrDuration(d time.Duration) *time.Duration { return &d }

func init() {
	// ensure core v1 gets added to scheme for leader election
	_ = corev1.AddToScheme(scheme)
}
