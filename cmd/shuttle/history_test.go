package main

import "testing"

// TestExtractSessionID locks the parsing contract that mirrors the dispatcher's
// Elixir extract_session_id/1: a real dispatch event yields its session id, the
// "<unknown>" sentinel and session-less text yield "", and the marker must sit
// at a word boundary (start-of-string or after whitespace).
func TestExtractSessionID(t *testing.T) {
	cases := []struct {
		name string
		text string
		want string
	}{
		{
			name: "real dispatch event",
			text: "worker dispatched (agent=claude-opus) session=24299999-279d-4c02-85c7-9815e27e7247",
			want: "24299999-279d-4c02-85c7-9815e27e7247",
		},
		{
			name: "id with the full allowed char class at start",
			text: "session=abcd.1234:ef_56-78",
			want: "abcd.1234:ef_56-78",
		},
		{
			name: "unknown sentinel is not resumable",
			text: "worker dispatched (agent=claude-sonnet) session=<unknown>",
			want: "",
		},
		{
			name: "worker-exit event carries no session",
			text: "worker exited (:session_not_found); agent=claude-opus",
			want: "",
		},
		{
			name: "session= must be at a word boundary",
			text: "prefixsession=should-not-match",
			want: "",
		},
		{
			name: "empty text",
			text: "",
			want: "",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := extractSessionID(tc.text); got != tc.want {
				t.Fatalf("extractSessionID(%q) = %q, want %q", tc.text, got, tc.want)
			}
		})
	}
}

// TestLatestResumableSessionID covers the end-to-end read against a real felt
// store: a never-run fiber has no session, and the most recent dispatch event's
// session id is recovered once one is on file.
func TestLatestResumableSessionID(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	writeFiber(t, host, "never-run", `---
name: Never run
status: open
shuttle:
  kind: oneshot
  agent: claude-sonnet
---

Body.
`)

	if got := latestResumableSessionID(host, "never-run"); got != "" {
		t.Fatalf("never-run fiber should have no resumable session, got %q", got)
	}

	writeFiber(t, host, "has-run", `---
name: Has run
status: open
shuttle:
  kind: oneshot
  agent: claude-sonnet
---

Body.
`)
	if err := appendFeltHistory(host, "has-run",
		"worker dispatched (agent=claude-sonnet) session=aaaa-bbbb-cccc-dddd"); err != nil {
		t.Fatalf("seed dispatch event: %v", err)
	}
	if err := appendFeltHistory(host, "has-run",
		"worker exited (:session_not_found); agent=claude-sonnet"); err != nil {
		t.Fatalf("seed exit event: %v", err)
	}

	if got := latestResumableSessionID(host, "has-run"); got != "aaaa-bbbb-cccc-dddd" {
		t.Fatalf("expected the dispatched session id, got %q", got)
	}
}
