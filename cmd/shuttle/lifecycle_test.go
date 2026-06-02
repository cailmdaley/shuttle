package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
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

// withTempHost creates a temp felt store, sets LOOM_HOME, and returns a cleanup func.
func withTempHost(t *testing.T) (host string, cleanup func()) {
	t.Helper()
	host = t.TempDir()
	prev := os.Getenv("LOOM_HOME")
	prevOffline, hadOffline := os.LookupEnv("SHUTTLE_LIFECYCLE_OFFLINE")
	if err := os.Setenv("LOOM_HOME", host); err != nil {
		t.Fatalf("setenv LOOM_HOME: %v", err)
	}
	if err := os.Setenv("SHUTTLE_LIFECYCLE_OFFLINE", "1"); err != nil {
		t.Fatalf("setenv SHUTTLE_LIFECYCLE_OFFLINE: %v", err)
	}
	cleanup = func() {
		if prev == "" {
			_ = os.Unsetenv("LOOM_HOME")
		} else {
			_ = os.Setenv("LOOM_HOME", prev)
		}
		if hadOffline {
			_ = os.Setenv("SHUTTLE_LIFECYCLE_OFFLINE", prevOffline)
		} else {
			_ = os.Unsetenv("SHUTTLE_LIFECYCLE_OFFLINE")
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

func TestInstallCmd_EnabledRequiresProjectDir(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "install-me", `---
name: Install me
status: open
---

Body.
`)

	cmd := newInstallCmd()
	cmd.SetArgs([]string{"install-me"})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected install without --project-dir to fail")
	}
	if !strings.Contains(err.Error(), "project_dir is required") {
		t.Fatalf("expected project_dir error, got %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	if strings.Contains(string(raw), "shuttle:") {
		t.Fatalf("install failure should not write shuttle block:\n%s", string(raw))
	}
}

func TestInstallCmd_WritesProjectDir(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	projectDir := t.TempDir()
	path := writeFiber(t, host, "install-with-project", `---
name: Install with project
status: open
---

Body.
`)

	cmd := newInstallCmd()
	cmd.SetArgs([]string{"install-with-project", "--project-dir", projectDir})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	text := string(raw)
	if !strings.Contains(text, "project_dir: "+projectDir) {
		t.Fatalf("project_dir not written:\n%s", text)
	}
	if !strings.Contains(text, "enabled: true") {
		t.Fatalf("enabled block not written:\n%s", text)
	}
}

func TestInstallCmd_WritesInteractive(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	projectDir := t.TempDir()
	path := writeFiber(t, host, "install-interactive", `---
name: Install interactive
status: open
---

Body.
`)

	cmd := newInstallCmd()
	cmd.SetArgs([]string{"install-interactive", "--project-dir", projectDir, "--interactive"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	if !strings.Contains(string(raw), "interactive: true") {
		t.Fatalf("interactive not written:\n%s", raw)
	}
}

func TestSetInteractiveCmd_WritesAndClearsField(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "toggle-interactive", `---
name: Toggle interactive
status: active
shuttle:
  enabled: true
  kind: oneshot
  project_dir: /tmp
---

Body.
`)

	if err := setInteractiveCmd.RunE(setInteractiveCmd, []string{"toggle-interactive", "true"}); err != nil {
		t.Fatalf("set true: %v", err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	if !strings.Contains(string(raw), "interactive: true") {
		t.Fatalf("interactive true not written:\n%s", raw)
	}

	if err := setInteractiveCmd.RunE(setInteractiveCmd, []string{"toggle-interactive", "false"}); err != nil {
		t.Fatalf("set false: %v", err)
	}
	raw, err = os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	if strings.Contains(string(raw), "interactive:") {
		t.Fatalf("interactive field not cleared:\n%s", raw)
	}
}

func TestInstallCmd_BumpsMissingStatusOnFreshInstall(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	projectDir := t.TempDir()
	path := writeFiber(t, host, "fresh-missing-status", `---
name: Fresh missing status
---

Body.
`)

	var stdout bytes.Buffer
	cmd := newInstallCmd()
	cmd.SetOut(&stdout)
	cmd.SetErr(&stdout)
	cmd.SetArgs([]string{"fresh-missing-status", "--project-dir", projectDir})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v, output:\n%s", err, stdout.String())
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	text := string(raw)
	if !strings.Contains(text, "status: active") {
		t.Fatalf("missing status should be bumped to active:\n%s", text)
	}
	if !strings.Contains(stdout.String(), "status: active (set; was missing)") {
		t.Fatalf("expected status bump in output, got:\n%s", stdout.String())
	}
}

func TestInstallCmd_DisabledFlagPositionIsIndependent(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	cases := []struct {
		name string
		args []string
	}{
		{"before-slug", []string{"--disabled", "position-before", "--model", "codex"}},
		{"between-slug-and-model", []string{"position-between", "--disabled", "--model", "codex"}},
		{"after-model", []string{"position-after", "--model", "codex", "--disabled"}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			slug := ""
			for _, arg := range tc.args {
				if !strings.HasPrefix(arg, "-") && arg != "codex" {
					slug = arg
					break
				}
			}
			path := writeFiber(t, host, slug, `---
name: Position test
status: open
---

Body.
`)

			cmd := newInstallCmd()
			cmd.SetArgs(tc.args)
			if err := cmd.Execute(); err != nil {
				t.Fatalf("Execute: %v", err)
			}

			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read fiber: %v", err)
			}
			text := string(raw)
			if !strings.Contains(text, "enabled: false") {
				t.Fatalf("--disabled should write to requested slug %q:\n%s", slug, text)
			}
			if !strings.Contains(text, "agent: codex") {
				t.Fatalf("--model should be honored for requested slug %q:\n%s", slug, text)
			}
		})
	}
}

func TestInstallCmd_ClosedStatusPointsAtReopen(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	projectDir := t.TempDir()
	path := writeFiber(t, host, "closed-install", `---
name: Closed install
status: closed
---

Body.
`)

	cmd := newInstallCmd()
	cmd.SetArgs([]string{"closed-install", "--project-dir", projectDir})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected closed fiber install to fail")
	}
	if !strings.Contains(err.Error(), "shuttle reopen closed-install") {
		t.Fatalf("expected reopen guidance, got %v", err)
	}

	raw, readErr := os.ReadFile(path)
	if readErr != nil {
		t.Fatalf("read fiber: %v", readErr)
	}
	if strings.Contains(string(raw), "shuttle:") {
		t.Fatalf("closed install failure should not write shuttle block:\n%s", string(raw))
	}
}

// TestInstallCmd_IdempotentWhenBlockExistsNoFlags covers the common authoring
// case: the user wrote a shuttle: block by hand in the constitution markdown,
// then runs `shuttle-ctl install <fiber>` to confirm the daemon will dispatch.
// Pre-fix this errored ("already has a shuttle: block"); now it prints state
// and exits 0.
func TestInstallCmd_IdempotentWhenBlockExistsNoFlags(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "already-installed", `---
name: Already installed
status: open
shuttle:
  enabled: true
  kind: oneshot
  agent: codex
  project_dir: /tmp
---

Body.
`)
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}

	var stdout bytes.Buffer
	cmd := newInstallCmd()
	cmd.SetOut(&stdout)
	cmd.SetErr(&stdout)
	cmd.SetArgs([]string{"already-installed"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v (no flags should be idempotent), output:\n%s", err, stdout.String())
	}

	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	if !bytes.Equal(before, after) {
		t.Fatalf("idempotent install must not rewrite the file. before:\n%s\nafter:\n%s", before, after)
	}

	out := stdout.String()
	for _, want := range []string{"already has a shuttle: block", "agent:       codex", "Daemon will dispatch on next poll"} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected %q in output, got:\n%s", want, out)
		}
	}
}

// TestInstallCmd_IdempotentWhenFlagsMatch covers `install --model codex`
// against a block that already has agent: codex — same intent, no conflict,
// exit 0.
func TestInstallCmd_IdempotentWhenFlagsMatch(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	writeFiber(t, host, "flags-match", `---
name: Flags match
status: open
shuttle:
  enabled: true
  kind: oneshot
  agent: codex
  project_dir: /tmp
---

Body.
`)

	var stdout bytes.Buffer
	cmd := newInstallCmd()
	cmd.SetOut(&stdout)
	cmd.SetErr(&stdout)
	cmd.SetArgs([]string{"flags-match", "--model", "codex"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v (matching --model should be idempotent), output:\n%s", err, stdout.String())
	}
}

// TestInstallCmd_ErrorsOnModelConflict covers --model differing from the
// existing block's agent. Exit non-zero; the message points at set-model.
func TestInstallCmd_ErrorsOnModelConflict(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	writeFiber(t, host, "model-conflict", `---
name: Model conflict
status: open
shuttle:
  enabled: true
  kind: oneshot
  agent: codex
  project_dir: /tmp
---

Body.
`)

	var stdout, stderr bytes.Buffer
	cmd := newInstallCmd()
	cmd.SetOut(&stdout)
	cmd.SetErr(&stderr)
	cmd.SetArgs([]string{"model-conflict", "--model", "claude-opus"})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected non-nil error on model conflict")
	}

	combined := stdout.String() + stderr.String()
	for _, want := range []string{
		"--model claude-opus",
		"current agent",
		"shuttle-ctl set-model",
	} {
		if !strings.Contains(combined, want) {
			t.Fatalf("expected %q in output, got:\n%s", want, combined)
		}
	}
}

// TestInstallCmd_BumpsMissingStatusEvenWhenBlockExists covers the "user
// wrote block: enabled: true but forgot status: active" case. Without this
// fix, install would error and leave the fiber undispatchable until the
// user discovered the missing status separately. Now install bumps it.
func TestInstallCmd_BumpsMissingStatusEvenWhenBlockExists(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "missing-status", `---
name: Missing status
shuttle:
  enabled: true
  kind: oneshot
  agent: codex
  project_dir: /tmp
---

Body.
`)

	var stdout bytes.Buffer
	cmd := newInstallCmd()
	cmd.SetOut(&stdout)
	cmd.SetErr(&stdout)
	cmd.SetArgs([]string{"missing-status"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v, output:\n%s", err, stdout.String())
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	if !strings.Contains(string(raw), "status: active") {
		t.Fatalf("expected status: active to be written; got:\n%s", string(raw))
	}
	if !strings.Contains(stdout.String(), "bumped to") {
		t.Fatalf("expected user-visible note about status bump; got:\n%s", stdout.String())
	}
}

func withStubbedTmux(t *testing.T, sessions map[string]bool) (killed *[]string) {
	t.Helper()
	originalExists := tmuxSessionExists
	originalKill := killTmuxSession
	kills := []string{}
	tmuxSessionExists = func(session string) bool {
		return sessions[session]
	}
	killTmuxSession = func(session string) error {
		kills = append(kills, session)
		sessions[session] = false
		return nil
	}
	t.Cleanup(func() {
		tmuxSessionExists = originalExists
		killTmuxSession = originalKill
	})
	return &kills
}

func TestPauseCmd_KillsRunningWorkerByDefault(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "pause-me", `---
name: Pause me
status: active
shuttle:
  enabled: true
  kind: oneshot
---

Body.
`)
	session := schema.TmuxSessionName("pause-me")
	killed := withStubbedTmux(t, map[string]bool{session: true})

	cmd := newPauseCmd()
	cmd.SetArgs([]string{"pause-me"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	text := string(raw)
	if !strings.Contains(text, "enabled: false") {
		t.Fatalf("enabled should be false after pause:\n%s", text)
	}
	if got := strings.Join(*killed, ","); got != session {
		t.Fatalf("expected killed session %q, got %q", session, got)
	}
}

func TestPauseCmd_NoRunningWorkerDoesNotError(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "idle", `---
name: Idle
status: active
shuttle:
  enabled: true
  kind: oneshot
---

Body.
`)
	killed := withStubbedTmux(t, map[string]bool{})

	cmd := newPauseCmd()
	cmd.SetArgs([]string{"idle"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	text := string(raw)
	if !strings.Contains(text, "enabled: false") {
		t.Fatalf("enabled should be false after pause:\n%s", text)
	}
	if len(*killed) != 0 {
		t.Fatalf("expected no kill calls, got %v", *killed)
	}
}

func TestPauseCmd_NoKillPreservesRunningWorker(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "let-finish", `---
name: Let finish
status: active
shuttle:
  enabled: true
  kind: oneshot
---

Body.
`)
	session := schema.TmuxSessionName("let-finish")
	sessions := map[string]bool{session: true}
	killed := withStubbedTmux(t, sessions)

	cmd := newPauseCmd()
	cmd.SetArgs([]string{"let-finish", "--no-kill"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	text := string(raw)
	if !strings.Contains(text, "enabled: false") {
		t.Fatalf("enabled should be false after pause:\n%s", text)
	}
	if len(*killed) != 0 {
		t.Fatalf("expected no kill calls, got %v", *killed)
	}
	if !sessions[session] {
		t.Fatalf("expected session %q to remain running", session)
	}
}

func TestResumeCmd_ClosedStatusPointsAtReopen(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	writeFiber(t, host, "closed-resume", `---
name: Closed resume
status: closed
shuttle:
  enabled: false
  kind: oneshot
---

Body.
`)

	cmd := newResumeCmd()
	cmd.SetArgs([]string{"closed-resume"})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected closed fiber resume to fail")
	}
	if !strings.Contains(err.Error(), "shuttle reopen closed-resume") {
		t.Fatalf("expected reopen guidance, got %v", err)
	}
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

// TestAcceptCmd_ClearsOutcomeByDefault verifies that accepting a standing-role
// awaiting-review run clears the outcome field. The next worker dispatched on
// this fiber will see an empty outcome and write a fresh digest.
func TestAcceptCmd_ClearsOutcomeByDefault(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "daily-report", `---
name: Daily report
status: active
outcome: |-
  2026-05-07 11:55 CEST | 8 reviewed | 16 archived | 1 fiber

  ### Action needed
  - Register on framadate
shuttle:
  enabled: true
  kind: standing
  schedule:
    expr: "0 9 * * 1-5"
    tz: Europe/Paris
  review:
    state: awaiting
    run_id: "20260508T070000+0000"
---

Standing role body.
`)

	cmd := newAcceptCmd()
	cmd.SetArgs([]string{"daily-report"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	text := string(raw)

	// The accept-state ratchet must have advanced.
	if !strings.Contains(text, "state: scheduled") {
		t.Fatalf("expected review.state: scheduled:\n%s", text)
	}
	if !strings.Contains(text, "accepted_run_id: 20260508T070000+0000") {
		t.Fatalf("accepted_run_id not set:\n%s", text)
	}

	// Outcome must be empty (either an empty value or absent).
	if strings.Contains(text, "Register on framadate") {
		t.Fatalf("outcome content survived accept:\n%s", text)
	}
	if strings.Contains(text, "16 archived") {
		t.Fatalf("outcome digest survived accept:\n%s", text)
	}

	// Body must be preserved.
	if !strings.Contains(text, "Standing role body.") {
		t.Fatalf("body lost after accept:\n%s", text)
	}
}

func TestAcceptCmd_AdHocRunPreservesNextDueAt(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "daily-report", `---
name: Daily report
status: active
outcome: ad-hoc digest
shuttle:
  enabled: true
  kind: standing
  schedule:
    expr: "0 9 * * 1-5"
    tz: Europe/Paris
  review:
    state: awaiting
    run_id: adhoc-1770000000000
  next_due_at: "2026-05-11T09:00:00+02:00"
---

Standing role body.
`)

	cmd := newAcceptCmd()
	cmd.SetArgs([]string{"daily-report"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	text := string(raw)

	if !strings.Contains(text, "accepted_run_id: adhoc-1770000000000") {
		t.Fatalf("accepted_run_id not set for ad-hoc run:\n%s", text)
	}
	if !strings.Contains(text, "next_due_at: 2026-05-11T09:00:00+02:00") {
		t.Fatalf("ad-hoc accept should preserve next_due_at:\n%s", text)
	}
	if strings.Contains(text, "ad-hoc digest") {
		t.Fatalf("outcome digest survived accept:\n%s", text)
	}
}

func TestAcceptCmd_ReactivatesClosedStandingRole(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "daily-report", `---
name: Daily report
status: closed
tempered: true
closed-at: 2026-05-08T10:00:00Z
outcome: stale digest
shuttle:
  enabled: true
  kind: standing
  schedule:
    expr: "0 9 * * 1-5"
    tz: Europe/Paris
  review:
    state: awaiting
    run_id: "20260508T070000+0000"
---

Standing role body.
`)

	cmd := newAcceptCmd()
	cmd.SetArgs([]string{"daily-report"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	text := string(raw)

	if !strings.Contains(text, "status: active") {
		t.Fatalf("accept should reactivate standing roles:\n%s", text)
	}
	if strings.Contains(text, "tempered:") {
		t.Fatalf("accept should clear tempered marker:\n%s", text)
	}
	if strings.Contains(text, "closed-at:") {
		t.Fatalf("accept should clear closed-at marker:\n%s", text)
	}
	if !strings.Contains(text, "state: scheduled") {
		t.Fatalf("expected review.state: scheduled:\n%s", text)
	}
}

// TestAcceptCmd_ClearsSessionUUID verifies that accept clears the session
// block, so any subsequent dispatch (next cron tick, manual ad-hoc, kanban
// drag) starts a fresh worker rather than resuming the just-accepted run's
// transcript. Resuming would land the worker in a transcript whose last
// turn was "Run accepted. Exiting" — they'd idle ("nothing new on the
// fiber") instead of running fresh. After accept, the cycle has rolled over.
func TestAcceptCmd_ClearsSessionUUID(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "daily-report", `---
name: Daily report
status: active
outcome: digest
shuttle:
  enabled: true
  kind: standing
  schedule:
    expr: "0 9 * * 1-5"
    tz: Europe/Paris
  review:
    state: awaiting
    run_id: "20260508T070000+0000"
  session:
    id: 11111111-2222-3333-4444-555555555555
    agent: claude-opus
    dispatched_at: 2026-05-08T07:00:00Z
---

Standing role body.
`)

	cmd := newAcceptCmd()
	cmd.SetArgs([]string{"daily-report"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	text := string(raw)

	// State must have advanced.
	if !strings.Contains(text, "state: scheduled") {
		t.Fatalf("expected review.state: scheduled:\n%s", text)
	}
	// The session uuid must not survive — it's the trigger for stale-resume.
	if strings.Contains(text, "11111111-2222-3333-4444-555555555555") {
		t.Fatalf("session UUID survived accept; next dispatch may resume stale transcript:\n%s", text)
	}
	if strings.Contains(text, "session:") {
		t.Fatalf("session block survived accept:\n%s", text)
	}
}

// TestAcceptCmd_KeepOutcomeFlag_PreservesOutcome verifies that --keep-outcome
// preserves the outcome field across accept (escape hatch for the rare case
// where the digest should survive into the next dispatch).
func TestAcceptCmd_KeepOutcomeFlag_PreservesOutcome(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "daily-report", `---
name: Daily report
status: active
outcome: |-
  2026-05-07 11:55 CEST | 8 reviewed
  Worth keeping across the boundary.
shuttle:
  enabled: true
  kind: standing
  schedule:
    expr: "0 9 * * 1-5"
    tz: Europe/Paris
  review:
    state: awaiting
    run_id: "20260508T070000+0000"
---

Body.
`)

	cmd := newAcceptCmd()
	cmd.SetArgs([]string{"daily-report", "--keep-outcome"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	text := string(raw)

	// Accept-state ratchet still advances.
	if !strings.Contains(text, "state: scheduled") {
		t.Fatalf("expected review.state: scheduled:\n%s", text)
	}
	// Outcome content survives.
	if !strings.Contains(text, "Worth keeping across the boundary.") {
		t.Fatalf("--keep-outcome did not preserve outcome:\n%s", text)
	}
}

func TestAcceptCmd_UsesDaemonLifecycleWhenAvailable(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "daily-report", `---
name: Daily report
status: active
outcome: digest
shuttle:
  enabled: true
  kind: standing
  schedule:
    expr: "0 9 * * 1-5"
    tz: Europe/Paris
  review:
    state: awaiting
    run_id: "20260508T070000+0000"
  session:
    id: stale-session
---

Body.
`)
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}

	var requestPath string
	var payload map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestPath = r.URL.Path
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatalf("decode payload: %v", err)
		}
		_, _ = w.Write([]byte("accepted run 20260508T070000+0000 for daily-report\n"))
	}))
	defer srv.Close()
	enableDaemonLifecycle(t, srv.URL)

	cmd := newAcceptCmd()
	cmd.SetArgs([]string{"daily-report", "--keep-outcome"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	if !bytes.Equal(before, after) {
		t.Fatalf("daemon path should not rewrite frontmatter. before:\n%s\nafter:\n%s", before, after)
	}
	if requestPath != "/api/v1/lifecycle" {
		t.Fatalf("unexpected request path %q", requestPath)
	}
	if payload["action"] != "accept" || payload["fiber"] != "daily-report" || payload["keep_outcome"] != true {
		t.Fatalf("unexpected lifecycle payload: %#v", payload)
	}
}

func TestResumeCmd_StandingReviewUsesDaemonLifecycleWhenAvailable(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "daily-report", `---
name: Daily report
status: active
outcome: digest
shuttle:
  enabled: true
  kind: standing
  schedule:
    expr: "0 9 * * 1-5"
    tz: Europe/Paris
  review:
    state: awaiting
    run_id: "20260508T070000+0000"
  next_due_at: null
---

Body.
`)
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}

	var payload map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/lifecycle" {
			t.Fatalf("unexpected request path %q", r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatalf("decode payload: %v", err)
		}
		_, _ = w.Write([]byte("resumed daily-report (standing role; re-queued for immediate dispatch)\n"))
	}))
	defer srv.Close()
	enableDaemonLifecycle(t, srv.URL)

	cmd := newResumeCmd()
	cmd.SetArgs([]string{"daily-report"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	if !bytes.Equal(before, after) {
		t.Fatalf("daemon path should not rewrite frontmatter. before:\n%s\nafter:\n%s", before, after)
	}
	if payload["action"] != "resume" || payload["fiber"] != "daily-report" {
		t.Fatalf("unexpected lifecycle payload: %#v", payload)
	}
}

func enableDaemonLifecycle(t *testing.T, url string) {
	t.Helper()
	prevOffline, hadOffline := os.LookupEnv("SHUTTLE_LIFECYCLE_OFFLINE")
	prevURL, hadURL := os.LookupEnv("SHUTTLE_DAEMON_URL")

	_ = os.Unsetenv("SHUTTLE_LIFECYCLE_OFFLINE")
	_ = os.Setenv("SHUTTLE_DAEMON_URL", url)

	t.Cleanup(func() {
		if hadOffline {
			_ = os.Setenv("SHUTTLE_LIFECYCLE_OFFLINE", prevOffline)
		} else {
			_ = os.Unsetenv("SHUTTLE_LIFECYCLE_OFFLINE")
		}
		if hadURL {
			_ = os.Setenv("SHUTTLE_DAEMON_URL", prevURL)
		} else {
			_ = os.Unsetenv("SHUTTLE_DAEMON_URL")
		}
	})
}
