package main

import (
	"fmt"
	"time"

	"github.com/cailmdaley/shuttle-cli/pkg/schema"
	"github.com/spf13/cobra"
)

var (
	repeatSchedule string
	repeatTZ       string
	repeatModel    string
)

var repeatCmd = &cobra.Command{
	Use:   "repeat <fiber>",
	Short: "Install a fiber as a standing (recurring) role",
	Long: `Install the fiber as a standing role on a recurring cron schedule.

The cron expression uses standard 5-field syntax: minute hour dom month dow.
Example: --schedule "0 9 * * 1-5" runs at 09:00 on weekdays.

The --tz flag must be an IANA timezone name (e.g. Europe/Paris, UTC).

  shuttle repeat <fiber> --schedule "0 9 * * 1-5" --tz Europe/Paris

The shuttle: block is validated before any file is touched.
The running daemon picks it up on its next poll.`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		agents := loadAgents()
		path, _, _ := resolveFiber(args[0])
		f := readFiber(path)

		block := &schema.Block{
			Enabled: true,
			Kind:    "standing",
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
		block.NextDueAt = &next
		block.Review = &schema.Review{State: "scheduled"}

		// Ensure felt status is dispatchable. The poller filters on
		// status in [active, open]; a missing field is treated as
		// ineligible. See lib/shuttle/poller.ex `eligible?/2`.
		statusBefore := f.Status()
		statusChanged := false
		if statusBefore == "closed" {
			return fmt.Errorf("fiber %s has status: closed; reopen it (set status: active in the markdown) before installing", args[0])
		}
		if statusBefore != "active" && statusBefore != "open" {
			f.SetStatus("active")
			statusChanged = true
		}

		if err := f.WriteBlock(block); err != nil {
			return fmt.Errorf("writing fiber: %w", err)
		}

		fmt.Printf("installed %s as standing role\n", args[0])
		fmt.Printf("  schedule: %s (%s)\n", repeatSchedule, repeatTZ)
		if block.Agent != "" {
			fmt.Printf("  agent:    %s\n", block.Agent)
		}
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
	_ = repeatCmd.MarkFlagRequired("schedule")
	rootCmd.AddCommand(repeatCmd)
}
