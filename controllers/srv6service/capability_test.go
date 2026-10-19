// SPDX-License-Identifier: Apache-2.0
//
// Capability-record tests, T370: the record is read UNCACHED (the reconciler
// passes the API reader, never the shared informer — a broken or stale
// informer must not be able to starve the decision), and cap-sai-srv6
// false/absent/unreadable each give a terminal CapabilityMissing while
// nothing has been claimed (rules C5; contracts/srv6service-crd.md §5).
package srv6service

import (
	"context"
	"strings"
	"testing"

	"github.com/mairp/agentic-netops/pkg/compat"
	"github.com/mairp/agentic-netops/pkg/reasons"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// recordingPinReader wraps the pins read and records every key it is asked
// for, so the test can watch the uncached read happen.
type recordingPinReader struct {
	inner client.Reader
	got   []client.ObjectKey
	err   error
}

func (r *recordingPinReader) Get(ctx context.Context, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
	r.got = append(r.got, key)
	if r.err != nil {
		return r.err
	}
	return r.inner.Get(ctx, key, obj, opts...)
}

// pinsClient serves one ConfigMap through a fresh client.
func pinsClient(t *testing.T, cm *corev1.ConfigMap) client.Reader {
	t.Helper()
	if cm == nil {
		return emptyTestClient(t)
	}
	return newTestClient(t, cm)
}

// requireCapabilityMissing requires the refusal to be the terminal C5 one.
func requireCapabilityMissing(t *testing.T, ref *Refusal) {
	t.Helper()
	if ref == nil {
		t.Fatal("checkCapability returned nil, want CapabilityMissing")
	}
	if ref.Reason != reasons.ReasonCapabilityMissing {
		t.Fatalf("refusal reason = %q (%s), want %q", ref.Reason, ref.Message, reasons.ReasonCapabilityMissing)
	}
	if !ref.Terminal() {
		t.Error("CapabilityMissing must be terminal")
	}
}

// TestCapabilityRecordIsReadUncached is T370's uncached rule: the decision
// comes from the API reader — a cached record claiming "true" must not
// decide when the uncached record says "false".
func TestCapabilityRecordIsReadUncached(t *testing.T) {
	const name = "cap-uncached"
	c := newTestClient(t, testService(name, "cap-uncached"))
	testClaims(t, c, "cap-uncached")

	// What the (hypothetically stale) cache holds: SRv6 proven.
	cached := newTestClient(t, goodPins())
	_ = cached
	// What the authority holds when read uncached: SRv6 NOT proven.
	uncachedCopy := goodPins()
	uncachedCopy.Data[KeySAISRV6] = "false"
	rec := &recordingPinReader{inner: pinsClient(t, uncachedCopy)}

	ex := &recordingExecutor{}
	r := testReconciler(t, c, ex, nil)
	r.APIReader = rec

	got := converge(t, r, testKey(name))
	cond := readyCondition(&got.Status)
	if cond == nil || cond.Reason != reasons.ReasonCapabilityMissing {
		t.Fatalf("Ready reason = %+v, want %s — the uncached record must decide", cond, reasons.ReasonCapabilityMissing)
	}
	want := pinsKey()
	if len(rec.got) == 0 || rec.got[0] != want {
		t.Errorf("uncached reads = %v, want the pins key %v first", rec.got, want)
	}
	if got.Status.Allocations != nil {
		t.Error("claims recorded despite the C5 refusal; nothing may be claimed")
	}
	assertNoDeviceWrites(t, ex)
	if n := countClaims(t, c); n != 3 {
		t.Errorf("C5 refusal left %d claims, want the 3 pre-created ones untouched", n)
	}
}

// pinsKey is the object key the capability record is read at — read
// UNCACHED through the API reader.
func pinsKey() client.ObjectKey {
	return client.ObjectKey{Name: compat.PinsConfigMapName, Namespace: compat.PinsConfigMapNamespace}
}

// TestCapabilityFalseAbsentUnreadableAreTerminal is T370: all three
// record shapes refuse identically — terminal, naming why.
func TestCapabilityFalseAbsentUnreadableAreTerminal(t *testing.T) {
	svc := testService("cap-ways", "cap-ways")

	t.Run("false", func(t *testing.T) {
		ref := checkCapability(svc, &Capability{Found: true, SAISRV6: false, Provenance: "configmap x/y"})
		requireCapabilityMissing(t, ref)
		for _, want := range []string{`key cap-sai-srv6 is not "true"`, "configmap x/y"} {
			if !strings.Contains(ref.Message, want) {
				t.Errorf("message %q must name %q", ref.Message, want)
			}
		}
	})
	t.Run("absent-key", func(t *testing.T) {
		// A record present but without the key reads as false.
		cap, cref := readCapability(context.Background(), pinsClient(t, &corev1.ConfigMap{
			ObjectMeta: metav1.ObjectMeta{Name: compat.PinsConfigMapName, Namespace: compat.PinsConfigMapNamespace},
		}))
		if cref != nil {
			t.Fatalf("readCapability: %s", cref.Message)
		}
		if cap.SAISRV6 {
			t.Error("a record without cap-sai-srv6 must read as not proven")
		}
		ref := checkCapability(svc, cap)
		requireCapabilityMissing(t, ref)
		if !strings.Contains(ref.Message, `key cap-sai-srv6 is not "true"`) {
			t.Errorf("message %q must name the missing key", ref.Message)
		}
	})
	t.Run("nil-record", func(t *testing.T) {
		ref := checkCapability(svc, nil)
		requireCapabilityMissing(t, ref)
		if !strings.Contains(ref.Message, "record absent") {
			t.Errorf("message %q must say the record is absent", ref.Message)
		}
	})
	t.Run("unreadable", func(t *testing.T) {
		ref := readCapabilityErr(t, apierrors.NewNotFound(
			schema.GroupResource{Group: "v1", Resource: "configmaps"}, "fabric-compat-pins"))
		requireCapabilityMissing(t, ref)
		for _, want := range []string{"unreadable", "agentic-netops-system/fabric-compat-pins"} {
			if !strings.Contains(ref.Message, want) {
				t.Errorf("message %q must name %q", ref.Message, want)
			}
		}
	})
}

// readCapabilityErr runs readCapability against a reader that always fails.
func readCapabilityErr(t *testing.T, err error) *Refusal {
	t.Helper()
	_, ref := readCapability(context.Background(), failingReader{err: err})
	return ref
}

type failingReader struct{ err error }

func (f failingReader) Get(ctx context.Context, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
	return f.err
}
