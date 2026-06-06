package schema

import (
	"strings"
	"testing"
)

func TestChooseResolvedFiberPrefersExactMatch(t *testing.T) {
	results := []feltFiber{
		{ID: "ai-futures/portolan/gotchas/stale-shuttle-daemon-after-schema-change"},
		{ID: "ai-futures/portolan/portolan/constitution-shuttle-portolan-version-sync"},
		{ID: "portolan/constitution-shuttle-portolan-version-sync", Path: "/loom/.felt/portolan/constitution-shuttle-portolan-version-sync.md"},
	}

	got, err := chooseResolvedFiber("portolan/constitution-shuttle-portolan-version-sync", results)
	if err != nil {
		t.Fatalf("chooseResolvedFiber: %v", err)
	}
	if got.ID != "portolan/constitution-shuttle-portolan-version-sync" {
		t.Fatalf("got id %q", got.ID)
	}
	if got.Path != "/loom/.felt/portolan/constitution-shuttle-portolan-version-sync.md" {
		t.Fatalf("got path %q; exact match must carry felt's path", got.Path)
	}
}

func TestChooseResolvedFiberPrefersUniqueSuffixMatch(t *testing.T) {
	results := []feltFiber{
		{ID: "ai-futures/portolan/gotchas/stale-shuttle-daemon-after-schema-change"},
		{ID: "ai-futures/portolan/portolan/constitution-shuttle-portolan-version-sync", Path: "/loom/.felt/x.md"},
	}

	got, err := chooseResolvedFiber("portolan/constitution-shuttle-portolan-version-sync", results)
	if err != nil {
		t.Fatalf("chooseResolvedFiber: %v", err)
	}
	if got.ID != "ai-futures/portolan/portolan/constitution-shuttle-portolan-version-sync" {
		t.Fatalf("got id %q", got.ID)
	}
	if got.Path != "/loom/.felt/x.md" {
		t.Fatalf("got path %q; suffix match must carry felt's path", got.Path)
	}
}

func TestChooseResolvedFiberRejectsAmbiguousSuffixMatches(t *testing.T) {
	results := []feltFiber{
		{ID: "ai-futures/portolan/constitution-shuttle-portolan-version-sync"},
		{ID: "archive/portolan/constitution-shuttle-portolan-version-sync"},
	}

	_, err := chooseResolvedFiber("portolan/constitution-shuttle-portolan-version-sync", results)
	if err == nil {
		t.Fatal("expected ambiguity error")
	}
	if !strings.Contains(err.Error(), "ambiguous") {
		t.Fatalf("expected ambiguity error, got %v", err)
	}
}

func TestChooseResolvedFiberAcceptsIntrinsicUID(t *testing.T) {
	results := []feltFiber{
		{
			ID:   "ai-futures/shuttle/constitution/constitution-federated-fiber-identity",
			UID:  "01KTCA2CWXBSNHETE66MXKPVE7",
			Path: "/loom/.felt/ai-futures/shuttle/constitution/constitution-federated-fiber-identity/constitution-federated-fiber-identity.md",
		},
		{ID: "ai-futures/shuttle/constitution/other", UID: "01KTCA2CWX6D5N12DME1MM55N2"},
	}

	got, err := chooseResolvedFiber("01KTCA2CWXBSNHETE66MXKPVE7", results)
	if err != nil {
		t.Fatalf("chooseResolvedFiber: %v", err)
	}
	if got.ID != "ai-futures/shuttle/constitution/constitution-federated-fiber-identity" {
		t.Fatalf("got id %q", got.ID)
	}
	if got.Path == "" {
		t.Fatalf("uid match must carry felt's path")
	}
}
