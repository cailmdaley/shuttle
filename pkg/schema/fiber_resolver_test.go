package schema

import (
	"strings"
	"testing"
)

func TestChooseResolvedFiberIDPrefersExactMatch(t *testing.T) {
	results := []struct {
		ID  string `json:"id"`
		UID string `json:"uid"`
	}{
		{ID: "ai-futures/portolan/gotchas/stale-shuttle-daemon-after-schema-change"},
		{ID: "ai-futures/portolan/portolan/constitution-shuttle-portolan-version-sync"},
		{ID: "portolan/constitution-shuttle-portolan-version-sync"},
	}

	got, err := chooseResolvedFiberID("portolan/constitution-shuttle-portolan-version-sync", results)
	if err != nil {
		t.Fatalf("chooseResolvedFiberID: %v", err)
	}
	if got != "portolan/constitution-shuttle-portolan-version-sync" {
		t.Fatalf("got %q", got)
	}
}

func TestChooseResolvedFiberIDPrefersUniqueSuffixMatch(t *testing.T) {
	results := []struct {
		ID  string `json:"id"`
		UID string `json:"uid"`
	}{
		{ID: "ai-futures/portolan/gotchas/stale-shuttle-daemon-after-schema-change"},
		{ID: "ai-futures/portolan/portolan/constitution-shuttle-portolan-version-sync"},
	}

	got, err := chooseResolvedFiberID("portolan/constitution-shuttle-portolan-version-sync", results)
	if err != nil {
		t.Fatalf("chooseResolvedFiberID: %v", err)
	}
	if got != "ai-futures/portolan/portolan/constitution-shuttle-portolan-version-sync" {
		t.Fatalf("got %q", got)
	}
}

func TestChooseResolvedFiberIDRejectsAmbiguousSuffixMatches(t *testing.T) {
	results := []struct {
		ID  string `json:"id"`
		UID string `json:"uid"`
	}{
		{ID: "ai-futures/portolan/constitution-shuttle-portolan-version-sync"},
		{ID: "archive/portolan/constitution-shuttle-portolan-version-sync"},
	}

	_, err := chooseResolvedFiberID("portolan/constitution-shuttle-portolan-version-sync", results)
	if err == nil {
		t.Fatal("expected ambiguity error")
	}
	if !strings.Contains(err.Error(), "ambiguous") {
		t.Fatalf("expected ambiguity error, got %v", err)
	}
}

func TestChooseResolvedFiberIDAcceptsIntrinsicUID(t *testing.T) {
	results := []struct {
		ID  string `json:"id"`
		UID string `json:"uid"`
	}{
		{ID: "ai-futures/shuttle/constitution/constitution-federated-fiber-identity", UID: "01KTCA2CWXBSNHETE66MXKPVE7"},
		{ID: "ai-futures/shuttle/constitution/other", UID: "01KTCA2CWX6D5N12DME1MM55N2"},
	}

	got, err := chooseResolvedFiberID("01KTCA2CWXBSNHETE66MXKPVE7", results)
	if err != nil {
		t.Fatalf("chooseResolvedFiberID: %v", err)
	}
	if got != "ai-futures/shuttle/constitution/constitution-federated-fiber-identity" {
		t.Fatalf("got %q", got)
	}
}
