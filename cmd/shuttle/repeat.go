package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/cailmdaley/shuttle/pkg/schema"
	"github.com/spf13/cobra"
)

var (
	repeatSchedule   string
	repeatTZ         string
	repeatModel      string
	repeatProjectDir string
	repeatHost       string
)

var repeatCmd = &cobra.Command{
	Use:   "repeat <fiber>",
	Short: "Install a fiber as a standing (recurring) role",
	Long: `Install the fiber as a standing role on a recurring cron schedule.

The cron expression uses standard 5-field syntax: minute hour dom month dow.
Example: --schedule "0 9 * * 1-5" runs at 09:00 on weekdays.

The --tz flag must be an IANA timezone name (e.g. Europe/Paris, UTC).

  shuttle repeat <fiber> --schedule "0 9 * * 1-5" --tz Europe/Paris --project-dir "$PWD"

The shuttle: block is validated before any file is touched.
The running daemon picks it up on its next poll.`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		agents := loadAgents()
		path, _, _ := resolveFiber(args[0])
		f := readFiber(path)
		projectDir, err := resolveProjectDirFlag(repeatProjectDir)
		if err != nil {
			return err
		}

		host, err := resolveOwnHost(repeatHost)
		if err != nil {
			return err
		}

		block := &schema.Block{
			Kind:       "standing",
			ProjectDir: projectDir,
			Host:       host,
			Schedule: &schema.Schedule{
				Expr: repeatSchedule,
				TZ:   repeatTZ,
			},
		}

		if repeatModel != "" {
			block.Agent = repeatModel
		} else if f.Block != nil && f.Block.Agent != "" {
			block.Agent = f.Block.Agent
		}

		// A standing role is born armed (status:active), so it must declare its
		// owning daemon — the dispatch predicate is strict block.host ==
		// own_host_id with no wildcard. resolveOwnHost stamps it by default.
		if strings.TrimSpace(block.Host) == "" {
			return fmt.Errorf("repeat requires a host (the owning daemon's host id; pass --host or run on the owning machine)")
		}

		// Validate (catches bad cron, bad tz, unknown agent) before touching the file.
		if errs := schema.Validate(block, agents); len(errs) > 0 {
			fmt.Fprintln(cmd.ErrOrStderr(), "shuttle: validation failed:")
			for _, e := range errs {
				fmt.Fprintf(cmd.ErrOrStderr(), "  %s\n", e)
			}
			return fmt.Errorf("invalid input")
		}

		next, err := schema.NextOccurrence(block.Schedule, time.Now())
		if err != nil {
			return fmt.Errorf("computing next occurrence: %w", err)
		}

		// Arm the role: status:active is the sole dispatch gate (slice 5 — no
		// enabled flag, no review block). Due-ness is computed cron.next(now)
		// by the daemon; next_due is shown here for the operator only.
		statusBefore := f.Status()
		statusChanged := false
		if statusBefore == "closed" {
			return fmt.Errorf("fiber %s has status: closed; use 'shuttle reopen %s' to clear verdict fields and requeue it before installing", args[0], args[0])
		}
		if statusBefore != "active" {
			f.SetStatus("active")
			statusChanged = true
		}

		if err := f.WriteBlock(block); err != nil {
			return fmt.Errorf("writing fiber: %w", err)
		}

		fmt.Printf("installed %s as standing role\n", args[0])
		fmt.Printf("  host:     %s\n", block.Host)
		fmt.Printf("  schedule: %s (%s)\n", repeatSchedule, repeatTZ)
		if block.Agent != "" {
			fmt.Printf("  agent:    %s\n", block.Agent)
		}
		fmt.Printf("  project_dir: %s\n", block.ProjectDir)
		fmt.Printf("  next due: %s\n", next.Format(time.RFC3339))
		if statusChanged {
			if statusBefore == "" {
				fmt.Println("  status:   active (set; was missing)")
			} else {
				fmt.Printf("  status:   %s → active\n", statusBefore)
			}
		}
		return nil
	},
}

func init() {
	repeatCmd.Flags().StringVarP(&repeatSchedule, "schedule", "s", "", "Cron expression (5-field standard syntax) — required")
	repeatCmd.Flags().StringVarP(&repeatTZ, "tz", "z", "UTC", "IANA timezone name (default: UTC)")
	repeatCmd.Flags().StringVarP(&repeatModel, "model", "m", "", "Agent ID (default: registry default)")
	repeatCmd.Flags().StringVar(&repeatProjectDir, "project-dir", "", "Worker cwd on the target host (required)")
	repeatCmd.Flags().StringVar(&repeatHost, "host", "", "Owning daemon's host id (default: local daemon's own_host_id; set for cross-host install)")
	_ = repeatCmd.MarkFlagRequired("schedule")
	rootCmd.AddCommand(repeatCmd)
}
