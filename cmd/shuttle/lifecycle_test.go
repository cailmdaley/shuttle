package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

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
	if !strings.Contains(text, "status: active") {
		t.Fatalf("armed install should set status: active:\n%s", text)
	}
	if strings.Contains(text, "enabled") {
		t.Fatalf("slice 5: install must not write an enabled flag:\n%s", text)
	}
}

// Interactivity is retired as a dispatch mode. The --interactive flag no longer
// exists, so install rejects it as an unknown flag rather than writing a field.
func TestInstallCmd_RejectsRetiredInteractiveFlag(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	projectDir := t.TempDir()
	writeFiber(t, host, "install-interactive", `---
name: Install interactive
status: open
---

Body.
`)

	cmd := newInstallCmd()
	cmd.SetArgs([]string{"install-interactive", "--project-dir", projectDir, "--interactive"})
	cmd.SetErr(io.Discard)
	err := cmd.Execute()
	if err == nil {
		t.Fatalf("expected --interactive to be rejected as an unknown flag")
	}
	if !strings.Contains(err.Error(), "interactive") {
		t.Fatalf("expected unknown-flag error to name interactive, got: %v", err)
	}
}

// set-interactive is retired: it stays registered (hidden) so muscle-memory
// invocations land on a clear pointer at the directive/resume channels rather
// than mutating a fiber.
func TestSetInteractiveCmd_Retired(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "toggle-interactive", `---
name: Toggle interactive
status: active
shuttle:
  kind: oneshot
  project_dir: /tmp
---

Body.
`)
	before, _ := os.ReadFile(path)

	err := setInteractiveCmd.RunE(setInteractiveCmd, []string{"toggle-interactive", "true"})
	if err == nil {
		t.Fatalf("expected set-interactive to return a retirement error")
	}
	if !strings.Contains(err.Error(), "retired") || !strings.Contains(err.Error(), "directive") {
		t.Fatalf("expected retirement error pointing at the directive channel, got: %v", err)
	}

	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Fatalf("set-interactive must not mutate the fiber; got:\n%s", after)
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
			if !strings.Contains(text, "status: open") {
				t.Fatalf("--disabled should land in drafts (status: open) for slug %q:\n%s", slug, text)
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

	// An armed fiber (status: active) with a hand-written block. Idempotent
	// install reports it as armed and never rewrites the file.
	path := writeFiber(t, host, "already-installed", `---
name: Already installed
status: active
shuttle:
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

// TestInstallCmd_ReportsMissingStatusOnExistingBlock covers a hand-written
// block with no status field. Slice 5: status is the dispatch gate, so a
// missing status means undispatchable — idempotent install reports that and
// points at resume, and does not auto-arm or rewrite the file (the user
// decides draft vs armed).
func TestInstallCmd_ReportsMissingStatusOnExistingBlock(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "missing-status", `---
name: Missing status
shuttle:
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
	cmd.SetArgs([]string{"missing-status"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v, output:\n%s", err, stdout.String())
	}

	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	if !bytes.Equal(before, after) {
		t.Fatalf("idempotent install must not auto-arm; before:\n%s\nafter:\n%s", before, after)
	}
	if !strings.Contains(stdout.String(), "Status missing") {
		t.Fatalf("expected a missing-status note; got:\n%s", stdout.String())
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
	// These temp-store fibers carry no felt uid, so the command resolves an
	// empty uid and pause targets the legacy leaf-only session name.
	session := schema.TmuxSessionName("pause-me", "")
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
	if !strings.Contains(text, "status: open") {
		t.Fatalf("pause should set status: open:\n%s", text)
	}
	if got := strings.Join(*killed, ","); got != session {
		t.Fatalf("expected killed session %q, got %q", session, got)
	}
}

func TestPauseCmd_KillsUIDKeyedSession(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	uid := "01KTHDNZS287ZSSG8X8V59XKWB"
	writeFiber(t, host, "pause-uid", `---
name: Pause uid
status: active
uid: `+uid+`
shuttle:
  enabled: true
  kind: oneshot
---

Body.
`)
	// felt surfaces the frontmatter uid, so pause computes the uid-keyed
	// session name and kills exactly that.
	session := schema.TmuxSessionName("pause-uid", uid)
	killed := withStubbedTmux(t, map[string]bool{session: true})

	cmd := newPauseCmd()
	cmd.SetArgs([]string{"pause-uid"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if got := strings.Join(*killed, ","); got != session {
		t.Fatalf("expected killed uid-keyed session %q, got %q", session, got)
	}
}

func TestPauseCmd_KillsLegacyNamedWorkerForUIDFiber(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	uid := "01KTHDNZS287ZSSG8X8V59XKWB"
	writeFiber(t, host, "pause-legacy", `---
name: Pause legacy
status: active
uid: `+uid+`
shuttle:
  enabled: true
  kind: oneshot
---

Body.
`)
	// A worker launched before the uid-keyed cutover is live under the legacy
	// leaf-only name; dual-recognition still finds and kills it.
	legacy := schema.TmuxSessionName("pause-legacy", "")
	killed := withStubbedTmux(t, map[string]bool{legacy: true})

	cmd := newPauseCmd()
	cmd.SetArgs([]string{"pause-legacy"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if got := strings.Join(*killed, ","); got != legacy {
		t.Fatalf("expected killed legacy session %q, got %q", legacy, got)
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
	if !strings.Contains(text, "status: open") {
		t.Fatalf("pause should set status: open:\n%s", text)
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
	session := schema.TmuxSessionName("let-finish", "")
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
	if !strings.Contains(text, "status: open") {
		t.Fatalf("pause should set status: open:\n%s", text)
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

// TestResumeCmd_StandingAwaitingReArms verifies that resume on a standing role
// awaiting review (status:closed + untempered) re-arms it to status:active and
// clears the awaiting markers (slice 5: no review.state, no next_due_at).
func TestResumeCmd_StandingAwaitingReArms(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "daily-report", `---
name: Daily report
status: closed
closed-at: 2026-06-01T09:30:00Z
shuttle:
  kind: standing
  schedule:
    expr: "0 9 * * 1-5"
    tz: Europe/Paris
---

Standing role body.
`)

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

	if !strings.Contains(text, "status: active") {
		t.Fatalf("resume should re-arm to status: active:\n%s", text)
	}
	if strings.Contains(text, "closed-at:") {
		t.Fatalf("resume should clear closed-at:\n%s", text)
	}
	// Clean cutover: no review block, no enabled flag, no next_due_at.
	if strings.Contains(text, "review") || strings.Contains(text, "enabled") ||
		strings.Contains(text, "next_due_at") {
		t.Fatalf("resume must not write review/enabled/next_due_at:\n%s", text)
	}
	if !strings.Contains(text, "Standing role body.") {
		t.Fatalf("body lost:\n%s", text)
	}
}

// TestResumeCmd_DraftArmsToActive verifies that resume on a draft (status: open)
// arms it straight to status: active.
func TestResumeCmd_DraftArmsToActive(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "role2", `---
name: Role
status: open
shuttle:
  kind: standing
  schedule:
    expr: "0 9 * * 1-5"
    tz: UTC
---

Body.
`)

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
	if !strings.Contains(text, "status: active") {
		t.Fatalf("resume should arm a draft to status: active:\n%s", text)
	}
	if strings.Contains(text, "enabled") {
		t.Fatalf("resume must not write an enabled flag:\n%s", text)
	}
}

// lastReviewCommentResumeMode reads the resume_mode of the most recent
// review-comment event in a fiber's felt history. Returns "" when no
// review-comment is on file (felt errors or empty result).
func lastReviewCommentResumeMode(t *testing.T, host, fiberID string) string {
	t.Helper()
	out, err := exec.Command("felt", "-C", host, "history", fiberID,
		"--kind", "review-comment", "--last", "1", "--json").Output()
	if err != nil {
		t.Fatalf("felt history read: %v", err)
	}
	var events []struct {
		Payload struct {
			ResumeMode string `json:"resume_mode"`
		} `json:"payload"`
	}
	if err := json.Unmarshal(out, &events); err != nil {
		t.Fatalf("decode review-comment json: %v\n%s", err, out)
	}
	if len(events) == 0 {
		return ""
	}
	return events[0].Payload.ResumeMode
}

// TestResumeCmd_NeverRunFilesFreshResumeMode verifies the arm path does not
// manufacture a permanent block: arming a fiber with no prior session in felt
// history files `resume_mode: fresh`, so the dispatcher starts fresh rather than
// returning {:error, :missing_session_id} on every poll.
func TestResumeCmd_NeverRunFilesFreshResumeMode(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	writeFiber(t, host, "never-run-resume", `---
name: Never run resume
status: open
shuttle:
  kind: oneshot
  agent: claude-sonnet
---

Body.
`)

	cmd := newResumeCmd()
	cmd.SetArgs([]string{"never-run-resume"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	if got := lastReviewCommentResumeMode(t, host, "never-run-resume"); got != "fresh" {
		t.Fatalf("never-run resume should file resume_mode: fresh, got %q", got)
	}
}

// TestResumeCmd_PriorSessionFilesPreviousResumeMode verifies the arm path still
// requests transcript continuation when there is one: a dispatch event with a
// session id on file makes resume file `resume_mode: previous`.
func TestResumeCmd_PriorSessionFilesPreviousResumeMode(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	writeFiber(t, host, "ran-before-resume", `---
name: Ran before resume
status: open
shuttle:
  kind: oneshot
  agent: claude-sonnet
---

Body.
`)
	if err := appendFeltHistory(host, "ran-before-resume",
		"worker dispatched (agent=claude-sonnet) session=1111-2222-3333-4444"); err != nil {
		t.Fatalf("seed dispatch event: %v", err)
	}

	cmd := newResumeCmd()
	cmd.SetArgs([]string{"ran-before-resume"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	if got := lastReviewCommentResumeMode(t, host, "ran-before-resume"); got != "previous" {
		t.Fatalf("resume with a prior session should file resume_mode: previous, got %q", got)
	}
}

// TestAcceptCmd_ClearsOutcomeByDefault verifies that accepting a standing-role
// awaiting-review run clears the outcome field. The next worker dispatched on
// this fiber will see an empty outcome and write a fresh digest.
func TestAcceptCmd_ClearsOutcomeByDefault(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	// Awaiting is felt-native (slice 5): status:closed + untempered.
	path := writeFiber(t, host, "daily-report", `---
name: Daily report
status: closed
closed-at: 2026-05-08T10:00:00Z
outcome: |-
  2026-05-07 11:55 CEST | 8 reviewed | 16 archived | 1 fiber

  ### Action needed
  - Register on framadate
shuttle:
  kind: standing
  schedule:
    expr: "0 9 * * 1-5"
    tz: Europe/Paris
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

	// The role re-arms: status:active, no review block (slice 5).
	if !strings.Contains(text, "status: active") {
		t.Fatalf("accept should re-arm to status: active:\n%s", text)
	}
	if strings.Contains(text, "review") {
		t.Fatalf("accept must not write a review block:\n%s", text)
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

func TestAcceptCmd_RefusesNonAwaitingRole(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	// A tempered (status:closed + tempered:true) role is a terminus, not
	// awaiting — accept must refuse it (only status:closed + untempered re-arms).
	writeFiber(t, host, "daily-report", `---
name: Daily report
status: closed
tempered: true
closed-at: 2026-05-08T10:00:00Z
shuttle:
  kind: standing
  schedule:
    expr: "0 9 * * 1-5"
    tz: Europe/Paris
---

Standing role body.
`)

	cmd := newAcceptCmd()
	cmd.SetArgs([]string{"daily-report"})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected accept on a tempered role to fail")
	}
	if !strings.Contains(err.Error(), "not awaiting review") {
		t.Fatalf("expected 'not awaiting review' error, got %v", err)
	}
}

// TestAcceptCmd_DocAwaitingReArmsFromSchedule verifies the new-model awaiting
// shape: a standing role at `status: closed` + untempered with NO review block
// is recognized as awaiting and re-armed straight from the doc schedule
// (felt-native), without resurrecting a review block. This is the offline
// fallback path; the daemon's LifecycleStore.accept handles the same shape
// over HTTP.
func TestAcceptCmd_DocAwaitingReArmsFromSchedule(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "daily-report", `---
name: Daily report
status: closed
closed-at: 2026-05-08T10:00:00Z
outcome: stale digest
shuttle:
  kind: standing
  schedule:
    expr: "0 9 * * 1-5"
    tz: Europe/Paris
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
		t.Fatalf("accept should re-arm a doc-awaiting standing role:\n%s", text)
	}
	if strings.Contains(text, "tempered:") {
		t.Fatalf("re-armed role must carry no verdict:\n%s", text)
	}
	if strings.Contains(text, "closed-at:") {
		t.Fatalf("accept should clear closed-at:\n%s", text)
	}
	// Felt-native re-arm: no review block resurrected.
	if strings.Contains(text, "review:") || strings.Contains(text, "state: scheduled") {
		t.Fatalf("doc-awaiting accept must not write a review block:\n%s", text)
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
status: closed
closed-at: 2026-05-08T07:30:00Z
outcome: digest
shuttle:
  kind: standing
  schedule:
    expr: "0 9 * * 1-5"
    tz: Europe/Paris
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

	// The role re-arms (status: active).
	if !strings.Contains(text, "status: active") {
		t.Fatalf("accept should re-arm to status: active:\n%s", text)
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
status: closed
closed-at: 2026-05-08T07:30:00Z
outcome: |-
  2026-05-07 11:55 CEST | 8 reviewed
  Worth keeping across the boundary.
shuttle:
  kind: standing
  schedule:
    expr: "0 9 * * 1-5"
    tz: Europe/Paris
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

	// The role re-arms (status: active).
	if !strings.Contains(text, "status: active") {
		t.Fatalf("accept should re-arm to status: active:\n%s", text)
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
status: closed
closed-at: 2026-05-08T07:30:00Z
outcome: digest
shuttle:
  kind: standing
  schedule:
    expr: "0 9 * * 1-5"
    tz: Europe/Paris
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
		_, _ = w.Write([]byte("accepted run for daily-report\n"))
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

func TestAcceptCmd_DaemonLifecycleErrorDoesNotFallbackToFrontmatter(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "daily-report", `---
name: Daily report
status: closed
closed-at: 2026-05-08T07:30:00Z
outcome: digest
shuttle:
  kind: standing
  schedule:
    expr: "0 9 * * 1-5"
    tz: Europe/Paris
---

Body.
`)
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "runtime store rejected transition", http.StatusUnprocessableEntity)
	}))
	defer srv.Close()
	enableDaemonLifecycle(t, srv.URL)

	cmd := newAcceptCmd()
	cmd.SetArgs([]string{"daily-report"})
	err = cmd.Execute()
	if err == nil {
		t.Fatal("expected daemon lifecycle error")
	}
	if !strings.Contains(err.Error(), "runtime store rejected transition") {
		t.Fatalf("unexpected error: %v", err)
	}

	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	if !bytes.Equal(before, after) {
		t.Fatalf("daemon error should not fall back to frontmatter rewrite. before:\n%s\nafter:\n%s", before, after)
	}
}

func TestResumeCmd_StandingReviewUsesDaemonLifecycleWhenAvailable(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "daily-report", `---
name: Daily report
status: closed
closed-at: 2026-05-08T07:30:00Z
outcome: digest
shuttle:
  kind: standing
  schedule:
    expr: "0 9 * * 1-5"
    tz: Europe/Paris
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

func TestCloseCmd_StandingWritesNoReviewBlock(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	// Close composts a standing role: status:closed + tempered:false. There is
	// no review axis (slice 5) — close writes status + tempered + closed-at and
	// never invents a review block.
	path := writeFiber(t, host, "newsletter", `---
name: Newsletter
status: active
shuttle:
  kind: standing
  schedule:
    expr: "0 9 * * 1-5"
    tz: UTC
---

Body.
`)

	closeTempered = "false"
	defer func() { closeTempered = "" }()
	if err := closeCmd.RunE(closeCmd, []string{"newsletter"}); err != nil {
		t.Fatalf("RunE: %v", err)
	}

	text := readFiberText(t, path)
	if !strings.Contains(text, "status: closed") {
		t.Fatalf("expected status: closed:\n%s", text)
	}
	if !strings.Contains(text, "tempered: false") {
		t.Fatalf("expected tempered: false (composted):\n%s", text)
	}
	if strings.Contains(text, "review") {
		t.Fatalf("close must not write a review block (slice 5):\n%s", text)
	}
}

func TestReopenCmd_StandingClearsVerdictNoReviewBlock(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	// Reopen is the un-temper path's first step: a composted standing role
	// (status:closed + tempered:false) re-enters active work with the verdict
	// cleared. No review axis to reset (slice 5).
	path := writeFiber(t, host, "cc-bills", `---
name: CC bills
status: closed
tempered: false
closed-at: 2026-06-01T09:30:00Z
shuttle:
  kind: standing
  schedule:
    expr: "0 9 1 * *"
    tz: UTC
---

Body.
`)

	if err := reopenCmd.RunE(reopenCmd, []string{"cc-bills"}); err != nil {
		t.Fatalf("RunE: %v", err)
	}

	text := readFiberText(t, path)
	if !strings.Contains(text, "status: active") {
		t.Fatalf("expected status: active after reopen:\n%s", text)
	}
	if strings.Contains(text, "tempered") {
		t.Fatalf("reopen should clear the verdict:\n%s", text)
	}
	if strings.Contains(text, "review") {
		t.Fatalf("reopen must not write a review block (slice 5):\n%s", text)
	}
}

func TestCloseCmd_OneshotWritesNoReviewBlock(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	// A oneshot close (accept terminus): status:closed + tempered:true, no
	// review block invented.
	path := writeFiber(t, host, "oneoff", `---
name: One off
status: active
shuttle:
  kind: oneshot
---

Body.
`)

	closeTempered = "true"
	defer func() { closeTempered = "" }()
	if err := closeCmd.RunE(closeCmd, []string{"oneoff"}); err != nil {
		t.Fatalf("RunE: %v", err)
	}

	text := readFiberText(t, path)
	if !strings.Contains(text, "status: closed") {
		t.Fatalf("expected status: closed:\n%s", text)
	}
	if !strings.Contains(text, "tempered: true") {
		t.Fatalf("expected tempered: true:\n%s", text)
	}
	if strings.Contains(text, "review") {
		t.Fatalf("oneshot close should not write a review block:\n%s", text)
	}
}

func readFiberText(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	return string(raw)
}
