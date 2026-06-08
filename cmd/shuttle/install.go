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
		installHost        string
		installDisabled    bool
		installInteractive bool
	)

	cmd := &cobra.Command{
		Use:   "install <fiber>",
		Short: "Install a fiber as a one-shot dispatch role",
		Long: `Install the fiber as a oneshot role: a one-time dispatch that the daemon
picks up on its next poll.

  shuttle install <fiber> --project-dir "$PWD"                      # armed, default agent
  shuttle install <fiber> --project-dir "$PWD" --model claude-opus  # explicit agent
  shuttle install <fiber> --project-dir "$PWD" --interactive        # human attaches after initial task
  shuttle install <fiber> --disabled                                # land in drafts (status: open)

The shuttle: block is validated before any file is touched.

Dispatch is gated solely by the felt-native status field: status:active is
armed (the daemon dispatches on its next poll), status:open is a draft. An
armed install sets status:active; --disabled sets status:open. Closed fibers
must be reopened before installing — use 'shuttle reopen <fiber>'.

Idempotent: if the fiber already has a shuttle: block, install reports its
current state and exits 0 when no conflicting flags are passed — useful
right after writing the block by hand in the constitution markdown. If a
flag conflicts with the existing block (--model differs from the current
agent, --interactive differs from current interactive state, --project-dir
differs), install exits non-zero and points at the right mutation verb
(pause / resume / set-model / set-interactive / uninstall).

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
				return reportExistingBlock(cmd, args[0], f, installModel, installDisabled, installProjectDir, installInteractive, installHost)
			}

			// Stamp host so the block is born owned. Default to the local
			// daemon's own_host_id; --host installs a block destined for
			// another daemon.
			host, err := resolveOwnHost(installHost)
			if err != nil {
				return err
			}

			block := &schema.Block{
				Kind:        "oneshot",
				Interactive: installInteractive,
				Host:        host,
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
				// An armed install must declare which daemon owns it. The
				// dispatch predicate is strict block.host == own_host_id with no
				// wildcard, so a host-less armed block would silently never
				// dispatch. resolveOwnHost stamps it by default; guard the
				// invariant at the write boundary.
				if strings.TrimSpace(block.Host) == "" {
					return fmt.Errorf("armed install requires a host (the owning daemon's host id; pass --host or run on the owning machine)")
				}
			}

			// Validate (catches unknown agent) before touching the file.
			if errs := schema.Validate(block, agents); len(errs) > 0 {
				fmt.Fprintln(cmd.ErrOrStderr(), "shuttle: validation failed:")
				for _, e := range errs {
					fmt.Fprintf(cmd.ErrOrStderr(), "  %s\n", e)
				}
				return fmt.Errorf("invalid input")
			}

			// Set the felt-native status: the sole dispatch gate. An armed
			// install is status:active (dispatched on next poll); --disabled is
			// status:open (a draft, never dispatched). Closed fibers must be
			// reopened first.
			statusBefore := f.Status()
			statusChanged := false
			if installDisabled {
				if statusBefore != "open" {
					f.SetStatus("open")
					statusChanged = true
				}
			} else {
				if statusBefore == "closed" {
					return fmt.Errorf("fiber %s has status: closed; use 'shuttle reopen %s' when it already has a shuttle block, or set status: active before installing; use --disabled to park in drafts", args[0], args[0])
				}
				if statusBefore != "active" {
					f.SetStatus("active")
					statusChanged = true
				}
			}

			if err := f.WriteBlock(block); err != nil {
				return fmt.Errorf("writing fiber: %w", err)
			}

			state := "armed"
			if installDisabled {
				state = "draft (status: open)"
			}
			fmt.Fprintf(cmd.OutOrStdout(), "installed %s as oneshot role (%s)\n", args[0], state)
			fmt.Fprintf(cmd.OutOrStdout(), "  host: %s\n", block.Host)
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
				want := "active"
				if installDisabled {
					want = "open"
				}
				if statusBefore == "" {
					fmt.Fprintf(cmd.OutOrStdout(), "  status: %s (set; was missing)\n", want)
				} else {
					fmt.Fprintf(cmd.OutOrStdout(), "  status: %s → %s\n", statusBefore, want)
				}
			}
			return nil
		},
	}
	cmd.Flags().StringVarP(&installModel, "model", "m", "", "Agent ID (default: registry default)")
	cmd.Flags().StringVar(&installProjectDir, "project-dir", "", "Worker cwd on the target host (required unless --disabled)")
	cmd.Flags().StringVar(&installHost, "host", "", "Owning daemon's host id (default: local daemon's own_host_id; set for cross-host install)")
	cmd.Flags().BoolVar(&installDisabled, "disabled", false, "Install as a draft (status: open); use 'shuttle resume' to arm it")
	cmd.Flags().BoolVar(&installInteractive, "interactive", false, "Dispatch in interactive mode (worker stays alive after initial task)")
	return cmd
}

// reportExistingBlock prints the current block state for the fiber and either
// returns nil (idempotent confirmation, no flag conflicts) or returns an error
// pointing at the right mutation verb (a passed flag disagrees with the existing
// block). Cobra's Flags().Changed("...") distinguishes "user took the default"
// from "user explicitly passed the value" — only explicit disagreements raise
// conflicts, so a plain `install <fiber>` with no flags is always a pure state
// query. The dispatch gate is the felt-native status: active is armed, open is a
// draft (slice 5 — no enabled flag).
func reportExistingBlock(cmd *cobra.Command, fiberID string, f *schema.FiberFile, model string, disabled bool, projectDir string, interactive bool, host string) error {
	b := f.Block
	out := cmd.OutOrStdout()
	errOut := cmd.ErrOrStderr()

	statusNow := f.Status()
	armed := statusNow == "active"
	draft := statusNow == "open"

	// Headline + block summary.
	headline := fmt.Sprintf("shuttle: fiber %s already has a shuttle: block (install is idempotent).", fiberID)
	if b.Kind == "standing" {
		headline = fmt.Sprintf("shuttle: fiber %s already has a standing-role shuttle: block.", fiberID)
	}
	fmt.Fprintln(out, headline)
	fmt.Fprintln(out, "")
	writeBlockSummary(out, b, statusNow, armed)

	// Dispatch state assessment.
	fmt.Fprintln(out, "")
	switch {
	case statusNow == "closed":
		fmt.Fprintf(out, "→ Fiber is closed — daemon will NOT dispatch. Use `shuttle-ctl reopen %s` to clear verdict fields and requeue it.\n", fiberID)
	case armed:
		fmt.Fprintln(out, "→ Daemon will dispatch on next poll. No action needed.")
	case draft:
		fmt.Fprintf(out, "→ Draft (status: open). Use `shuttle-ctl resume %s` to arm it.\n", fiberID)
	case statusNow == "":
		fmt.Fprintf(out, "→ Status missing — daemon will NOT dispatch. Use `shuttle-ctl resume %s` or set status: active in the markdown.\n", fiberID)
	default:
		fmt.Fprintf(out, "→ Status %q is not armed — daemon will NOT dispatch. Use `shuttle-ctl resume %s` to set status: active.\n", statusNow, fiberID)
	}

	// Conflict detection: only fire when the user explicitly passed a flag
	// that disagrees with the existing block.
	modelChanged := cmd.Flags().Changed("model")
	disabledChanged := cmd.Flags().Changed("disabled")
	projectDirChanged := cmd.Flags().Changed("project-dir")
	interactiveChanged := cmd.Flags().Changed("interactive")
	hostChanged := cmd.Flags().Changed("host")

	var mismatches []string
	if hostChanged && strings.TrimSpace(host) != b.Host {
		mismatches = append(mismatches,
			fmt.Sprintf("--host %s ≠ current host %q  →  shuttle-ctl uninstall %s && shuttle-ctl install %s --host %s",
				host, b.Host, fiberID, fiberID, host))
	}
	if modelChanged && model != b.Agent {
		mismatches = append(mismatches,
			fmt.Sprintf("--model %s ≠ current agent %q  →  shuttle-ctl set-model %s %s",
				model, b.Agent, fiberID, model))
	}
	if disabledChanged {
		if disabled && armed {
			mismatches = append(mismatches,
				fmt.Sprintf("--disabled passed but fiber is armed (status: active)  →  shuttle-ctl pause %s", fiberID))
		} else if !disabled && draft {
			mismatches = append(mismatches,
				fmt.Sprintf("--disabled=false passed but fiber is a draft (status: open)  →  shuttle-ctl resume %s", fiberID))
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
// by reportExistingBlock. Eligibility is the felt-native status alone
// (status:active = armed); there is no enabled flag (slice 5).
func writeBlockSummary(out io.Writer, b *schema.Block, statusNow string, armed bool) {
	fmt.Fprintln(out, "Current block:")
	fmt.Fprintf(out, "  kind:        %s\n", nonEmpty(b.Kind, "(unset)"))
	fmt.Fprintf(out, "  host:        %s\n", nonEmpty(b.Host, "(unset — NOT eligible on any daemon)"))
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
		fmt.Fprintln(out, "  status:      (missing — NOT armed; resume or set status: active in the markdown)")
	case statusNow == "closed":
		fmt.Fprintln(out, "  status:      closed (NOT armed — daemon ignores closed fibers)")
	case statusNow == "open":
		fmt.Fprintln(out, "  status:      open (draft — NOT armed; resume to dispatch)")
	case armed:
		fmt.Fprintf(out, "  status:      %s (armed)\n", statusNow)
	default:
		fmt.Fprintf(out, "  status:      %s\n", statusNow)
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
