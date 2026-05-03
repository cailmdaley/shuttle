package main

import (
	"fmt"

	"github.com/cailmdaley/shuttle-cli/pkg/schema"
	"github.com/spf13/cobra"
)

var (
	installModel    string
	installDisabled bool
)

var installCmd = &cobra.Command{
	Use:   "install <fiber>",
	Short: "Install a fiber as a one-shot dispatch role",
	Long: `Install the fiber as a oneshot role: a one-time dispatch that the daemon
picks up on its next poll once enabled.

  shuttle install <fiber>                       # enabled, default agent
  shuttle install <fiber> --model claude-opus   # explicit agent
  shuttle install <fiber> --disabled            # land in drafts (paused)

The shuttle: block is validated before any file is touched.
The running daemon picks it up on its next poll when enabled.

When installing without --disabled, the felt-native status field is set to
"active" if it was missing or any value other than "active"/"open" — the
poller's eligibility filter requires this. Closed fibers must be reopened
in the markdown before installing.

Use 'shuttle repeat' for standing (recurring) roles.`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		agents := loadAgents()
		path, _ := resolveFiber(args[0])
		f := readFiber(path)

		// Refuse to clobber an existing block — the user should pause/resume
		// or set-model rather than re-install. Prevents silent loss of
		// schedule/review state on standing roles.
		if f.Block != nil {
			return fmt.Errorf("fiber %s already has a shuttle: block (use pause/resume/set-model to mutate, or uninstall first)", args[0])
		}

		block := &schema.Block{
			Enabled: !installDisabled,
			Kind:    "oneshot",
		}

		if installModel != "" {
			block.Agent = installModel
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
				return fmt.Errorf("fiber %s has status: closed; reopen it (set status: active in the markdown) before installing, or use --disabled to park in drafts", args[0])
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
		fmt.Printf("installed %s as oneshot role (%s)\n", args[0], state)
		if block.Agent != "" {
			fmt.Printf("  agent: %s\n", block.Agent)
		}
		if statusChanged {
			if statusBefore == "" {
				fmt.Println("  status: active (set; was missing)")
			} else {
				fmt.Printf("  status: %s → active\n", statusBefore)
			}
		}
		return nil
	},
}

func init() {
	installCmd.Flags().StringVarP(&installModel, "model", "m", "", "Agent ID (default: registry default)")
	installCmd.Flags().BoolVar(&installDisabled, "disabled", false, "Install with enabled=false (lands in drafts; use 'shuttle resume' to dispatch)")
	rootCmd.AddCommand(installCmd)
}
