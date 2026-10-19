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

	"github.com/go-logr/zapr"
	"go.uber.org/zap"
	coordinationv1 "k8s.io/api/coordination/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	agenticnetopsv1alpha1 "github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/controllers/srv6service"
	"github.com/mairp/agentic-netops/pkg/executorclient"
	"github.com/mairp/agentic-netops/pkg/kuid"
)

var (
	scheme = runtime.NewScheme()
)

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(agenticnetopsv1alpha1.AddToScheme(scheme))
}

func main() {
	var metricsAddr, probeAddr string
	var enableLeaderElection bool
	flag.StringVar(&metricsAddr, "metrics-bind", ":8081", "The address the metric endpoint binds to.")
	flag.StringVar(&probeAddr, "health-probe-bind", ":8082", "The address the probe endpoint binds to.")
	flag.BoolVar(&enableLeaderElection, "leader-elect", true, "Enable leader election for controller manager.")
	flag.Parse()

	zl, _ := zap.NewProduction()
	defer zl.Sync()
	log := zapr.NewLogger(zl)
	// controller-runtime's internal logger otherwise warns "log.SetLogger(...)
	// was never called; logs will not be displayed" on every event broadcast.
	ctrl.SetLogger(log)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), manager.Options{
		Scheme:                        scheme,
		Metrics:                       metricsserver.Options{BindAddress: metricsAddr},
		HealthProbeBindAddress:        probeAddr,
		LeaderElection:                enableLeaderElection,
		LeaderElectionID:              "agentic-netops-srv6-controller",
		LeaderElectionReleaseOnCancel: true,
		LeaseDuration:                 ptrDuration(50 * time.Second),
		RenewDeadline:                 ptrDuration(40 * time.Second),
		RetryPeriod:                   ptrDuration(15 * time.Second),
		Cache: cache.Options{
			ByObject: map[client.Object]cache.ByObject{
				// The Lease fallback (pkg/kuid.AllocateLeaseID) reads
				// allocation leases in kuid-system only. Confining the Lease
				// informer to that namespace keeps the runtime grant exactly
				// the namespaced Role the rbac file binds (a default
				// controller-runtime informer is CLUSTER-scoped, which would
				// need a cluster-wide lease list the rbac file deliberately
				// does not carry — measured live 2026-10-16: the unconfinced
				// informer sat forbidden and the first Allocate blocked on
				// its cache sync). Leader election is unaffected: the manager
				// takes its own lease through the API, not this cache.
				&coordinationv1.Lease{}: {
					Namespaces: map[string]cache.Config{
						kuid.Namespace: {},
					},
				},
			},
		},
	})
	if err != nil {
		log.Error(err, "unable to start manager")
		os.Exit(1)
	}

	// T398 wiring: the manager client IS the KUID client — pkg/kuid's claim,
	// wait, release, reserve and Lease-fallback helpers all take client.Client
	// and are driven through Reconciler.Client against the served
	// *.be.kuid.dev groups (deploy/rbac/srv6-crd-rbac.yaml). The pin reader is
	// the uncached APIReader (capability C5 must not trust a shared informer).
	siteFacts, factsErr := srv6service.SiteFactsFromEnv()
	if factsErr != nil {
		log.Error(factsErr, "FABRIC_SITE_FACTS / per-map env unparsable; sonic-vm defaults kept for the unparsable maps")
	}
	executorURL := os.Getenv("FABRIC_EXECUTOR_URL")
	if executorURL == "" {
		// The lab default (scripts/provision.sh starts the host service on the
		// kind bridge gateway); the manifest carries the same value (T399).
		executorURL = "http://172.30.0.1:8084"
	}
	reconciler := &srv6service.Reconciler{
		Client:    mgr.GetClient(),
		Scheme:    mgr.GetScheme(),
		Log:       log.WithName("srv6service"),
		APIReader: mgr.GetAPIReader(), // pins read uncached (see pkg/compat/pins.go)
		Facts:     siteFacts,
		Executor:  executorclient.New(executorURL, nil),
		Recorder:  mgr.GetEventRecorderFor("agentic-netops-srv6-controller"),
	}
	log.Info("srv6 controller wired",
		"executor", executorURL,
		"nodes", len(siteFacts.Nodes),
		"ports", len(siteFacts.PortMap),
		"locators", len(siteFacts.Locators))
	if err := reconciler.SetupWithManager(mgr); err != nil {
		log.Error(err, "unable to create controller", "controller", "SRv6Service")
		os.Exit(1)
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		log.Error(err, "unable to set up health check")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Checker(func(req *http.Request) error { return nil })); err != nil {
		log.Error(err, "unable to set up ready check")
		os.Exit(1)
	}

	if err := mgr.Start(ctx); err != nil {
		log.Error(err, "problem running manager")
		os.Exit(1)
	}
}

func ptrDuration(d time.Duration) *time.Duration { return &d }
