package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/cailmdaley/shuttle/pkg/schema"
	"github.com/spf13/cobra"
)

func newInstallCmd() *cobra.Command {
	var (
		installModel       string
		installProjectDir  string
		installDisabled    bool
		installInteractive bool
	)

	cmd := &cobra.Command{
		Use:   "install <fiber>",
		Short: "Install a fiber as a one-shot dispatch role",
		Long: `Install the fiber as a oneshot role: a one-time dispatch that the daemon
picks up on its next poll once enabled.

  shuttle install <fiber> --project-dir "$PWD"                      # enabled, default agent
  shuttle install <fiber> --project-dir "$PWD" --model claude-opus  # explicit agent
  shuttle install <fiber> --project-dir "$PWD" --interactive        # human attaches after initial task
  shuttle install <fiber> --disabled                                # land in drafts (paused)

The shuttle: block is validated before any file is touched.
The running daemon picks it up on its next poll when enabled.

When installing without --disabled, the felt-native status field is set to
"active" if it was missing or any value other than "active"/"open" — the
poller's eligibility filter requires this. Closed fibers must be reopened
before installing. Use 'shuttle reopen <fiber>' when the fiber already has a
shuttle block, or set status: active in the markdown before a first install.

Idempotent: if the fiber already has a shuttle: block, install reports its
current state and exits 0 when no conflicting flags are passed — useful
right after writing the block by hand in the constitution markdown. If a
flag conflicts with the existing block (--model differs from the current
agent, --disabled differs from current enabled state, --interactive differs
from current interactive state, --project-dir
differs), install exits non-zero and points at the right mutation verb
(pause / resume / set-model / set-interactive / uninstall). Even on the idempotent path,
install will bump felt status to "active" if it was missing — otherwise
the daemon would silently ignore an enabled block.

Use 'shuttle repeat' for standing (recurring) roles.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			agents := loadAgents()
			path, _, _ := resolveFiber(args[0])
			f := readFiber(path)

			// If a block already exists, treat install as idempotent state
			// reporting + conflict detection. The common case is "I wrote
			// the block manually and just want to confirm the daemon will
			// dispatch it"; the failure case is "I passed a flag that
			// conflicts with what's already there."
			if f.Block != nil {
				return reportExistingBlock(cmd, args[0], f, installModel, installDisabled, installProjectDir, installInteractive)
			}

			block := &schema.Block{
				Enabled:     !installDisabled,
				Kind:        "oneshot",
				Interactive: installInteractive,
			}

			if installModel != "" {
				block.Agent = installModel
			}
			if !installDisabled {
				projectDir, err := resolveProjectDirFlag(installProjectDir)
				if err != nil {
					return err
				}
				block.ProjectDir = projectDir
			}

			// Validate (catches unknown agent) before touching the file.
			if errs := schema.Validate(block, agents); len(errs) > 0 {
				fmt.Fprintln(cmd.ErrOrStderr(), "shuttle: validation failed:")
				for _, e := range errs {
					fmt.Fprintf(cmd.ErrOrStderr(), "  %s\n", e)
				}
				return fmt.Errorf("invalid input")
			}

			// Ensure felt status is dispatchable when we're installing enabled.
			// The shuttle daemon's poller filters on status in [active, open]
			// (lib/shuttle/poller.ex `eligible?/2`); a missing field is treated
			// as ineligible — silent failure for users who run `install` and
			// expect dispatch on next poll.
			statusBefore := f.Status()
			statusChanged := false
			if !installDisabled {
				if statusBefore == "closed" {
					return fmt.Errorf("fiber %s has status: closed; use 'shuttle reopen %s' when it already has a shuttle block, or set status: active before installing; use --disabled to park in drafts", args[0], args[0])
				}
				if statusBefore != "active" && statusBefore != "open" {
					f.SetStatus("active")
					statusChanged = true
				}
			}

			if err := f.WriteBlock(block); err != nil {
				return fmt.Errorf("writing fiber: %w", err)
			}

			state := "enabled"
			if installDisabled {
				state = "disabled (paused)"
			}
			fmt.Fprintf(cmd.OutOrStdout(), "installed %s as oneshot role (%s)\n", args[0], state)
			if block.Agent != "" {
				fmt.Fprintf(cmd.OutOrStdout(), "  agent: %s\n", block.Agent)
			}
			if block.ProjectDir != "" {
				fmt.Fprintf(cmd.OutOrStdout(), "  project_dir: %s\n", block.ProjectDir)
			}
			if block.Interactive {
				fmt.Fprintln(cmd.OutOrStdout(), "  interactive: true")
			}
			if statusChanged {
				if statusBefore == "" {
					fmt.Fprintln(cmd.OutOrStdout(), "  status: active (set; was missing)")
				} else {
					fmt.Fprintf(cmd.OutOrStdout(), "  status: %s → active\n", statusBefore)
				}
			}
			return nil
		},
	}
	cmd.Flags().StringVarP(&installModel, "model", "m", "", "Agent ID (default: registry default)")
	cmd.Flags().StringVar(&installProjectDir, "project-dir", "", "Worker cwd on the target host (required unless --disabled)")
	cmd.Flags().BoolVar(&installDisabled, "disabled", false, "Install with enabled=false (lands in drafts; use 'shuttle resume' to dispatch)")
	cmd.Flags().BoolVar(&installInteractive, "interactive", false, "Dispatch in interactive mode (worker stays alive after initial task)")
	return cmd
}

// reportExistingBlock prints the current block state for the fiber, fixes
// missing felt status if the block is enabled, and either returns nil
// (idempotent confirmation, no flag conflicts) or returns an error pointing
// at the right mutation verb (a passed flag disagrees with the existing
// block). Cobra's Flags().Changed("...") distinguishes "user took the
// default" from "user explicitly passed the value" — only explicit
// disagreements raise conflicts, so a plain `install <fiber>` with no
// flags is always a pure state query.
func reportExistingBlock(cmd *cobra.Command, fiberID string, f *schema.FiberFile, model string, disabled bool, projectDir string, interactive bool) error {
	b := f.Block
	out := cmd.OutOrStdout()
	errOut := cmd.ErrOrStderr()

	// Bump felt status if the block is enabled but status is missing —
	// otherwise the daemon silently ignores the fiber and the user has no
	// way to learn that without running `shuttle-ctl status` afterward.
	// "closed" is left alone — install doesn't reopen fibers, that's a
	// human decision.
	statusBefore := f.Status()
	statusChanged := false
	if b.Enabled && statusBefore != "active" && statusBefore != "open" && statusBefore != "closed" {
		f.SetStatus("active")
		if err := f.WriteBlock(b); err != nil {
			return fmt.Errorf("writing status to fiber: %w", err)
		}
		statusChanged = true
	}
	statusNow := f.Status()
	eligible := b.Enabled && (statusNow == "active" || statusNow == "open")

	// Headline + block summary.
	headline := fmt.Sprintf("shuttle: fiber %s already has a shuttle: block (install is idempotent).", fiberID)
	if b.Kind == "standing" {
		headline = fmt.Sprintf("shuttle: fiber %s already has a standing-role shuttle: block.", fiberID)
	}
	fmt.Fprintln(out, headline)
	fmt.Fprintln(out, "")
	writeBlockSummary(out, b, statusNow, statusChanged, statusBefore, eligible)

	// Dispatch state assessment.
	fmt.Fprintln(out, "")
	switch {
	case statusNow == "closed":
		fmt.Fprintf(out, "→ Fiber is closed — daemon will NOT dispatch. Use `shuttle-ctl reopen %s` to clear verdict fields and requeue it.\n", fiberID)
	case eligible:
		fmt.Fprintln(out, "→ Daemon will dispatch on next poll. No action needed.")
	case b.Enabled && statusNow == "":
		fmt.Fprintln(out, "→ Status missing — daemon will NOT dispatch. Set status: active in the markdown.")
	case !b.Enabled:
		fmt.Fprintf(out, "→ Block is disabled (in drafts). Use `shuttle-ctl resume %s` to dispatch.\n", fiberID)
	}

	// Conflict detection: only fire when the user explicitly passed a flag
	// that disagrees with the existing block.
	modelChanged := cmd.Flags().Changed("model")
	disabledChanged := cmd.Flags().Changed("disabled")
	projectDirChanged := cmd.Flags().Changed("project-dir")
	interactiveChanged := cmd.Flags().Changed("interactive")

	var mismatches []string
	if modelChanged && model != b.Agent {
		mismatches = append(mismatches,
			fmt.Sprintf("--model %s ≠ current agent %q  →  shuttle-ctl set-model %s %s",
				model, b.Agent, fiberID, model))
	}
	if disabledChanged {
		if disabled && b.Enabled {
			mismatches = append(mismatches,
				fmt.Sprintf("--disabled passed but block is enabled  →  shuttle-ctl pause %s", fiberID))
		} else if !disabled && !b.Enabled {
			mismatches = append(mismatches,
				fmt.Sprintf("--disabled=false passed but block is disabled  →  shuttle-ctl resume %s", fiberID))
		}
	}
	if projectDirChanged {
		expanded, err := resolveProjectDirFlag(projectDir)
		if err == nil && expanded != b.ProjectDir {
			mismatches = append(mismatches,
				fmt.Sprintf("--project-dir %s ≠ current %q  →  shuttle-ctl uninstall %s && shuttle-ctl install %s --project-dir %s",
					expanded, b.ProjectDir, fiberID, fiberID, expanded))
		}
	}
	if interactiveChanged && interactive != b.Interactive {
		mismatches = append(mismatches,
			fmt.Sprintf("--interactive %v ≠ current interactive %v  →  shuttle-ctl set-interactive %s %v",
				interactive, b.Interactive, fiberID, interactive))
	}

	if len(mismatches) > 0 {
		fmt.Fprintln(errOut, "")
		fmt.Fprintln(errOut, "Conflicts with current block:")
		for _, m := range mismatches {
			fmt.Fprintf(errOut, "  %s\n", m)
		}
		return fmt.Errorf("install would mutate existing block; use the verbs above")
	}

	return nil
}

// writeBlockSummary writes the human-readable "Current block:" report used
// by reportExistingBlock.
func writeBlockSummary(out io.Writer, b *schema.Block, statusNow string, statusChanged bool, statusBefore string, eligible bool) {
	fmt.Fprintln(out, "Current block:")
	fmt.Fprintf(out, "  kind:        %s\n", nonEmpty(b.Kind, "(unset)"))
	fmt.Fprintf(out, "  enabled:     %v\n", b.Enabled)
	if b.Interactive {
		fmt.Fprintln(out, "  interactive: true")
	}
	if b.Agent != "" {
		fmt.Fprintf(out, "  agent:       %s\n", b.Agent)
	}
	if b.ProjectDir != "" {
		fmt.Fprintf(out, "  project_dir: %s\n", b.ProjectDir)
	}
	if b.Schedule != nil {
		fmt.Fprintf(out, "  schedule:    %q tz=%s\n", b.Schedule.Expr, b.Schedule.TZ)
	}

	switch {
	case statusNow == "":
		fmt.Fprintln(out, "  status:      (missing — NOT eligible; set status: active in the markdown)")
	case statusNow == "closed":
		fmt.Fprintln(out, "  status:      closed (NOT eligible — daemon ignores closed fibers)")
	case eligible:
		fmt.Fprintf(out, "  status:      %s (eligible)\n", statusNow)
	default:
		fmt.Fprintf(out, "  status:      %s\n", statusNow)
	}
	if statusChanged {
		fmt.Fprintf(out, "               (was %q — bumped to %q because block is enabled)\n",
			nonEmpty(statusBefore, ""), statusNow)
	}
}

func nonEmpty(s, fallback string) string {
	if s == "" {
		return fallback
	}
	return s
}

func resolveProjectDirFlag(raw string) (string, error) {
	if raw == "" {
		return "", fmt.Errorf("project_dir is required when enabling dispatch; pass --project-dir <path>")
	}
	expanded := os.ExpandEnv(raw)
	if strings.HasPrefix(expanded, "~") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("resolving ~ in project_dir: %w", err)
		}
		switch {
		case expanded == "~":
			expanded = home
		case strings.HasPrefix(expanded, "~/"):
			expanded = filepath.Join(home, strings.TrimPrefix(expanded, "~/"))
		}
	}
	abs, err := filepath.Abs(expanded)
	if err != nil {
		return "", fmt.Errorf("resolving project_dir %q: %w", raw, err)
	}
	if info, err := os.Stat(abs); err != nil {
		return "", fmt.Errorf("project_dir %q does not exist or is not readable: %w", abs, err)
	} else if !info.IsDir() {
		return "", fmt.Errorf("project_dir %q is not a directory", abs)
	}
	return abs, nil
}

func init() {
	rootCmd.AddCommand(newInstallCmd())
}
