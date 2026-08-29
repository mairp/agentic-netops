//go:build ainetops_k8s

package main

import (
	"context"
	"flag"
	"fmt"
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
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/manager"

	"github.com/mairp/ainetops/controllers/sonicprovider"
	"github.com/mairp/ainetops/pkg/kubenet"
	"github.com/mairp/ainetops/pkg/sdc"
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

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	options := manager.Options{
		Scheme:                 scheme,
		MetricsBindAddress:     metricsAddr,
		HealthProbeBindAddress: probeAddr,
		LeaderElection:         enableLeaderElection,
		LeaderElectionID:       "ainetops-sonic-provider",
		LeaderElectionReleaseOnCancel: true,
		LeaseDuration:          ptrDuration(50 * time.Second),
		RenewDeadline:          ptrDuration(40 * time.Second),
		RetryPeriod:            ptrDuration(15 * time.Second),
		LeaderElectionResourceLock: resourcelock.LeasesResourceLock,
	}

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), options)
	if err != nil {
		setupLog.Error(err, "unable to start manager")
		os.Exit(1)
	}

	// Register Kubenet types for watches
	if err := kubenet.AddToScheme(scheme); err != nil {
		setupLog.Error(err, "unable to add Kubenet scheme")
		os.Exit(1)
	}

	// Register field indexes used by reconcilers
	if err := sonicprovider.SetupIndexes(ctx, mgr); err != nil {
		setupLog.Error(err, "unable to set up indexes")
		os.Exit(1)
	}

	// Register SDC types for Ownership and SSA
	if err := sdc.AddToScheme(scheme); err != nil {
		setupLog.Error(err, "unable to add SDC scheme")
		os.Exit(1)
	}

	reconciler := &sonicprovider.Reconciler{Client: mgr.GetClient(), Scheme: mgr.GetScheme(), Log: setupLog.WithName("sonicprovider"), Recorder: mgr.GetEventRecorderFor("ainetops-sonic-provider")}
	if err := reconciler.SetupWithManager(mgr); err != nil {
		setupLog.Error(err, "unable to create controller", "controller", "NetworkDevice")
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
