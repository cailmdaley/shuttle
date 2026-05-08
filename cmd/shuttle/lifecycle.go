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

func newPauseCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "pause <fiber>",
		Short: "Pause dispatch, kill any live worker, and park a fiber in drafts",
		Long: `Sets shuttle.enabled = false while preserving the schedule, then kills the
canonical worker tmux session (shuttle-<fiber-id>) if one is running. When the fiber
is currently closed, pause also reopens it to status: active and clears
closed-at / tempered so the card lands in Drafts rather than Awaiting review.
Open fibers keep their existing status (typically open).

Use --no-kill to preserve the old stop-scheduling-only behavior and let a live
worker finish naturally.

This makes pause the single-writer transition for the Kanban's Drafts target.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			noKill, err := cmd.Flags().GetBool("no-kill")
			if err != nil {
				return err
			}
			if !usingLocalOrigin() {
				return postRemoteLifecycle("pause", map[string]any{
					"fiber":   args[0],
					"no_kill": noKill,
				})
			}
			path, fiberID, _ := resolveFiber(args[0])
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
			if noKill {
				fmt.Println("  worker: left running (--no-kill)")
				return nil
			}

			session := schema.TmuxSessionName(fiberID)
			if !tmuxSessionExists(session) {
				fmt.Printf("  worker: no live session %s\n", session)
				return nil
			}
			if err := killTmuxSession(session); err != nil {
				return fmt.Errorf("killing tmux session %q: %w", session, err)
			}
			fmt.Printf("  worker: killed %s\n", session)
			return nil
		},
	}
	cmd.Flags().Bool("no-kill", false, "Only disable future dispatch; leave any live worker tmux session running")
	return cmd
}

var pauseCmd = newPauseCmd()

func newResumeCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "resume <fiber>",
		Short: "Resume a paused fiber (enabled=true; ensures status: active)",
		Long: `Sets shuttle.enabled = true and ensures the felt-native status field is
"active" so the daemon's eligibility filter accepts the fiber on its next
poll. A missing or non-dispatchable status would otherwise leave the fiber
silently un-dispatched even with enabled=true.

For standing roles in awaiting/review state, resume re-queues the fiber for
immediate dispatch rather than just flipping enabled. The daemon's eligibility
check (StandingRole.due?) requires review.state ∈ {scheduled, accepted} — a
fiber in awaiting state would be silently skipped. Resume transitions the block
to scheduled with next_due_at=now so the daemon dispatches a fresh worker on
its next poll. The previous run's id is preserved for reference; this is
distinct from accept, which advances next_due_at to the next cron occurrence.

Refuses if status is currently "closed" — use 'shuttle reopen' to requeue a
closed fiber back into active work.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if !usingLocalOrigin() {
				return postRemoteLifecycle("resume", map[string]any{"fiber": args[0]})
			}
			path, fiberID, host := resolveFiber(args[0])
			f := readFiber(path)
			if f.Block == nil {
				return fmt.Errorf("fiber %s has no shuttle: block", args[0])
			}

			// Standing roles in awaiting/review state need special handling: just
			// enabling the fiber would leave it ineligible because the daemon's
			// StandingRole.due? rejects review.state == "awaiting". Transition to
			// scheduled with next_due_at=now so the daemon dispatches immediately.
			if f.Block.Kind == "standing" && standingInReviewState(f.Block.Review) {
				return resumeStandingFromReview(args[0], fiberID, host, f)
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

			// File a review-comment so the dispatcher's check_resume_intent/3
			// can detect resume intent. Without this event the dispatcher always
			// takes the fresh path — shuttle.session.id alone is insufficient
			// because check_resume_intent reads only the latest review-comment.
			// Mirror what the kanban's "Resume previous" button does.
			if f.Block.Session != nil && f.Block.Session.ID != "" {
				sessionID := f.Block.Session.ID
				summary := "resumed via shuttle-ctl; session " + sessionID + " available for reattach"
				_ = appendFeltHistoryReviewComment(host, fiberID, summary, "previous")
				fmt.Printf("  resume_mode: previous (session %s)\n", sessionID)
			}
			return nil
		},
	}
}

var resumeCmd = newResumeCmd()

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

func newAcceptCmd() *cobra.Command {
	var keepOutcome bool

	cmd := &cobra.Command{
		Use:   "accept <fiber>",
		Short: "Accept a completed standing-role run and advance the schedule",
		Long: `Flips shuttle.review.state to accepted/scheduled and advances next_due_at.

The run_id from the current awaiting run becomes accepted_run_id, review.state
is reset to scheduled, and next_due_at is advanced to the next occurrence.

Clears the outcome field so the next dispatch starts with a blank slate; the
worker treats an empty outcome as "previous run was accepted, write fresh" and
a non-empty outcome as "prior runs unaccepted, append below." Pass
--keep-outcome to preserve the existing outcome (rare; useful when accepting
a run whose digest the next worker should still see).

Appends a felt history event recording the acceptance.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if !usingLocalOrigin() {
				return postRemoteLifecycle("accept", map[string]any{
					"fiber":        args[0],
					"keep_outcome": keepOutcome,
				})
			}
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

			adHoc := strings.HasPrefix(runID, "adhoc-")
			next := f.Block.NextDueAt
			if !adHoc {
				// Advance next_due_at from current or now.
				from := time.Now()
				if f.Block.NextDueAt != nil {
					from = *f.Block.NextDueAt
				}
				computedNext, err := schema.NextOccurrence(f.Block.Schedule, from)
				if err != nil {
					return fmt.Errorf("computing next occurrence: %w", err)
				}
				next = &computedNext
			}

			f.Block.Review = &schema.Review{
				State:         "scheduled",
				RunID:         schema.StringPtr(runID),
				AcceptedRunID: schema.StringPtr(runID),
			}
			f.Block.NextDueAt = next
			f.Block.Enabled = true // ensure re-enabled after review

			// Clear the session block. The run we just accepted is finalized;
			// the session UUID was a handle for resuming THAT run, and any
			// subsequent dispatch (next cron tick, manual ad-hoc, kanban drag)
			// is a NEW run that should start fresh. Leaving session.id set
			// would let check_resume_intent/3 latch onto a stale UUID if a
			// prior review-comment carried `resume_mode: previous`, landing
			// the worker in a transcript whose last assistant turn was
			// "Run accepted. Exiting" — they'd idle ("nothing new on the
			// fiber") instead of running fresh. After accept, the cycle has
			// rolled over.
			f.Block.Session = nil

			// Clear outcome unless --keep-outcome. The accepted digest's signal
			// lives in the felt history event below; outcome is the live-state
			// surface and should be empty so the next worker writes fresh into it.
			if !keepOutcome {
				f.SetOutcome("")
			}

			if err := f.WriteBlock(f.Block); err != nil {
				return fmt.Errorf("writing fiber: %w", err)
			}

			// Append felt history event.
			if adHoc {
				nextText := "unchanged"
				if next != nil {
					nextText = next.Format(time.RFC3339)
				}
				_ = appendFeltHistory(host, fiberID, fmt.Sprintf("accepted ad-hoc run %s; next due %s", runID, nextText))

				fmt.Printf("accepted ad-hoc run %s for %s\n", runID, args[0])
				fmt.Printf("  next due: %s (unchanged)\n", nextText)
				return nil
			}

			_ = appendFeltHistory(host, fiberID, fmt.Sprintf("accepted run %s; next due %s", runID, next.Format(time.RFC3339)))

			fmt.Printf("accepted run %s for %s\n", runID, args[0])
			fmt.Printf("  next due: %s\n", next.Format(time.RFC3339))
			return nil
		},
	}

	cmd.Flags().BoolVar(&keepOutcome, "keep-outcome", false, "Preserve the existing outcome instead of clearing it for the next dispatch")
	return cmd
}

var acceptCmd = newAcceptCmd()

var setModelCmd = &cobra.Command{
	Use:   "set-model <fiber> <agent>",
	Short: "Change the dispatch agent for a fiber",
	Long: `Updates shuttle.agent to the given agent ID. Validates against the
agent registry before writing. Removes any existing agent:* felt tag
(the shuttle: block is now the authoritative source).`,
	Args: cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		if !usingLocalOrigin() {
			return postRemoteLifecycle("set-model", map[string]any{
				"fiber": args[0],
				"agent": args[1],
			})
		}
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
		if !usingLocalOrigin() {
			return postRemoteLifecycle("uninstall", map[string]any{"fiber": args[0]})
		}
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

// standingInReviewState returns true when a standing role's review block is in
// a state that withholds dispatch (awaiting, review, in_review). These states
// are excluded by StandingRole.due?/2 in the Elixir daemon, so simply enabling
// the fiber would leave it silently ineligible.
func standingInReviewState(review *schema.Review) bool {
	if review == nil {
		return false
	}
	s := review.State
	return s == "awaiting" || s == "review" || s == "in_review"
}

// resumeStandingFromReview re-queues a standing role that is in awaiting/review
// state for immediate dispatch without advancing the recurrence schedule.
//
// The transition is: review.state → scheduled, next_due_at → now. This makes
// StandingRole.due?/2 return true on the next daemon poll so a fresh worker is
// dispatched. The prior run's id is preserved in review.run_id for reference —
// the fresh worker can compare it to the run_id in the current outcome to
// understand it is continuing an awaiting run rather than starting a new one.
//
// Contrast with accept: accept advances next_due_at to the next cron occurrence
// and marks the run as successfully completed. Resume re-dispatches without
// advancing the schedule, intended for addressing open questions from the
// awaiting run before the next scheduled occurrence.
func resumeStandingFromReview(fiberRef, fiberID, host string, f *schema.FiberFile) error {
	priorState := f.Block.Review.State
	prevRunID := ""
	if f.Block.Review.RunID != nil {
		prevRunID = *f.Block.Review.RunID
	}

	now := time.Now().UTC()
	review := &schema.Review{State: "scheduled"}
	if prevRunID != "" {
		review.RunID = schema.StringPtr(prevRunID)
	}
	f.Block.Review = review
	f.Block.NextDueAt = &now
	f.Block.Enabled = true

	if err := f.WriteBlock(f.Block); err != nil {
		return fmt.Errorf("writing fiber: %w", err)
	}

	histSummary := fmt.Sprintf("resumed from %s state; re-queued for immediate dispatch", priorState)
	if prevRunID != "" {
		histSummary += fmt.Sprintf(" (prior run_id: %s)", prevRunID)
	}
	_ = appendFeltHistory(host, fiberID, histSummary)

	fmt.Printf("resumed %s (standing role; re-queued for immediate dispatch)\n", fiberRef)
	fmt.Printf("  review.state: %s → scheduled\n", priorState)
	fmt.Printf("  next_due_at:  %s (immediate)\n", now.Format(time.RFC3339))
	if prevRunID != "" {
		fmt.Printf("  prior run_id: %s\n", prevRunID)
	}
	fmt.Println("  note: use 'accept' to advance the recurrence instead")
	return nil
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
