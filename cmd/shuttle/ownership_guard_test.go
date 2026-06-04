package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/cailmdaley/shuttle/pkg/schema"
)

// withOwnHost points the CLI's daemon-state lookup at a stub returning hostID so
// resolveOwnHost (and thus ensureOwnedHere) resolves deterministically,
// independent of any real daemon running on the test machine.
func withOwnHost(t *testing.T, hostID string) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v1/state" {
			_ = json.NewEncoder(w).Encode(map[string]any{"host": hostID})
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(srv.Close)

	prev, had := os.LookupEnv("SHUTTLE_DAEMON_URL")
	if err := os.Setenv("SHUTTLE_DAEMON_URL", srv.URL); err != nil {
		t.Fatalf("setenv SHUTTLE_DAEMON_URL: %v", err)
	}
	t.Cleanup(func() {
		if had {
			_ = os.Setenv("SHUTTLE_DAEMON_URL", prev)
		} else {
			_ = os.Unsetenv("SHUTTLE_DAEMON_URL")
		}
	})
}

// TestEnsureOwnedHere exercises the guard's logic directly: a fiber pinned to
// this host (or host-less) passes; one pinned to another host is refused.
func TestEnsureOwnedHere(t *testing.T) {
	withOwnHost(t, "macbook")

	mk := func(host string) *schema.FiberFile {
		return &schema.FiberFile{Block: &schema.Block{Host: host}}
	}

	if err := ensureOwnedHere(mk("macbook"), "f"); err != nil {
		t.Fatalf("fiber owned by this host should pass: %v", err)
	}

	err := ensureOwnedHere(mk("cineca"), "f")
	if err == nil {
		t.Fatal("fiber owned by another host should be refused")
	}
	if _, ok := err.(ownerMismatchError); !ok {
		t.Fatalf("expected ownerMismatchError, got %T: %v", err, err)
	}

	if err := ensureOwnedHere(mk(""), "f"); err != nil {
		t.Fatalf("host-less block should fail open (legacy): %v", err)
	}
	if err := ensureOwnedHere(&schema.FiberFile{}, "f"); err != nil {
		t.Fatalf("nil block should pass: %v", err)
	}
}

// TestCloseCmd_RefusesRemoteOwnedFiber is the regression for the resurrecting
// tempered-card bug: `shuttle close --tempered` run on the wrong host resolved
// the local git-sync mirror and wrote it. The guard must refuse and leave the
// file byte-identical so no split-brain mirror write happens.
func TestCloseCmd_RefusesRemoteOwnedFiber(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()
	withOwnHost(t, "macbook")

	path := writeFiber(t, host, "remote-owned", `---
name: Remote owned
status: closed
shuttle:
  enabled: true
  kind: oneshot
  host: cineca
---

Body.
`)
	before := readFiberText(t, path)

	closeTempered = "true"
	defer func() { closeTempered = "" }()
	err := closeCmd.RunE(closeCmd, []string{"remote-owned"})
	if err == nil {
		t.Fatal("close on a cineca-owned fiber from macbook should be refused")
	}
	if _, ok := err.(ownerMismatchError); !ok {
		t.Fatalf("expected ownerMismatchError, got %T: %v", err, err)
	}
	if after := readFiberText(t, path); after != before {
		t.Fatalf("refused close must not write the local mirror.\nbefore:\n%s\nafter:\n%s", before, after)
	}
}

// TestCloseCmd_WritesOwnedFiber confirms the guard does not over-reach: a fiber
// whose shuttle.host IS this daemon writes normally.
func TestCloseCmd_WritesOwnedFiber(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()
	withOwnHost(t, "cineca")

	path := writeFiber(t, host, "owned-here", `---
name: Owned here
status: closed
shuttle:
  enabled: true
  kind: oneshot
  host: cineca
---

Body.
`)

	closeTempered = "true"
	defer func() { closeTempered = "" }()
	if err := closeCmd.RunE(closeCmd, []string{"owned-here"}); err != nil {
		t.Fatalf("close on a fiber owned by this host should succeed: %v", err)
	}
	if text := readFiberText(t, path); !strings.Contains(text, "tempered: true") {
		t.Fatalf("owned close should write tempered: true:\n%s", text)
	}
}

// TestPauseCmd_RefusesRemoteOwnedFiber proves the guard is wired across verbs,
// not just close. pause on a candide-owned fiber from macbook must refuse and
// leave the file unchanged (it would otherwise flip enabled:false in the mirror).
func TestPauseCmd_RefusesRemoteOwnedFiber(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()
	withOwnHost(t, "macbook")
	// Stub tmux so a guard regression can't shell out to real tmux.
	withStubbedTmux(t, map[string]bool{})

	path := writeFiber(t, host, "remote-pause", `---
name: Remote pause
status: active
shuttle:
  enabled: true
  kind: oneshot
  host: candide
---

Body.
`)
	before := readFiberText(t, path)

	cmd := newPauseCmd()
	cmd.SetArgs([]string{"remote-pause"})
	if err := cmd.Execute(); err == nil {
		t.Fatal("pause on a candide-owned fiber from macbook should be refused")
	}
	if after := readFiberText(t, path); after != before {
		t.Fatalf("refused pause must not write the local mirror.\nbefore:\n%s\nafter:\n%s", before, after)
	}
}
