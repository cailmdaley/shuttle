package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

// fiberWithShuttleBlock writes a temp fiber `.md` whose shuttle: block already
// carries the daemon-written dispatch fields, and returns its path.
func fiberWithShuttleBlock(t *testing.T, dispatchedAt, sessionUUID string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "fiber.md")
	content := "---\n" +
		"id: 01KVJ7DCWEB869GFRQV5RRP8EY\n" +
		"status: active\n" +
		"shuttle:\n" +
		"    kind: oneshot\n" +
		"    host: dapmcw68\n" +
		"    session_uuid: " + sessionUUID + "\n" +
		"    dispatched_at: " + dispatchedAt + "\n" +
		"---\n" +
		"# body\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("writing fiber: %v", err)
	}
	return path
}

func readFrontmatter(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading fiber: %v", err)
	}
	parts := strings.SplitN(string(raw), "---\n", 3)
	if len(parts) < 3 {
		t.Fatalf("fiber has no frontmatter:\n%s", raw)
	}
	return parts[1]
}

// handedOffAt extracts the shuttle.handed_off_at value from the block. The Go
// writer emits it as a quoted scalar, so a generic YAML decode yields a string
// (bare ISO timestamps would coerce to time.Time, which is why preservation of
// the daemon-written fields is checked against the raw text instead).
func handedOffAt(t *testing.T, fm string) string {
	t.Helper()
	var doc map[string]any
	if err := yaml.Unmarshal([]byte(fm), &doc); err != nil {
		t.Fatalf("parsing frontmatter: %v\n%s", err, fm)
	}
	block, ok := doc["shuttle"].(map[string]any)
	if !ok {
		t.Fatalf("no shuttle: block in frontmatter: %v", doc)
	}
	at, ok := block["handed_off_at"].(string)
	if !ok {
		t.Fatalf("handed_off_at missing or not a string: %v", block["handed_off_at"])
	}
	return at
}

// TestHandoffCmd_StampsHandedOffAt verifies the clean-exit contract: handoff
// stamps shuttle.handed_off_at = now (RFC3339 UTC, >= the dispatch reference, so
// the daemon's >= comparison reads it as a clean exit) into the file at
// SHUTTLE_FIBER_PATH, while PRESERVING the daemon-written session_uuid and
// dispatched_at.
func TestHandoffCmd_StampsHandedOffAt(t *testing.T) {
	const dispatchedAt = "2026-06-20T18:00:00Z"
	const sessionUUID = "11111111-2222-3333-4444-555555555555"
	path := fiberWithShuttleBlock(t, dispatchedAt, sessionUUID)
	t.Setenv("SHUTTLE_FIBER_PATH", path)

	before := time.Now().UTC()

	cmd := newHandoffCmd()
	cmd.SetArgs([]string{"some-fiber-id"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	fm := readFrontmatter(t, path)

	// The clean-exit field landed and is a UTC timestamp at or after dispatch.
	at := handedOffAt(t, fm)
	parsed, err := time.Parse(time.RFC3339Nano, at)
	if err != nil {
		t.Fatalf("handed_off_at %q is not RFC3339Nano: %v", at, err)
	}
	if parsed.Location() != time.UTC {
		t.Fatalf("handed_off_at must be UTC (trailing Z), got %q", at)
	}
	if parsed.Before(before) {
		t.Fatalf("handed_off_at %q is before dispatch ref %q — would read as a dirty exit", at, before.Format(time.RFC3339Nano))
	}

	// The daemon-written dispatch fields survive the worker's stamp (checked on
	// the raw text — a bare ISO timestamp would coerce to time.Time under a
	// generic YAML decode, masking byte-level preservation).
	for _, want := range []string{
		"session_uuid: " + sessionUUID,
		"dispatched_at: " + dispatchedAt,
		"kind: oneshot",
	} {
		if !strings.Contains(fm, want) {
			t.Fatalf("dispatch field not preserved: missing %q in:\n%s", want, fm)
		}
	}
}

// TestHandoffCmd_FailsLoudlyWithoutTarget verifies the guard: a worker that was
// not launched by the daemon (no SHUTTLE_FIBER_PATH) and whose <fiber> argument
// does not resolve cannot silently no-op — the command errors instead.
func TestHandoffCmd_FailsLoudlyWithoutTarget(t *testing.T) {
	t.Setenv("SHUTTLE_FIBER_PATH", "")
	// Point felt-store resolution at an empty dir so the fallback resolve fails.
	t.Setenv("LOOM_HOME", t.TempDir())
	t.Setenv("LOOM_HOMES", "")

	cmd := newHandoffCmd()
	cmd.SetArgs([]string{"definitely-not-a-real-fiber-xyz"})
	if err := cmd.Execute(); err == nil {
		t.Fatal("handoff with no SHUTTLE_FIBER_PATH and an unresolvable fiber should fail loudly, got nil error")
	}
}
