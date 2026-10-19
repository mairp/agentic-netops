// SPDX-License-Identifier: Apache-2.0
//
// Plan stage tests, T378: the render goes through fabricplan.ForSRv6Service
// (the renderer is pure over svc+alloc+facts) and every node's rendered ops
// are hashed into status.configHashes — the basis of the zero-write
// re-apply (T390). This file also carries the shared test harness the other
// pipeline stage tests use: the fake client scheme, the recording executor,
// the capability-record reader and the converge loop.
package srv6service

import (
	"context"
	"encoding/json"
	"regexp"
	"sync"
	"testing"

	agenticnetopsv1alpha1 "github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/compat"
	"github.com/mairp/agentic-netops/pkg/executorclient"
	"github.com/mairp/agentic-netops/pkg/fabricplan"
	"github.com/mairp/agentic-netops/pkg/kubenet"
	"github.com/mairp/agentic-netops/pkg/kuid"
	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// testNamespace is where the harness places services (the conflict tests
// share it).
const testNamespace = "intent"

// testKey is the object key of a named test service.
func testKey(name string) types.NamespacedName {
	return types.NamespacedName{Namespace: testNamespace, Name: name}
}

// testScheme carries the built-in types (ConfigMaps, coordination Leases),
// the SRv6Service CRD and the kubenet Network types the conflict stage
// lists. The served *.be.kuid.dev claims are used as unstructured objects,
// which the fake client tracks without registration (the same trick
// pkg/kuid's own tests use).
func testScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		t.Fatalf("client-go scheme: %v", err)
	}
	if err := agenticnetopsv1alpha1.AddToScheme(scheme); err != nil {
		t.Fatalf("api scheme: %v", err)
	}
	if err := kubenet.AddToScheme(scheme); err != nil {
		t.Fatalf("kubenet scheme: %v", err)
	}
	return scheme
}

// newTestClient builds the fake client with the status subresource enabled.
func newTestClient(t *testing.T, objs ...client.Object) client.Client {
	t.Helper()
	return fake.NewClientBuilder().
		WithScheme(testScheme(t)).
		WithStatusSubresource(&agenticnetopsv1alpha1.SRv6Service{}).
		WithObjects(objs...).
		Build()
}

// emptyTestClient is a fake client with nothing in it (a store that answers
// NotFound for the pins read).
func emptyTestClient(t *testing.T) client.Client {
	t.Helper()
	return fake.NewClientBuilder().WithScheme(testScheme(t)).Build()
}

// testService returns a valid steered ip-vrf/vpn service on the site's two
// leaves (ports the site port map knows). The correlation id label names
// every claim; without it the object UID would.
func testService(name, corrID string) *agenticnetopsv1alpha1.SRv6Service {
	svc := &agenticnetopsv1alpha1.SRv6Service{
		Spec: agenticnetopsv1alpha1.SRv6ServiceSpec{
			Tenant:     "acme",
			Construct:  agenticnetopsv1alpha1.ConstructIPVRF,
			Signalling: agenticnetopsv1alpha1.SignallingVPN,
			Attachments: []agenticnetopsv1alpha1.Attachment{
				{Node: "leaf01", Port: "wan1", Gateway: []agenticnetopsv1alpha1.GatewayPrefix{"192.168.1.1/24"}},
				{Node: "leaf02", Port: "wan1", Gateway: []agenticnetopsv1alpha1.GatewayPrefix{"192.168.2.1/24"}},
			},
			Path: agenticnetopsv1alpha1.PathSelection{PreferredSpine: "spine01", AlternateSpine: "spine02"},
		},
	}
	svc.Name = name
	svc.Namespace = testNamespace
	svc.UID = types.UID("uid-" + name)
	svc.Generation = 1
	if corrID != "" {
		svc.Labels = map[string]string{agenticnetopsv1alpha1.CorrelationIDLabel: corrID}
	}
	return svc
}

// claimObject builds one served claim with (optionally) an allocated status,
// exactly the shape kuid's wait stage reads.
func claimObject(pool kuid.Pool, name, corrID string, status map[string]any) *unstructured.Unstructured {
	u := &unstructured.Unstructured{}
	u.SetGroupVersionKind(schema.GroupVersionKind{Group: pool.Group, Version: pool.Version, Kind: pool.Kind})
	u.SetNamespace(kuid.Namespace)
	u.SetName(name)
	u.SetLabels(map[string]string{
		kuid.LabelCorrelationID: corrID,
		kuid.LabelManagedBy:     kuid.ManagedBy,
	})
	u.Object["spec"] = map[string]any{"index": pool.Name}
	if status != nil {
		u.Object["status"] = status
	}
	return u
}

// testClaims pre-creates the served claims of the §8.1 profile so the wait
// stage answers instantly: service id 7 (Vrf7) and one client /24 per
// attachment. On the pinned server the GENID family fails at runtime and the
// Lease fallback takes over; the fake client answers the served shape, which
// exercises the same code path one step earlier.
func testClaims(t *testing.T, c client.Client, corrID string) {
	t.Helper()
	claims := []client.Object{
		claimObject(kuid.ServiceIDPool, kuid.ClaimName(kuid.ServiceIDPool, corrID), corrID,
			map[string]any{"id": int64(7)}),
		claimObject(kuid.ClientV4Pool, kuid.ClaimName(kuid.ClientV4Pool, corrID, "leaf01-wan1"), corrID,
			map[string]any{"prefix": "192.168.35.0/24"}),
		claimObject(kuid.ClientV4Pool, kuid.ClaimName(kuid.ClientV4Pool, corrID, "leaf02-wan1"), corrID,
			map[string]any{"prefix": "192.168.36.0/24"}),
	}
	for _, obj := range claims {
		if err := c.Create(context.Background(), obj); err != nil {
			t.Fatalf("pre-create claim %s: %v", obj.GetName(), err)
		}
	}
}

// countClaims returns how many claim objects (any kuid family) currently
// exist in kuid-system.
func countClaims(t *testing.T, c client.Client) int {
	t.Helper()
	n := 0
	for _, pool := range []kuid.Pool{kuid.ServiceIDPool, kuid.ClientV4Pool, kuid.VlanPool} {
		list := &unstructured.UnstructuredList{}
		list.SetGroupVersionKind(schema.GroupVersionKind{
			Group: pool.Group, Version: pool.Version, Kind: pool.Kind + "List",
		})
		if err := c.List(context.Background(), list, client.InNamespace(kuid.Namespace)); err != nil {
			t.Fatalf("list %s claims: %v", pool.Kind, err)
		}
		n += len(list.Items)
	}
	return n
}

// goodPins is a capability record that proves ip-vrf/vpn + steering and
// registers a probe host for both attachments.
func goodPins() *corev1.ConfigMap {
	return &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      compat.PinsConfigMapName,
			Namespace: compat.PinsConfigMapNamespace,
		},
		Data: map[string]string{
			KeySAISRV6:          "true",
			KeySRv6Supported:    "ip-vrf/vpn,steering",
			KeyProbeAttachments: "leaf01/wan1,leaf02/wan1",
		},
	}
}

// pinReader adapts a client.Client to compat.PinReader — the shape the
// reconciler wires manager.GetAPIReader() into.
type pinReader struct{ c client.Client }

func (p pinReader) Get(ctx context.Context, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
	return p.c.Get(ctx, key, obj, opts...)
}

// testReconciler wires the pipeline against the fake client. pins, when not
// nil, is served through the (uncached-shaped) reader; when nil the reader
// answers NotFound, as a cluster without the record would.
func testReconciler(t *testing.T, c client.Client, ex *recordingExecutor, pins *corev1.ConfigMap) *Reconciler {
	t.Helper()
	r := &Reconciler{
		Client:   c,
		Scheme:   c.Scheme(),
		Log:      logr.Discard(),
		Facts:    DefaultSiteFacts(),
		Executor: ex,
	}
	if pins != nil {
		pinsClient := newTestClient(t, pins)
		r.APIReader = pinReader{c: pinsClient}
	}
	return r
}

// execCall is one recorded executor call.
type execCall struct {
	Node string
	Ops  []fabricplan.Op
}

// recordingExecutor records every apply/verify and answers from a scripted
// function, so apply/verify/update/delete stages are tested without an HTTP
// endpoint.
type recordingExecutor struct {
	mu       sync.Mutex
	applies  []execCall
	verifies []execCall

	applyFn  func(call execCall, nth int) (*executorclient.ApplyResult, error)
	verifyFn func(node string, checks []fabricplan.Check, nth int) *executorclient.VerifyResult
}

func (e *recordingExecutor) Apply(ctx context.Context, node string, ops []fabricplan.Op) (*executorclient.ApplyResult, error) {
	e.mu.Lock()
	nth := len(e.applies)
	e.applies = append(e.applies, execCall{Node: node, Ops: ops})
	fn := e.applyFn
	e.mu.Unlock()
	if fn != nil {
		return fn(execCall{Node: node, Ops: ops}, nth)
	}
	return applyOKResult(node), nil
}

func (e *recordingExecutor) Verify(ctx context.Context, node string, checks []fabricplan.Check) (*executorclient.VerifyResult, error) {
	e.mu.Lock()
	nth := len(e.verifies)
	e.verifies = append(e.verifies, execCall{Node: node})
	fn := e.verifyFn
	e.mu.Unlock()
	if fn != nil {
		return fn(node, checks, nth), nil
	}
	return verifyAllOK(node, checks), nil
}

// applyCalls snapshots the recorded applies.
func (e *recordingExecutor) applyCalls() []execCall {
	e.mu.Lock()
	defer e.mu.Unlock()
	return append([]execCall(nil), e.applies...)
}

// appliesTo snapshots the recorded applies for one node.
func (e *recordingExecutor) appliesTo(node string) []execCall {
	var out []execCall
	for _, call := range e.applyCalls() {
		if call.Node == node {
			out = append(out, call)
		}
	}
	return out
}

// verifyCount snapshots how many verify calls were made.
func (e *recordingExecutor) verifyCount() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return len(e.verifies)
}

func resultFromJSON(out any, payload string) {
	// The payloads are literals in this file; an unmarshal failure is a bug
	// in the helper, not the code under test.
	_ = json.Unmarshal([]byte(payload), out)
}

// applyOKResult is an accepted apply.
func applyOKResult(node string) *executorclient.ApplyResult {
	res := &executorclient.ApplyResult{}
	resultFromJSON(res, `{"node":"`+node+`","ok":true,"results":[{"kind":"gcu","ok":true}]}`)
	return res
}

// applyFailResult is a rejected apply whose first op errored.
func applyFailResult(node, errText string) *executorclient.ApplyResult {
	res := &executorclient.ApplyResult{}
	resultFromJSON(res, `{"node":"`+node+`","ok":false,"results":[{"kind":"gcu","ok":false,"error":"`+errText+`"}]}`)
	return res
}

// verifyAllOK passes every check the executor was handed.
func verifyAllOK(node string, checks []fabricplan.Check) *executorclient.VerifyResult {
	// The path stage's read (T520) is a single read-only command check with
	// an EMPTY Expect: it never asserts, it carries the observed route table
	// back in Actual. The default fake models a converged steered device —
	// the pin via the node's spine01 leg, the test site's preferred spine —
	// the same table `ip -6 route show` prints on the lab.
	if len(checks) == 1 && checks[0].Type == "command" &&
		checks[0].Command == "ip -6 route show" && checks[0].Expect == "" {
		return verifyScripted(node, checks, true, convergedRouteTable(node), "")
	}
	return verifyScripted(node, checks, true, "", "")
}

// convergedRouteTable is the default fake's `ip -6 route show` slice for the
// test site (DefaultSiteFacts): the /48 pin, the decap route and — on each
// attachment node — the per-service pin via that node's spine01 leg toward
// the PEER function space (data-model §8.6; leaf01 is 3, leaf02 is 4).
func convergedRouteTable(node string) string {
	peer := "fcbb:bbbb:4:11::"
	leg := "2001:db8:1::3"
	if node == "leaf02" {
		peer = "fcbb:bbbb:3:11::"
		leg = "2001:db8:1::5"
	}
	return "fcbb:bbbb:3::/48 via 2001:db8:1::3 dev Ethernet0 metric 5\n" +
		peer + " from :: via " + leg + " dev Ethernet0 metric 20\n"
}

// verifyAllFail fails every check with the same detail.
func verifyAllFail(node string, checks []fabricplan.Check, errText string) *executorclient.VerifyResult {
	return verifyScripted(node, checks, false, "", errText)
}

func verifyScripted(node string, checks []fabricplan.Check, ok bool, actual, errText string) *executorclient.VerifyResult {
	res := &executorclient.VerifyResult{Node: node}
	// The actual/err text is JSON-escaped (the route table the path read
	// carries is multi-line; a raw newline would break the payload).
	actualJSON, errTextJSON := jsonString(actual), jsonString(errText)
	payload := `{"node":"` + node + `","ok":` + boolJSON(ok) + `,"results":[`
	for i := range checks {
		if i > 0 {
			payload += ","
		}
		payload += `{"check":"checks[` + itoa(i) + `]","ok":` + boolJSON(ok)
		if actualJSON != `""` {
			payload += `,"actual":` + actualJSON
		}
		if errTextJSON != `""` {
			payload += `,"error":` + errTextJSON
		}
		payload += `}`
	}
	payload += `]}`
	resultFromJSON(res, payload)
	return res
}

// jsonString marshals s as a JSON string ("": for an empty input).
func jsonString(s string) string {
	b, err := json.Marshal(s)
	if err != nil {
		return `""`
	}
	return string(b)
}

func boolJSON(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

func itoa(i int) string {
	return json.Number(jsonInt(i)).String()
}

func jsonInt(i int) string {
	b, _ := json.Marshal(i)
	return string(b)
}

// readyCondition returns the Ready condition of a status (or nil).
func readyCondition(st *agenticnetopsv1alpha1.SRv6ServiceStatus) *metav1.Condition {
	for i := range st.Conditions {
		if st.Conditions[i].Type == ConditionReady {
			return &st.Conditions[i]
		}
	}
	return nil
}

// converge drives reconciles until the service settles: Ready=True, or the
// same (reason, message) twice in a row (a terminal refusal or a stuck
// non-terminal one). The caller asserts on the returned object.
func converge(t *testing.T, r *Reconciler, key types.NamespacedName) *agenticnetopsv1alpha1.SRv6Service {
	t.Helper()
	ctx := context.Background()
	var prev, last string
	for i := 0; i < 8; i++ {
		if _, err := r.Reconcile(ctx, ctrl.Request{NamespacedName: key}); err != nil {
			t.Fatalf("reconcile: %v", err)
		}
		var got agenticnetopsv1alpha1.SRv6Service
		if err := r.Get(ctx, key, &got); err != nil {
			t.Fatalf("get after reconcile: %v", err)
		}
		cond := readyCondition(&got.Status)
		if cond == nil {
			// The finalizer pass patches metadata only — no status yet.
			last = "no Ready condition after reconcile " + itoa(i)
			continue
		}
		if cond.Status == metav1.ConditionTrue {
			return &got
		}
		state := cond.Reason + "|" + cond.Message + "|gen" + itoa(int(cond.ObservedGeneration))
		last = state
		if state == prev {
			return &got
		}
		prev = state
	}
	t.Fatalf("service never settled; last state: %s", last)
	return nil
}

// convergeService wires testReconciler and converges one named service.
func convergeService(t *testing.T, c client.Client, ex *recordingExecutor, pins *corev1.ConfigMap, name string) *agenticnetopsv1alpha1.SRv6Service {
	t.Helper()
	return converge(t, testReconciler(t, c, ex, pins), testKey(name))
}

var hashShape = regexp.MustCompile(`^[0-9a-f]{64}$`)

// TestPlanHashesEveryNodeOfTheRender is T378: BuildPlan renders through
// fabricplan.ForSRv6Service (the kernel port of the site port map appears in
// the ops — only the renderer resolves wan1 → Ethernet12) and PlanHashes
// gives one stable sha256 per node, stored in status.configHashes.
func TestPlanHashesEveryNodeOfTheRender(t *testing.T) {
	svc := testService("plan-hashes", "plan-hashes-1")
	alloc := testAllocation(t, svc)

	plan, err := BuildPlan(svc, alloc, DefaultSiteFacts())
	if err != nil {
		t.Fatalf("BuildPlan: %v", err)
	}
	order := PlanOrder(plan)
	if len(order) != 2 || order[0] != "leaf01" || order[1] != "leaf02" {
		t.Fatalf("PlanOrder = %v, want [leaf01 leaf02] (one NodePlan per attachment)", order)
	}
	// The renderer resolved the logical port through the site port map.
	for _, node := range order {
		rendered := ""
		for _, op := range plan.Nodes[node].Ops {
			rendered += canonicalOp(op)
		}
		if !regexp.MustCompile(`Ethernet12`).MatchString(rendered) {
			t.Errorf("node %s ops carry no resolved kernel port (want Ethernet12): the render did not go through fabricplan.ForSRv6Service", node)
		}
	}

	hashes := PlanHashes(plan)
	if len(hashes) != 2 {
		t.Fatalf("PlanHashes covered %d nodes, want 2", len(hashes))
	}
	for _, node := range order {
		if !hashShape.MatchString(hashes[node]) {
			t.Errorf("hash for %s = %q, want a sha256 hex digest", node, hashes[node])
		}
	}
	if hashes["leaf01"] == hashes["leaf02"] {
		t.Error("distinct nodes rendered identical hashes; the hash does not cover the per-node ops")
	}
	if !hashesEqual(hashes, PlanHashes(mustReplan(t, svc, alloc))) {
		t.Error("re-rendering the same (svc, alloc, facts) changed the hashes; the renderer must be pure")
	}
	changed := testService("plan-hashes", "plan-hashes-1")
	changed.Spec.Path.PreferredSpine = "spine02"
	if hashesEqual(hashes, PlanHashes(mustReplan(t, changed, alloc))) {
		t.Error("a changed spec produced identical hashes; the hash does not track the render")
	}
	if hashesEqual(nil, hashes) {
		t.Error("hashesEqual matched an empty stored map; the first apply must never be skipped")
	}

	// Reconcile level: the stored status.configHashes are exactly the fresh
	// render's hashes.
	name := "plan-hashes-live"
	c := newTestClient(t, testService(name, "plan-hashes-live"))
	testClaims(t, c, "plan-hashes-live")
	svcLive := convergeService(t, c, &recordingExecutor{}, goodPins(), name)
	if cond := readyCondition(&svcLive.Status); cond == nil || cond.Status != metav1.ConditionTrue {
		t.Fatalf("service not Ready: %+v", cond)
	}
	fresh, err := BuildPlan(svcLive, testAllocation(t, svcLive), DefaultSiteFacts())
	if err != nil {
		t.Fatalf("re-render after converge: %v", err)
	}
	want := PlanHashes(fresh)
	if len(svcLive.Status.ConfigHashes) != len(want) {
		t.Fatalf("status.configHashes has %d entries, want %d", len(svcLive.Status.ConfigHashes), len(want))
	}
	for node, h := range want {
		if svcLive.Status.ConfigHashes[node] != h {
			t.Errorf("status.configHashes[%s] = %q, want the fresh render's %q", node, svcLive.Status.ConfigHashes[node], h)
		}
	}
}

// testAllocation builds the Allocation a claimed service would carry,
// including the per-node service SIDs derived from the bootstrap locators.
func testAllocation(t *testing.T, svc *agenticnetopsv1alpha1.SRv6Service) *Allocation {
	t.Helper()
	sids, err := serviceSIDs(svc, DefaultSiteFacts().Locators)
	if err != nil {
		t.Fatalf("serviceSIDs: %v", err)
	}
	return &Allocation{
		Allocations: &agenticnetopsv1alpha1.Allocations{
			ServiceID:      7,
			VRF:            "Vrf7",
			ClientPrefixes: map[string]string{"leaf01": "192.168.35.0/24", "leaf02": "192.168.36.0/24"},
		},
		ServiceSIDs: sids,
	}
}

func mustReplan(t *testing.T, svc *agenticnetopsv1alpha1.SRv6Service, alloc *Allocation) *fabricplan.Plan {
	t.Helper()
	plan, err := BuildPlan(svc, alloc, DefaultSiteFacts())
	if err != nil {
		t.Fatalf("re-render: %v", err)
	}
	return plan
}
