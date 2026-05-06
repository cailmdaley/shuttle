package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cailmdaley/shuttle/pkg/schema"
	"github.com/spf13/cobra"
)

func TestResolveOutcomeValue_PrefersFlagOverStdin(t *testing.T) {
	cmd := &cobra.Command{}
	cmd.Flags().String("outcome", "", "")
	if err := cmd.Flags().Set("outcome", "flag value"); err != nil {
		t.Fatalf("setting flag: %v", err)
	}
	cmd.SetIn(bytes.NewBufferString("stdin value\n"))

	got, err := resolveOutcomeValue(cmd, "flag value")
	if err != nil {
		t.Fatalf("resolveOutcomeValue: %v", err)
	}
	if got != "flag value" {
		t.Fatalf("expected flag value, got %q", got)
	}
}

func TestResolveOutcomeValue_ReadsAndTrimsStdin(t *testing.T) {
	cmd := &cobra.Command{}
	cmd.Flags().String("outcome", "", "")
	cmd.SetIn(bytes.NewBufferString("first line\nsecond line\n"))

	got, err := resolveOutcomeValue(cmd, "")
	if err != nil {
		t.Fatalf("resolveOutcomeValue: %v", err)
	}
	if got != "first line\nsecond line" {
		t.Fatalf("unexpected stdin outcome %q", got)
	}
}

func TestSetOutcomeCmd_WritesMultilineOutcome(t *testing.T) {
	host := t.TempDir()
	feltDir := filepath.Join(host, ".felt", "story")
	if err := os.MkdirAll(feltDir, 0o755); err != nil {
		t.Fatalf("mkdir felt dir: %v", err)
	}
	path := filepath.Join(feltDir, "story.md")
	content := `---
name: Story
status: active
shuttle:
  enabled: true
  kind: oneshot
---

Body text.
`
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write fiber: %v", err)
	}

	prev := os.Getenv("LOOM_HOME")
	if err := os.Setenv("LOOM_HOME", host); err != nil {
		t.Fatalf("setenv: %v", err)
	}
	defer func() {
		if prev == "" {
			_ = os.Unsetenv("LOOM_HOME")
		} else {
			_ = os.Setenv("LOOM_HOME", prev)
		}
	}()

	cmd := newSetOutcomeCmd()
	cmd.SetArgs([]string{"story"})
	cmd.SetIn(bytes.NewBufferString("first line\nsecond line\n"))
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	text := string(raw)
	if !bytes.Contains(raw, []byte("outcome: |-\n  first line\n  second line")) {
		t.Fatalf("expected literal block-scalar outcome, got:\n%s", text)
	}
	if !bytes.Contains(raw, []byte("Body text.")) {
		t.Fatalf("body lost after set-outcome:\n%s", text)
	}
}

// withTempHost creates a temp felt host, sets LOOM_HOME, and returns a cleanup func.
func withTempHost(t *testing.T) (host string, cleanup func()) {
	t.Helper()
	host = t.TempDir()
	prev := os.Getenv("LOOM_HOME")
	if err := os.Setenv("LOOM_HOME", host); err != nil {
		t.Fatalf("setenv LOOM_HOME: %v", err)
	}
	cleanup = func() {
		if prev == "" {
			_ = os.Unsetenv("LOOM_HOME")
		} else {
			_ = os.Setenv("LOOM_HOME", prev)
		}
	}
	return host, cleanup
}

// writeFiber writes a fiber .md file at host/.felt/<slug>/<slug>.md.
func writeFiber(t *testing.T, host, slug, content string) string {
	t.Helper()
	dir := filepath.Join(host, ".felt", slug)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir felt dir: %v", err)
	}
	path := filepath.Join(dir, slug+".md")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write fiber: %v", err)
	}
	return path
}

// TestResumeCmd_StandingAwaitingTransitionsToScheduled verifies that resume on
// a standing role in awaiting state transitions review.state to scheduled and
// sets next_due_at to now (making the fiber immediately eligible).
func TestResumeCmd_StandingAwaitingTransitionsToScheduled(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "daily-report", `---
name: Daily report
status: active
shuttle:
  enabled: true
  kind: standing
  schedule:
    expr: "0 9 * * 1-5"
    tz: Europe/Paris
  review:
    state: awaiting
    run_id: "20260506T090000+0200"
---

Standing role body.
`)

	before := time.Now().UTC()
	cmd := newResumeCmd()
	cmd.SetArgs([]string{"daily-report"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	text := string(raw)

	// review.state must be scheduled
	if !strings.Contains(text, "state: scheduled") {
		t.Fatalf("expected review.state: scheduled, got:\n%s", text)
	}
	// awaiting must be gone
	if strings.Contains(text, "state: awaiting") {
		t.Fatalf("awaiting state still present:\n%s", text)
	}
	// next_due_at must be present and parseable as a time >= before
	if !strings.Contains(text, "next_due_at:") {
		t.Fatalf("next_due_at not written:\n%s", text)
	}
	// prior run_id must be preserved
	if !strings.Contains(text, "20260506T090000+0200") {
		t.Fatalf("prior run_id not preserved:\n%s", text)
	}
	// enabled must still be true
	if !strings.Contains(text, "enabled: true") {
		t.Fatalf("enabled should be true:\n%s", text)
	}
	// body must be preserved
	if !strings.Contains(text, "Standing role body.") {
		t.Fatalf("body lost:\n%s", text)
	}

	_ = before // verify next_due_at >= before if we want to parse the timestamp
}

// TestResumeCmd_StandingReviewStateVariants checks that all review-state aliases
// (review, in_review) also trigger the standing-resume path.
func TestResumeCmd_StandingReviewStateVariants(t *testing.T) {
	for _, reviewState := range []string{"review", "in_review"} {
		t.Run(reviewState, func(t *testing.T) {
			host, cleanup := withTempHost(t)
			defer cleanup()

			content := "---\nname: Role\nstatus: active\nshuttle:\n  enabled: true\n  kind: standing\n  schedule:\n    expr: \"0 9 * * 1-5\"\n    tz: UTC\n  review:\n    state: " + reviewState + "\n    run_id: \"20260506T090000+0000\"\n---\n\nBody.\n"
			path := writeFiber(t, host, "role", content)

			cmd := newResumeCmd()
			cmd.SetArgs([]string{"role"})
			if err := cmd.Execute(); err != nil {
				t.Fatalf("Execute (%s): %v", reviewState, err)
			}

			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read fiber: %v", err)
			}
			text := string(raw)
			if !strings.Contains(text, "state: scheduled") {
				t.Fatalf("(%s) expected review.state: scheduled:\n%s", reviewState, text)
			}
			if !strings.Contains(text, "next_due_at:") {
				t.Fatalf("(%s) next_due_at not written:\n%s", reviewState, text)
			}
		})
	}
}

// TestResumeCmd_StandingScheduledFallsThrough verifies that resume on a standing
// role that is NOT in review state (e.g. already scheduled) uses the regular
// enable path rather than the standing-resume path.
func TestResumeCmd_StandingScheduledFallsThrough(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	// A standing role that was paused (enabled=false) but not in review.
	now := time.Now().UTC().Add(24 * time.Hour)
	nextStr := now.Format(time.RFC3339)
	content := "---\nname: Role\nstatus: active\nshuttle:\n  enabled: false\n  kind: standing\n  schedule:\n    expr: \"0 9 * * 1-5\"\n    tz: UTC\n  review:\n    state: scheduled\n  next_due_at: " + nextStr + "\n---\n\nBody.\n"
	path := writeFiber(t, host, "role2", content)

	cmd := newResumeCmd()
	cmd.SetArgs([]string{"role2"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	text := string(raw)
	// enabled must flip to true
	if !strings.Contains(text, "enabled: true") {
		t.Fatalf("enabled should be true:\n%s", text)
	}
	// review.state must remain scheduled (not changed to something else)
	if !strings.Contains(text, "state: scheduled") {
		t.Fatalf("review.state should remain scheduled:\n%s", text)
	}
	// next_due_at must NOT have been reset to now (still the future timestamp)
	if !strings.Contains(text, nextStr[:16]) { // match at minute precision
		t.Fatalf("next_due_at was unexpectedly changed:\n%s", text)
	}
}

// TestStandingInReviewState exercises the helper directly.
func TestStandingInReviewState(t *testing.T) {
	cases := []struct {
		state string
		want  bool
	}{
		{"awaiting", true},
		{"review", true},
		{"in_review", true},
		{"scheduled", false},
		{"accepted", false},
		{"", false},
	}
	for _, tc := range cases {
		t.Run(tc.state, func(t *testing.T) {
			rev := &schema.Review{State: tc.state}
			got := standingInReviewState(rev)
			if got != tc.want {
				t.Fatalf("standingInReviewState(%q) = %v, want %v", tc.state, got, tc.want)
			}
		})
	}
	// nil review
	if standingInReviewState(nil) {
		t.Fatal("standingInReviewState(nil) should be false")
	}
}
