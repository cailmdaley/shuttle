package main

import (
	"fmt"
	"time"

	"github.com/cailmdaley/shuttle-cli/pkg/schema"
	"github.com/spf13/cobra"
)

var pauseCmd = &cobra.Command{
	Use:   "pause <fiber>",
	Short: "Pause dispatch without disturbing the schedule",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		path, _ := resolveFiber(args[0])
		f := readFiber(path)
		if f.Block == nil {
			return fmt.Errorf("fiber %s has no shuttle: block", args[0])
		}
		f.Block.Enabled = false
		if err := f.WriteBlock(f.Block); err != nil {
			return fmt.Errorf("writing fiber: %w", err)
		}
		fmt.Printf("paused %s (enabled=false; schedule preserved)\n", args[0])
		return nil
	},
}

var resumeCmd = &cobra.Command{
	Use:   "resume <fiber>",
	Short: "Resume a paused fiber (enabled=true; ensures status: active)",
	Long: `Sets shuttle.enabled = true and ensures the felt-native status field is
"active" so the daemon's eligibility filter accepts the fiber on its next
poll. A missing or non-dispatchable status would otherwise leave the fiber
silently un-dispatched even with enabled=true.

Refuses if status is currently "closed" — closed fibers must be explicitly
reopened in the markdown before resuming.`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		path, _ := resolveFiber(args[0])
		f := readFiber(path)
		if f.Block == nil {
			return fmt.Errorf("fiber %s has no shuttle: block", args[0])
		}

		// Mirror install: ensure status is dispatchable before flipping
		// enabled. See lib/shuttle/poller.ex `eligible?/2` for the filter.
		statusBefore := f.Status()
		statusChanged := false
		if statusBefore == "closed" {
			return fmt.Errorf("fiber %s has status: closed; reopen it (set status: active in the markdown) before resuming", args[0])
		}
		if statusBefore != "active" && statusBefore != "open" {
			f.SetStatus("active")
			statusChanged = true
		}

		f.Block.Enabled = true
		if err := f.WriteBlock(f.Block); err != nil {
			return fmt.Errorf("writing fiber: %w", err)
		}
		fmt.Printf("resumed %s (enabled=true)\n", args[0])
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

var acceptCmd = &cobra.Command{
	Use:   "accept <fiber>",
	Short: "Accept a completed standing-role run and advance the schedule",
	Long: `Flips shuttle.review.state to accepted/scheduled and advances next_due_at.

The run_id from the current awaiting run becomes accepted_run_id, review.state
is reset to scheduled, and next_due_at is advanced to the next occurrence.

Appends a felt history event recording the acceptance.`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		path, fiberID := resolveFiber(args[0])
		f := readFiber(path)
		if f.Block == nil {
			return fmt.Errorf("fiber %s has no shuttle: block", args[0])
		}
		if f.Block.Kind != "standing" {
			return fmt.Errorf("accept only applies to standing roles (fiber has kind=%s)", f.Block.Kind)
		}
		if f.Block.Review == nil || f.Block.Review.State != "awaiting" {
			state := ""
			if f.Block.Review != nil {
				state = f.Block.Review.State
			}
			return fmt.Errorf("fiber %s is not awaiting review (state=%q)", args[0], state)
		}
		if f.Block.Schedule == nil {
			return fmt.Errorf("fiber %s has no schedule", args[0])
		}

		runID := ""
		if f.Block.Review.RunID != nil {
			runID = *f.Block.Review.RunID
		}

		// Advance next_due_at from current or now.
		from := time.Now()
		if f.Block.NextDueAt != nil {
			from = *f.Block.NextDueAt
		}
		next, err := schema.NextOccurrence(f.Block.Schedule, from)
		if err != nil {
			return fmt.Errorf("computing next occurrence: %w", err)
		}

		f.Block.Review = &schema.Review{
			State:         "scheduled",
			RunID:         schema.StringPtr(runID),
			AcceptedRunID: schema.StringPtr(runID),
		}
		f.Block.NextDueAt = &next
		f.Block.Enabled = true // ensure re-enabled after review

		if err := f.WriteBlock(f.Block); err != nil {
			return fmt.Errorf("writing fiber: %w", err)
		}

		// Append felt history event.
		_ = appendFeltHistory(fiberID, fmt.Sprintf("accepted run %s; next due %s", runID, next.Format(time.RFC3339)))

		fmt.Printf("accepted run %s for %s\n", runID, args[0])
		fmt.Printf("  next due: %s\n", next.Format(time.RFC3339))
		return nil
	},
}

var setModelCmd = &cobra.Command{
	Use:   "set-model <fiber> <agent>",
	Short: "Change the dispatch agent for a fiber",
	Long: `Updates shuttle.agent to the given agent ID. Validates against the
agent registry before writing. Removes any existing agent:* felt tag
(the shuttle: block is now the authoritative source).`,
	Args: cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		agents := loadAgents()
		path, _ := resolveFiber(args[0])
		f := readFiber(path)
		if f.Block == nil {
			return fmt.Errorf("fiber %s has no shuttle: block (use 'shuttle repeat' to install first)", args[0])
		}

		agentID := args[1]
		if _, ok := agents.Find(agentID); !ok {
			return fmt.Errorf("unknown agent %q (known: %s)", agentID, joinIDs(agents.IDs()))
		}

		f.Block.Agent = agentID
		if err := f.WriteBlock(f.Block); err != nil {
			return fmt.Errorf("writing fiber: %w", err)
		}

		fmt.Printf("set agent for %s → %s\n", args[0], agentID)
		return nil
	},
}

var uninstallCmd = &cobra.Command{
	Use:   "uninstall <fiber>",
	Short: "Remove the shuttle: block from a fiber",
	Long: `Removes the shuttle: block entirely. The fiber is left in place; the
daemon will no longer dispatch it. The felt tags and status are not changed.`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		path, _ := resolveFiber(args[0])
		f := readFiber(path)
		if f.Block == nil {
			fmt.Printf("fiber %s has no shuttle: block (nothing to do)\n", args[0])
			return nil
		}
		if err := f.WriteBlock(nil); err != nil {
			return fmt.Errorf("removing shuttle block: %w", err)
		}
		fmt.Printf("uninstalled %s (shuttle: block removed)\n", args[0])
		return nil
	},
}

func joinIDs(ids []string) string {
	result := ""
	for i, id := range ids {
		if i > 0 {
			result += ", "
		}
		result += id
	}
	return result
}

func init() {
	rootCmd.AddCommand(pauseCmd)
	rootCmd.AddCommand(resumeCmd)
	rootCmd.AddCommand(acceptCmd)
	rootCmd.AddCommand(setModelCmd)
	rootCmd.AddCommand(uninstallCmd)
}
