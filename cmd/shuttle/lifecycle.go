package main

import (
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/cailmdaley/shuttle/pkg/schema"
	"github.com/spf13/cobra"
)

var pauseCmd = &cobra.Command{
	Use:   "pause <fiber>",
	Short: "Pause dispatch and park a fiber in drafts",
	Long: `Sets shuttle.enabled = false while preserving the schedule. When the fiber
is currently closed, pause also reopens it to status: active and clears
closed-at / tempered so the card lands in Drafts rather than Awaiting review.
Open fibers keep their existing status (typically open).

This makes pause the single-writer transition for the Kanban's Drafts target.`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		path, _, _ := resolveFiber(args[0])
		f := readFiber(path)
		if f.Block == nil {
			return fmt.Errorf("fiber %s has no shuttle: block", args[0])
		}

		statusBefore := f.Status()
		if statusBefore == "closed" {
			f.SetStatus("active")
		}
		f.SetTempered(nil)
		f.ClearClosedAt()
		f.Block.Enabled = false
		if err := f.WriteBlock(f.Block); err != nil {
			return fmt.Errorf("writing fiber: %w", err)
		}
		fmt.Printf("paused %s (enabled=false; schedule preserved)\n", args[0])
		if statusBefore == "closed" {
			fmt.Println("  status: closed → active")
			fmt.Println("  cleared: tempered, closed-at")
		}
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

Refuses if status is currently "closed" — use 'shuttle reopen' to requeue a
closed fiber back into active work.`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		path, _, _ := resolveFiber(args[0])
		f := readFiber(path)
		if f.Block == nil {
			return fmt.Errorf("fiber %s has no shuttle: block", args[0])
		}

		// Mirror install: ensure status is dispatchable before flipping
		// enabled. See lib/shuttle/poller.ex `eligible?/2` for the filter.
		statusBefore := f.Status()
		statusChanged := false
		if statusBefore == "closed" {
			return fmt.Errorf("fiber %s has status: closed; use 'shuttle reopen %s' to clear verdict fields and requeue it", args[0], args[0])
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

var closeTempered string

var closeCmd = &cobra.Command{
	Use:   "close <fiber>",
	Short: "Close a shuttle-managed fiber and optionally set the human verdict",
	Long: `Sets status: closed, sets/clears tempered, and stamps closed-at when the
field is missing. Use:

  shuttle close <fiber>                   # awaiting review (tempered cleared)
  shuttle close <fiber> --tempered=true   # human-accepted
  shuttle close <fiber> --tempered=false  # composted / rejected

The shuttle block stays installed; closed fibers are ignored by the daemon
until they are reopened.`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		path, _, _ := resolveFiber(args[0])
		f := readFiber(path)
		if f.Block == nil {
			return fmt.Errorf("fiber %s has no shuttle: block", args[0])
		}

		var tempered *bool
		if closeTempered != "" {
			parsed, err := parseOptionalBool(closeTempered)
			if err != nil {
				return fmt.Errorf("parsing --tempered: %w", err)
			}
			tempered = parsed
		}

		f.SetStatus("closed")
		f.SetTempered(tempered)
		f.SetClosedAtIfMissing(time.Now().UTC().Format("2006-01-02T15:04:05.000Z"))
		if err := f.WriteBlock(f.Block); err != nil {
			return fmt.Errorf("writing fiber: %w", err)
		}

		fmt.Printf("closed %s\n", args[0])
		switch {
		case tempered == nil:
			fmt.Println("  tempered: cleared (awaiting review)")
		case *tempered:
			fmt.Println("  tempered: true")
		default:
			fmt.Println("  tempered: false")
		}
		return nil
	},
}

var reopenCmd = &cobra.Command{
	Use:   "reopen <fiber>",
	Short: "Requeue a closed or reviewed fiber back into active work",
	Long: `Sets shuttle.enabled = true, status = active, and clears tempered /
closed-at so a previously closed card re-enters the in-flight loop.

This is the canonical reopen path for Kanban requeues from Awaiting review,
Tempered, or Composted back to In flight.`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		path, _, _ := resolveFiber(args[0])
		f := readFiber(path)
		if f.Block == nil {
			return fmt.Errorf("fiber %s has no shuttle: block", args[0])
		}

		statusBefore := f.Status()
		f.SetStatus("active")
		f.SetTempered(nil)
		f.ClearClosedAt()
		f.Block.Enabled = true
		if err := f.WriteBlock(f.Block); err != nil {
			return fmt.Errorf("writing fiber: %w", err)
		}

		fmt.Printf("reopened %s (enabled=true)\n", args[0])
		if statusBefore == "" {
			fmt.Println("  status: active (set; was missing)")
		} else if statusBefore != "active" {
			fmt.Printf("  status: %s → active\n", statusBefore)
		}
		fmt.Println("  cleared: tempered, closed-at")
		return nil
	},
}

func newSetOutcomeCmd() *cobra.Command {
	var outcomeValue string
	cmd := &cobra.Command{
		Use:   "set-outcome <fiber>",
		Short: "Set the outcome field on a shuttle-managed fiber",
		Long: `Updates the felt-native outcome: field while preserving the existing
shuttle: block. Use --outcome for single-line values, or pipe multi-line text
on stdin to preserve block-scalar output.

Examples:
  shuttle set-outcome <fiber> --outcome "Blocked: waiting on ADS token"
  printf 'First line\nSecond line\n' | shuttle set-outcome <fiber>`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			path, _, _ := resolveFiber(args[0])
			f := readFiber(path)
			if f.Block == nil {
				return fmt.Errorf("fiber %s has no shuttle: block", args[0])
			}

			outcome, err := resolveOutcomeValue(cmd, outcomeValue)
			if err != nil {
				return err
			}

			f.SetOutcome(outcome)
			if err := f.WriteBlock(f.Block); err != nil {
				return fmt.Errorf("writing fiber: %w", err)
			}

			fmt.Printf("set outcome for %s\n", args[0])
			return nil
		},
	}
	cmd.Flags().StringVar(&outcomeValue, "outcome", "", "Outcome text; omit to read from stdin")
	return cmd
}

var setOutcomeCmd = newSetOutcomeCmd()

func resolveOutcomeValue(cmd *cobra.Command, flagValue string) (string, error) {
	if cmd.Flags().Changed("outcome") {
		return flagValue, nil
	}

	in := cmd.InOrStdin()
	if file, ok := in.(*os.File); ok {
		if stat, err := file.Stat(); err == nil && (stat.Mode()&os.ModeCharDevice) != 0 {
			return "", fmt.Errorf("provide --outcome or pipe outcome text on stdin")
		}
	}

	data, err := io.ReadAll(in)
	if err != nil {
		return "", fmt.Errorf("reading outcome from stdin: %w", err)
	}
	return strings.TrimRight(string(data), "\r\n"), nil
}

func parseOptionalBool(raw string) (*bool, error) {
	switch raw {
	case "true":
		value := true
		return &value, nil
	case "false":
		value := false
		return &value, nil
	case "":
		return nil, nil
	default:
		return nil, fmt.Errorf("must be true or false, got %q", raw)
	}
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
		path, fiberID, host := resolveFiber(args[0])
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
		_ = appendFeltHistory(host, fiberID, fmt.Sprintf("accepted run %s; next due %s", runID, next.Format(time.RFC3339)))

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
		path, _, _ := resolveFiber(args[0])
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
		path, _, _ := resolveFiber(args[0])
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
	closeCmd.Flags().StringVar(&closeTempered, "tempered", "", "Set tempered verdict (true/false); omit to clear it for awaiting review")
	rootCmd.AddCommand(pauseCmd)
	rootCmd.AddCommand(resumeCmd)
	rootCmd.AddCommand(closeCmd)
	rootCmd.AddCommand(reopenCmd)
	rootCmd.AddCommand(setOutcomeCmd)
	rootCmd.AddCommand(acceptCmd)
	rootCmd.AddCommand(setModelCmd)
	rootCmd.AddCommand(uninstallCmd)
}
