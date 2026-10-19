// SPDX-License-Identifier: Apache-2.0
//
// Events tests, T397: every reason the reconciler records reaches the
// operator exactly once as a Kubernetes event AND exactly once as a
// structured log line carrying reason=<reason> — the one-event-one-log-line
// contract of events.go. The refusal path (r.refuse) and the ready path
// (emitCondition with the Verified condition) are both driven.
package srv6service

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"

	"github.com/go-logr/logr"
	agenticnetopsv1alpha1 "github.com/mairp/agentic-netops/api/v1alpha1"
	"github.com/mairp/agentic-netops/pkg/reasons"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/tools/record"
)

// capturedLine is one structured log line: the message plus the flat
// key/value pairs emit logged with it.
type capturedLine struct {
	msg     string
	kv      map[string]string
	level   int
	isError bool
}

// logCapture is a logr.LogSink that records every Info/Error line with its
// structured key/values, so the test can assert the one-log-line-per-reason
// contract instead of trusting a formatted string.
type logCapture struct {
	mu    sync.Mutex
	lines []capturedLine
}

func (l *logCapture) Init(logr.RuntimeInfo) {}

func (l *logCapture) Enabled(int) bool { return true }

func (l *logCapture) Info(level int, msg string, keysAndValues ...any) {
	l.record(false, level, msg, keysAndValues...)
}

func (l *logCapture) Error(err error, msg string, keysAndValues ...any) {
	l.record(true, 0, msg, keysAndValues...)
}

func (l *logCapture) record(isErr bool, level int, msg string, keysAndValues ...any) {
	kv := map[string]string{}
	for i := 0; i+1 < len(keysAndValues); i += 2 {
		kv[fmt.Sprint(keysAndValues[i])] = fmt.Sprint(keysAndValues[i+1])
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.lines = append(l.lines, capturedLine{msg: msg, kv: kv, level: level, isError: isErr})
}

func (l *logCapture) WithValues(...any) logr.LogSink { return l }

func (l *logCapture) WithName(string) logr.LogSink { return l }

// forReason returns the captured Info lines whose reason key equals reason.
func (l *logCapture) forReason(reason string) []capturedLine {
	l.mu.Lock()
	defer l.mu.Unlock()
	var out []capturedLine
	for _, line := range l.lines {
		if !line.isError && line.kv["reason"] == reason {
			out = append(out, line)
		}
	}
	return out
}

// drainEvents reads everything the fake recorder buffered.
func drainEvents(rec *record.FakeRecorder) []string {
	var out []string
	for {
		select {
		case e := <-rec.Events:
			out = append(out, e)
		default:
			return out
		}
	}
}

// eventFor counts the recorded events of one reason and returns the first
// match. FakeRecorder renders "<eventtype> <reason> <message>".
func eventFor(events []string, reason string) (count int, eventtype, message string) {
	for _, e := range events {
		parts := strings.SplitN(e, " ", 3)
		if len(parts) < 3 {
			continue
		}
		if parts[1] == reason {
			count++
			if count == 1 {
				eventtype, message = parts[0], parts[2]
			}
		}
	}
	return count, eventtype, message
}

// TestRefusalEmitsOneEventAndOneLogLinePerReason drives r.refuse for every
// §6 reason the reconciler records and asserts the pair appears exactly once
// per reason: one Warning event carrying the reason and the message, and one
// structured log line with reason=<reason> and the same message.
func TestRefusalEmitsOneEventAndOneLogLinePerReason(t *testing.T) {
	ctx := context.Background()
	c := newTestClient(t, testService("evt", "evt"))
	r := testReconciler(t, c, &recordingExecutor{}, goodPins())
	rec := record.NewFakeRecorder(64)
	logs := &logCapture{}
	r.Recorder = rec
	r.Log = logr.New(logs)

	// The §6 refusal reasons with the pipeline kind each refusal carries
	// (types.go) — the kinds decide requeue behaviour, the reason is what
	// the operator sees.
	cases := []struct {
		reason string
		kind   refusalKind
	}{
		{reasons.ReasonInvalidSite, refusalSite},
		{reasons.ReasonPortInUse, refusalPort},
		{reasons.ReasonCapabilityMissing, refusalCap},
		{reasons.ReasonDataPathUnverifiable, refusalCap},
		{reasons.ReasonUnsupportedVariant, refusalVariant},
		{reasons.ReasonPoolExhausted, refusalPool},
		{reasons.ReasonVlanInUse, refusalVlan},
		{reasons.ReasonApplyFailed, refusalApply},
		{reasons.ReasonCheckFailed, refusalCheck},
		{reasons.ReasonLocatorMissing, refusalLocator},
		{reasons.ReasonDataPathFailed, refusalDataPath},
		{reasons.ReasonPathDown, refusalPath},
		{reasons.ReasonFinalizing, refusalFinalizing},
	}
	for _, tc := range cases {
		t.Run(tc.reason, func(t *testing.T) {
			var live agenticnetopsv1alpha1.SRv6Service
			if err := c.Get(ctx, testKey("evt"), &live); err != nil {
				t.Fatalf("get service: %v", err)
			}
			msg := fmt.Sprintf("unit-test refusal for %s", tc.reason)
			if _, err := r.refuse(ctx, &live, &Refusal{Reason: tc.reason, Message: msg, Kind: tc.kind}); err != nil {
				t.Fatalf("refuse: %v", err)
			}

			events := drainEvents(rec)
			count, eventtype, eventMsg := eventFor(events, tc.reason)
			if count != 1 {
				t.Fatalf("reason %s: got %d events (%v), want exactly 1", tc.reason, count, events)
			}
			if eventtype != corev1.EventTypeWarning {
				t.Errorf("reason %s: event type %q, want Warning for a refusal", tc.reason, eventtype)
			}
			if !strings.Contains(eventMsg, msg) {
				t.Errorf("reason %s: event message %q does not carry the refusal message %q", tc.reason, eventMsg, msg)
			}

			lines := logs.forReason(tc.reason)
			if len(lines) != 1 {
				t.Fatalf("reason %s: got %d structured log lines, want exactly 1", tc.reason, len(lines))
			}
			if !strings.Contains(lines[0].msg, msg) {
				t.Errorf("reason %s: log line %q does not carry the message %q", tc.reason, lines[0].msg, msg)
			}
		})
	}
}

// TestVerifiedEmitsOneNormalEventAndOneLogLine pins the ready path of the
// same contract: the Verified condition emits one Normal event and one
// structured log line, both carrying reason=Verified.
func TestVerifiedEmitsOneNormalEventAndOneLogLine(t *testing.T) {
	ctx := context.Background()
	c := newTestClient(t, testService("evt-ready", "evt-ready"))
	r := testReconciler(t, c, &recordingExecutor{}, goodPins())
	rec := record.NewFakeRecorder(16)
	logs := &logCapture{}
	r.Recorder = rec
	r.Log = logr.New(logs)

	var live agenticnetopsv1alpha1.SRv6Service
	if err := c.Get(ctx, testKey("evt-ready"), &live); err != nil {
		t.Fatalf("get service: %v", err)
	}
	const msg = "unit-test verified"
	r.emitCondition(&live, readyTrue(live.Generation), "%s", msg)

	events := drainEvents(rec)
	count, eventtype, eventMsg := eventFor(events, reasons.ReasonVerified)
	if count != 1 {
		t.Fatalf("reason Verified: got %d events (%v), want exactly 1", count, events)
	}
	if eventtype != corev1.EventTypeNormal {
		t.Errorf("event type %q, want Normal for Verified", eventtype)
	}
	if !strings.Contains(eventMsg, msg) {
		t.Errorf("event message %q does not carry %q", eventMsg, msg)
	}

	lines := logs.forReason(reasons.ReasonVerified)
	if len(lines) != 1 {
		t.Fatalf("reason Verified: got %d structured log lines, want exactly 1", len(lines))
	}
	if !strings.Contains(lines[0].msg, msg) {
		t.Errorf("log line %q does not carry %q", lines[0].msg, msg)
	}
}
