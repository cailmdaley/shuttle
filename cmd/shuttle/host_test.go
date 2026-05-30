package main

import (
	"os"
	"testing"
)

// resolveOwnHost's precedence: explicit --host wins; otherwise the local
// daemon's own_host_id; otherwise SHUTTLE_HOST; otherwise os.Hostname().
// These tests exercise the daemon-unreachable branch (point the daemon URL
// at a closed port) so the env/hostname fallbacks are observable without a
// running daemon.

func TestResolveOwnHost_FlagWins(t *testing.T) {
	// Even with the daemon reachable, an explicit flag short-circuits first.
	got, err := resolveOwnHost("  candide ")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "candide" {
		t.Fatalf("expected flag value trimmed to 'candide', got %q", got)
	}
}

func TestResolveOwnHost_EnvFallbackWhenDaemonDown(t *testing.T) {
	t.Setenv("SHUTTLE_DAEMON_URL", "http://127.0.0.1:1") // unreachable
	t.Setenv("SHUTTLE_HOST", "env-host")

	got, err := resolveOwnHost("")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "env-host" {
		t.Fatalf("expected SHUTTLE_HOST fallback 'env-host', got %q", got)
	}
}

func TestResolveOwnHost_HostnameFallbackWhenDaemonDownAndEnvUnset(t *testing.T) {
	t.Setenv("SHUTTLE_DAEMON_URL", "http://127.0.0.1:1") // unreachable
	os.Unsetenv("SHUTTLE_HOST")

	got, err := resolveOwnHost("")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	name, _ := os.Hostname()
	if got != name {
		t.Fatalf("expected os.Hostname() fallback %q, got %q", name, got)
	}
}
