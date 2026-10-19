// SPDX-License-Identifier: Apache-2.0
package kuid

import (
	"context"
	"fmt"
	"regexp"
	"strings"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	// Namespace is where every claim and fallback Lease lives, matching
	// agents/provisioning/allocator/kuid.py.
	Namespace = "kuid-system"
	// LabelCorrelationID stamps a claim with the service's correlation id
	// before any wait happens.
	LabelCorrelationID = "agentic-netops.io/correlation-id"
	// LabelManagedBy marks objects this package manages.
	LabelManagedBy = "app.kubernetes.io/managed-by"
	// ManagedBy is the value of LabelManagedBy for this controller.
	ManagedBy = "agentic-netops"
)

// Pool describes one claim pool of data-model.md §8.1: the kuid index that
// is the honest authority, and the served claim resource of the
// `*.be.kuid.dev` group that allocates from it.
type Pool struct {
	// Name is the kuid index name (and, for leases, the pool label value).
	Name string
	// Group/Version/Kind identify the claim resource on the aggregated API.
	Group   string
	Version string
	Kind    string
	// Plural is the claim resource's plural (path segment).
	Plural string
}

// ServiceIDPool is the integer service-id pool (Vrf<service-id>, §8.1),
// served by the GENID family. On the pinned kuid-server that family is
// broken at runtime (tier finding), so claims against it are what trigger
// the Lease fallback in lease.go.
var ServiceIDPool = Pool{
	Name:    "srv6-service-ids",
	Group:   "genid.be.kuid.dev",
	Version: "v1alpha1",
	Kind:    "GENIDClaim",
	Plural:  "genidclaims",
}

// ClientV4Pool is the per-attachment client /24 pool (192.168.0.0/16, §8.1),
// served by the ipam family, which works on the pinned server.
var ClientV4Pool = Pool{
	Name:    "srv6-client-v4",
	Group:   "ipam.be.kuid.dev",
	Version: "v1alpha1",
	Kind:    "IPClaim",
	Plural:  "ipclaims",
}

// pools this package claims from and releases; kept in one place so
// release covers everything create can produce.
var pools = []Pool{ServiceIDPool, ClientV4Pool}

// ClaimRef identifies a created claim.
type ClaimRef struct {
	Pool Pool
	Name string
}

var nameSanitizer = regexp.MustCompile(`[^a-zA-Z0-9.-]+`)

// sanitize folds a correlation id (or attachment name) into a DNS-label
// fragment, mirroring kuid.py's _label_value.
func sanitize(s string) string {
	v := nameSanitizer.ReplaceAllString(s, "-")
	v = strings.Trim(v, "-.")
	if len(v) > 63 {
		v = strings.Trim(v[:63], "-.")
	}
	if v == "" {
		return "default"
	}
	return v
}

// ClaimName builds the deterministic claim name for a correlation id (and
// optional distinguishing parts, e.g. an attachment name).
func ClaimName(pool Pool, correlationID string, parts ...string) string {
	return sanitize(strings.Join(append([]string{pool.Name, "claim", correlationID}, parts...), "-"))
}

// claimSpec returns the claim spec for the pool. Shapes follow the served
// schemas (`kubectl explain genidclaims.genid.be.kuid.dev.spec` /
// `ipclaims.ipam.be.kuid.dev.spec`): GENID claims name the index; IP claims
// name the index and ask for a /24 per attachment (data-model §8.1). The
// served IPClaim validation measures prefixLength against createPrefix — a
// claim with a prefix length but createPrefix unset is read as a
// dynamicIPRange (single address) claim and rejected ("dynamicIPRange cannot
// have a prefixLength", measured live 2026-10-16), so createPrefix must be
// set for any non-/32 carve. With it, prefixLength alone selects the length:
// the claim inherits its parent prefix from the index, and prefixType stays
// unset (defaulting to "other", not the nic-oriented "network" flavor that
// would also claim network+broadcast addresses).
func claimSpec(pool Pool) map[string]any {
	spec := map[string]any{"index": pool.Name}
	if pool.Kind == "IPClaim" {
		spec["createPrefix"] = true
		spec["prefixLength"] = int64(24)
	}
	return spec
}

// CreateServiceIDClaim claims one integer service id (the VRF name id,
// §8.1) for the correlation id. The claim is stamped with the correlation
// id before it is returned — call WaitForClaim afterwards.
func CreateServiceIDClaim(ctx context.Context, c client.Client, correlationID string) (ClaimRef, error) {
	return CreateClaim(ctx, c, ServiceIDPool, correlationID)
}

// CreateClientPrefixClaim claims one client /24 for one attachment of the
// service. The attachment name keeps the deterministic claim name unique
// per attachment.
func CreateClientPrefixClaim(ctx context.Context, c client.Client, correlationID, attachment string) (ClaimRef, error) {
	return CreateClaim(ctx, c, ClientV4Pool, correlationID, attachment)
}

// CreateClaim creates a claim object in kuid-system, deterministically
// named and labelled with the correlation id and managed-by. Creating the
// same claim twice for the same correlation id is a no-op; a name held by
// a different correlation id is a CollisionError naming the pool.
func CreateClaim(ctx context.Context, c client.Client, pool Pool, correlationID string, parts ...string) (ClaimRef, error) {
	ref := ClaimRef{Pool: pool, Name: ClaimName(pool, correlationID, parts...)}

	u := newClaimObject(pool)
	u.SetNamespace(Namespace)
	u.SetName(ref.Name)
	u.SetLabels(map[string]string{
		LabelCorrelationID: correlationID,
		LabelManagedBy:     ManagedBy,
	})
	u.Object["spec"] = claimSpec(pool)

	if err := c.Create(ctx, u); err != nil {
		if !apierrors.IsAlreadyExists(err) && !looksLikeExists(strings.ToLower(err.Error())) {
			return ref, classify(pool.Name, err)
		}
		// Exists-shaped answer (the pinned server wraps duplicates in an
		// InternalError whose message folds the words together, so the
		// apierrors check alone misses it): the name is taken. A stored
		// object under a different correlation id is a real collision; a
		// stored object under OUR id — or no stored object at all, the
		// authority's answer outrunning its own store — is this claim's
		// name being ours: no-op, and the caller's wait decides when the
		// value actually lands.
		existing, getErr := getClaim(ctx, c, ref)
		if getErr != nil {
			if apierrors.IsNotFound(getErr) {
				return ref, nil
			}
			return ref, classify(pool.Name, getErr)
		}
		if label := existing.GetLabels()[LabelCorrelationID]; label != correlationID {
			return ref, &CollisionError{
				Pool:   pool.Name,
				Detail: fmt.Sprintf("claim %s already held by correlation id %q", ref.Name, label),
			}
		}
	}
	return ref, nil
}

// newClaimObject returns an empty unstructured object for the pool's claim
// resource.
func newClaimObject(pool Pool) *unstructured.Unstructured {
	u := &unstructured.Unstructured{}
	u.SetGroupVersionKind(schema.GroupVersionKind{
		Group: pool.Group, Version: pool.Version, Kind: pool.Kind,
	})
	return u
}

// newListObject returns an empty unstructured list for the pool's claims.
func newListObject(pool Pool) *unstructured.UnstructuredList {
	list := &unstructured.UnstructuredList{}
	list.SetGroupVersionKind(schema.GroupVersionKind{
		Group: pool.Group, Version: pool.Version, Kind: pool.Kind + "List",
	})
	return list
}

// getClaim fetches one claim by ref.
func getClaim(ctx context.Context, c client.Client, ref ClaimRef) (*unstructured.Unstructured, error) {
	u := newClaimObject(ref.Pool)
	if err := c.Get(ctx, client.ObjectKey{Namespace: Namespace, Name: ref.Name}, u); err != nil {
		return nil, err
	}
	return u, nil
}
