package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestHandoffCmd_WritesMarkerKeyedByEnv verifies the clean-exit contract: the
// handoff marker lands at $SHUTTLE_DATA_DIR/handoff/<key> (extensionless, keyed
// by SHUTTLE_FIBER_KEY, never recomputed), carries exactly {"at": <RFC3339 UTC>},
// and that timestamp parses as a UTC time at or after a dispatch reference — the
// >= comparison the daemon runs to decide a clean exit registers as fresh.
func TestHandoffCmd_WritesMarkerKeyedByEnv(t *testing.T) {
	dataDir := t.TempDir()
	t.Setenv("SHUTTLE_DATA_DIR", dataDir)
	const key = "01KVJ7DCWEB869GFRQV5RRP8EY"
	t.Setenv("SHUTTLE_FIBER_KEY", key)

	// A dispatch reference just before the handoff; handoff.at must be >= it.
	before := time.Now().UTC()

	cmd := newHandoffCmd()
	cmd.SetArgs([]string{"some-fiber-id"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	markerPath := filepath.Join(dataDir, "handoff", key)
	raw, err := os.ReadFile(markerPath)
	if err != nil {
		t.Fatalf("reading handoff marker at %s: %v", markerPath, err)
	}

	var payload map[string]string
	if err := json.Unmarshal(raw, &payload); err != nil {
		t.Fatalf("handoff marker is not the expected JSON object: %v\n%s", err, raw)
	}
	if len(payload) != 1 {
		t.Fatalf("handoff marker must carry only {at}, got %v", payload)
	}
	at, ok := payload["at"]
	if !ok {
		t.Fatalf("handoff marker missing the \"at\" key: %s", raw)
	}

	parsed, err := time.Parse(time.RFC3339Nano, at)
	if err != nil {
		t.Fatalf("at %q is not RFC3339Nano: %v", at, err)
	}
	if parsed.Location() != time.UTC {
		t.Fatalf("at must be UTC (trailing Z), got %q", at)
	}
	if parsed.Before(before) {
		t.Fatalf("handoff at %q is before the dispatch reference %q — would read as a dirty exit", at, before.Format(time.RFC3339Nano))
	}

	// Atomic write leaves no temp files behind in the handoff dir.
	entries, err := os.ReadDir(filepath.Dir(markerPath))
	if err != nil {
		t.Fatalf("reading handoff dir: %v", err)
	}
	if len(entries) != 1 || entries[0].Name() != key {
		var names []string
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Fatalf("handoff dir should hold only the marker %q, got %v", key, names)
	}
}

// TestHandoffCmd_FailsLoudlyWithoutKey verifies the guard: a worker that was not
// launched by the daemon (no SHUTTLE_FIBER_KEY) cannot silently write a
// miskeyed marker — the command errors instead.
func TestHandoffCmd_FailsLoudlyWithoutKey(t *testing.T) {
	t.Setenv("SHUTTLE_DATA_DIR", t.TempDir())
	// Ensure SHUTTLE_FIBER_KEY is unset for this test even if the ambient env
	// or a parallel test set it.
	t.Setenv("SHUTTLE_FIBER_KEY", "")

	cmd := newHandoffCmd()
	cmd.SetArgs([]string{"some-fiber-id"})
	if err := cmd.Execute(); err == nil {
		t.Fatal("handoff with no SHUTTLE_FIBER_KEY should fail loudly, got nil error")
	}
}
