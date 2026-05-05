package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

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
