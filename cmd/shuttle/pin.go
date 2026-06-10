package main

import (
	"fmt"
	"strings"

	"github.com/cailmdaley/shuttle/pkg/schema"
	"github.com/spf13/cobra"
)

func newPinCmd() *cobra.Command {
	var (
		pinModel      string
		pinProjectDir string
		pinHost       string
	)

	cmd := &cobra.Command{
		Use:   "pin <fiber>",
		Short: "Install a fiber as a pinned, schedule-less dispatchable role",
		Long: `Install the fiber as a pinned role: a schedule-less umbrella concern the
daemon NEVER auto-dispatches. The only way it fires is an explicit
force-dispatch — the kanban's "Dispatch ▸" affordance, or the /dispatch verb.

  shuttle pin <fiber> --project-dir "$PWD"                      # at rest, default agent
  shuttle pin <fiber> --project-dir "$PWD" --model claude-opus  # explicit agent

The shuttle: block is validated before any file is touched.

A pinned role's steady state is status:active "at rest": the poller skips it
(kind=pinned is never eligible for auto-dispatch), so it sits on the board's
pinned strip waiting for a human (or another agent) to dispatch it on demand. A
run closes the fiber to awaiting-review; accepting it re-arms back to rest. This
is the standing-role lifecycle minus the cron.

Use 'shuttle install' for one-shot roles and 'shuttle repeat' for recurring
(cron) standing roles.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			agents := loadAgents()
			path, _, _ := resolveFiber(args[0])
			f := readFiber(path)

			if f.Block != nil {
				return fmt.Errorf("fiber %s already has a shuttle: block (kind=%s); uninstall it first to re-pin", args[0], f.Block.Kind)
			}

			// Stamp host so the block is born owned. A pinned role still needs a
			// host: a force-dispatch must spawn the worker on the owning daemon.
			host, err := resolveOwnHost(pinHost)
			if err != nil {
				return err
			}

			projectDir, err := resolveProjectDirFlag(pinProjectDir)
			if err != nil {
				return err
			}

			block := &schema.Block{
				Kind:       "pinned",
				Host:       host,
				ProjectDir: projectDir,
			}
			if pinModel != "" {
				block.Agent = pinModel
			}
			if strings.TrimSpace(block.Host) == "" {
				return fmt.Errorf("pinned role requires a host (the owning daemon's host id; pass --host or run on the owning machine)")
			}

			if errs := schema.Validate(block, agents); len(errs) > 0 {
				fmt.Fprintln(cmd.ErrOrStderr(), "shuttle: validation failed:")
				for _, e := range errs {
					fmt.Fprintf(cmd.ErrOrStderr(), "  %s\n", e)
				}
				return fmt.Errorf("invalid input")
			}

			// Pinned steady state is status:active "at rest" — never dispatched by
			// the poller, only by an explicit force-dispatch. Closed fibers must be
			// reopened first.
			statusBefore := f.Status()
			if statusBefore == "closed" {
				return fmt.Errorf("fiber %s has status: closed; reopen it before pinning", args[0])
			}
			statusChanged := false
			if statusBefore != "active" {
				f.SetStatus("active")
				statusChanged = true
			}

			if err := f.WriteBlock(block); err != nil {
				return fmt.Errorf("writing fiber: %w", err)
			}

			fmt.Fprintf(cmd.OutOrStdout(), "pinned %s (schedule-less; dispatch on demand)\n", args[0])
			fmt.Fprintf(cmd.OutOrStdout(), "  host: %s\n", block.Host)
			if block.Agent != "" {
				fmt.Fprintf(cmd.OutOrStdout(), "  agent: %s\n", block.Agent)
			}
			fmt.Fprintf(cmd.OutOrStdout(), "  project_dir: %s\n", block.ProjectDir)
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
	cmd.Flags().StringVarP(&pinModel, "model", "m", "", "Agent ID (default: registry default)")
	cmd.Flags().StringVar(&pinProjectDir, "project-dir", "", "Worker cwd on the target host (required)")
	cmd.Flags().StringVar(&pinHost, "host", "", "Owning daemon's host id (default: local daemon's own_host_id; set for cross-host install)")
	return cmd
}

func init() {
	rootCmd.AddCommand(newPinCmd())
}
