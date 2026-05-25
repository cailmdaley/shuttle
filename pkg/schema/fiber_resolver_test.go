package schema

import (
	"strings"
	"testing"
)

func TestChooseResolvedFiberIDPrefersExactMatch(t *testing.T) {
	results := []struct {
		ID string `json:"id"`
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
		ID string `json:"id"`
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
		ID string `json:"id"`
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
