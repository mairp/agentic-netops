// SPDX-License-Identifier: Apache-2.0
//
// One event and one structured log line per reason (T397). Every refusal,
// failure and transition the reconciler records goes through emit, so the
// operator sees the §6 reason exactly once per observation, in both the event
// stream and the controller log.
package srv6service

import (
	"fmt"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

// recordEventer is the slice of record.Recorder the reconciler needs. Tests
// stub it with record.NewFakeRecorder; the manager's recorder satisfies it.
type recordEventer interface {
	Event(object runtime.Object, eventtype, reason, message string)
	Eventf(object runtime.Object, eventtype, reason, messageFmt string, args ...interface{})
}

// emit logs one structured line and records one event for the reason. A nil
// Recorder (unit tests without a manager) still logs.
func (r *Reconciler) emit(obj runtime.Object, eventtype, reason, format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	log := r.Log
	if log.GetSink() == nil {
		log = logr.Discard()
	}
	log.Info(msg, "reason", reason)
	if r.Recorder != nil {
		r.Recorder.Eventf(obj, eventtype, reason, "%s", msg)
	}
}

// emitCondition emits for a condition reason: Warning for a False condition
// (a refusal or a failure), Normal for a True one.
func (r *Reconciler) emitCondition(obj runtime.Object, cond metav1.Condition, format string, args ...any) {
	eventtype := corev1.EventTypeNormal
	if cond.Status != metav1.ConditionTrue {
		eventtype = corev1.EventTypeWarning
	}
	r.emit(obj, eventtype, cond.Reason, format, args...)
}
