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

// ownerMismatchError is returned by ensureOwnedHere when a lifecycle verb runs
// against a fiber owned by a different daemon. A distinct type so callers and
// tests can assert the guard fired rather than string-matching the message.
type ownerMismatchError struct {
	fiber, owner, own string
}

func (e ownerMismatchError) Error() string {
	return fmt.Sprintf(
		"fiber %s is owned by host %q, but this daemon is %q.\n"+
			"  Refusing to write the local git-sync mirror — that desyncs the owner's\n"+
			"  copy and resurrects on the next loom sync (single-writer-per-fiber).\n"+
			"  Run this verb on %q, or use the kanban (it routes to the owning daemon).",
		e.fiber, e.owner, e.own, e.owner)
}

// ensureOwnedHere refuses to mutate a fiber whose shuttle.host names a daemon
// other than this machine. Under loom git-sync the same fiber file exists on
// every host, so a bare `shuttle <verb>` run on the wrong machine resolves the
// LOCAL mirror and writes it — producing split-brain that only git-sync
// reconciles, lazily and sometimes wrongly (the resurrecting tempered-card bug).
// The owning daemon is the single writer; cross-host lifecycle must reach it —
// the kanban routes there, or run the verb on the owning host.
//
// Best-effort, fail-open: a host-less block (legacy, pre-"born-owned") or an
// unresolvable own-host identity falls through to a normal local write rather
// than hard-blocking. The guard closes the known mirror-write footgun; it is not
// a gate on every edit.
func ensureOwnedHere(f *schema.FiberFile, fiber string) error {
	if f == nil || f.Block == nil {
		return nil
	}
	owner := strings.TrimSpace(f.Block.Host)
	if owner == "" {
		return nil
	}
	own, err := resolveOwnHost("")
	if err != nil {
		return nil
	}
	if own = strings.TrimSpace(own); own == "" || owner == own {
		return nil
	}
	return ownerMismatchError{fiber: fiber, owner: owner, own: own}
}

func newPauseCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "pause <fiber>",
		Short: "Pause dispatch, kill any live worker, and park a fiber in drafts",
		Long: `Sets the felt-native status to "open" (the draft / paused state — the daemon
never dispatches an open fiber) while preserving the schedule, then kills the
worker tmux session if one is running. Clears tempered / closed-at so the card
lands in Drafts rather than Awaiting review.

Use --no-kill to stop scheduling only and let a live worker finish naturally.

This makes pause the single-writer transition for the Kanban's Drafts target
(status:open). There is no enabled flag (slice 5); status is the sole gate.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			noKill, err := cmd.Flags().GetBool("no-kill")
			if err != nil {
				return err
			}
			ref := resolveFiberRef(args[0])
			path := ref.Path
			f := readFiber(path)
			if f.Block == nil {
				return fmt.Errorf("fiber %s has no shuttle: block", args[0])
			}

			if err := ensureOwnedHere(f, args[0]); err != nil {
				return err
			}

			statusBefore := f.Status()
			f.SetStatus("open")
			f.SetTempered(nil)
			f.ClearClosedAt()
			if err := f.WriteBlock(f.Block); err != nil {
				return fmt.Errorf("writing fiber: %w", err)
			}
			fmt.Printf("paused %s (status: open; schedule preserved)\n", args[0])
			if statusBefore != "open" {
				fmt.Printf("  status: %s → open\n", nonEmpty(statusBefore, "(missing)"))
			}
			if statusBefore == "closed" {
				fmt.Println("  cleared: tempered, closed-at")
			}
			if noKill {
				fmt.Println("  worker: left running (--no-kill)")
				return nil
			}

			// Dual-recognition: kill whichever session form is live (a worker
			// launched before the uid-keyed cutover carries the legacy name).
			session := ""
			for _, candidate := range schema.TmuxSessionNames(ref.ID, ref.UID) {
				if tmuxSessionExists(candidate) {
					session = candidate
					break
				}
			}
			if session == "" {
				fmt.Printf("  worker: no live session %s\n", schema.TmuxSessionName(ref.ID, ref.UID))
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
		Short: "Arm a paused fiber (status: active)",
		Long: `Sets the felt-native status to "active" — the sole dispatch gate (slice 5:
no enabled flag) — so the daemon dispatches the fiber on its next poll.

For a standing role awaiting review (status: closed + untempered), resume
re-arms it for immediate dispatch and routes to the owning daemon (which clears
the awaiting marker and recomputes due-ness from the schedule). The previous
run's session id, recorded in felt history, lets the next worker resume that
transcript; this is distinct from accept, which advances the recurrence.

A draft (status: open) is armed straight to status: active. Refuses on a
tempered/composted close — use 'shuttle reopen' to requeue a finished fiber.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			path, fiberID, host := resolveFiber(args[0])
			f := readFiber(path)
			if f.Block == nil {
				return fmt.Errorf("fiber %s has no shuttle: block", args[0])
			}

			if err := ensureOwnedHere(f, args[0]); err != nil {
				return err
			}

			// A standing role awaiting review (status:closed + untempered) re-arms
			// through the owning daemon, which clears the awaiting marker and
			// recomputes due-ness from the schedule. Falls back to a local
			// document write when the daemon is unreachable.
			docAwaiting := f.Status() == "closed" && f.Tempered() == nil
			if f.Block.Kind == "standing" && docAwaiting {
				if output, err := postLifecycle("resume", map[string]any{"fiber": fiberID}); err == nil {
					fmt.Print(output)
					return nil
				} else if !isLifecycleTransportError(err) {
					return err
				}
				f.SetStatus("active")
				f.SetTempered(nil)
				f.ClearClosedAt()
				if err := f.WriteBlock(f.Block); err != nil {
					return fmt.Errorf("writing fiber: %w", err)
				}
				_ = appendFeltHistory(host, fiberID, "resumed; re-queued for immediate dispatch")
				fmt.Printf("resumed %s (standing role; re-queued for immediate dispatch)\n", args[0])
				return nil
			}

			statusBefore := f.Status()
			if statusBefore == "closed" {
				return fmt.Errorf("fiber %s has status: closed; use 'shuttle reopen %s' to clear verdict fields and requeue it", args[0], args[0])
			}
			f.SetStatus("active")
			if err := f.WriteBlock(f.Block); err != nil {
				return fmt.Errorf("writing fiber: %w", err)
			}
			fmt.Printf("resumed %s (status: active)\n", args[0])
			if statusBefore != "active" {
				if statusBefore == "" {
					fmt.Println("  status: active (set; was missing)")
				} else {
					fmt.Printf("  status: %s → active\n", statusBefore)
				}
			}

			// File a review-comment so the dispatcher's check_resume_intent/3
			// can detect resume intent. The summary is intentionally empty:
			// render_user_message_block/2 in the dispatcher suppresses the
			// "From User" prompt block when the latest review-comment has empty
			// text, so we keep the resume_mode in the payload without surfacing
			// meaningless machinery as a directive.
			//
			// Request `previous` only when felt history actually holds a
			// resumable session id (a "worker dispatched … session=<uuid>"
			// event). Arming a never-run fiber has no such session, so a
			// `previous` directive would resolve to {:error, :missing_session_id}
			// in check_resume_intent/3 and re-fail on every poll, forever (the
			// permanent-block failure mode that left morning-post stuck 5 days).
			// File `fresh` there so arming a never-run fiber dispatches fresh.
			resumeMode := "fresh"
			if latestResumableSessionID(host, fiberID) != "" {
				resumeMode = "previous"
			}
			_ = appendFeltHistoryReviewComment(host, fiberID, "", resumeMode)
			if resumeMode == "previous" {
				fmt.Println("  resume_mode: previous (session read from felt history)")
			} else {
				fmt.Println("  resume_mode: fresh (no prior session in felt history)")
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

		if err := ensureOwnedHere(f, args[0]); err != nil {
			return err
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
	Long: `Sets status = active and clears tempered / closed-at so a previously closed
card re-enters the in-flight loop. status:active is the sole dispatch gate
(slice 5: no enabled flag).

This is the canonical reopen path for Kanban requeues from Awaiting review,
Tempered, or Composted back to In flight.`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		path, _, _ := resolveFiber(args[0])
		f := readFiber(path)
		if f.Block == nil {
			return fmt.Errorf("fiber %s has no shuttle: block", args[0])
		}

		if err := ensureOwnedHere(f, args[0]); err != nil {
			return err
		}

		statusBefore := f.Status()
		f.SetStatus("active")
		f.SetTempered(nil)
		f.ClearClosedAt()
		if err := f.WriteBlock(f.Block); err != nil {
			return fmt.Errorf("writing fiber: %w", err)
		}

		fmt.Printf("reopened %s (status: active)\n", args[0])
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

			if err := ensureOwnedHere(f, args[0]); err != nil {
				return err
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
		Short: "Accept a completed standing-role run and re-arm it",
		Long: `Re-arms a standing role awaiting review (status: closed + untempered) by
writing status: active back to the document and clearing closed-at / tempered.
Due-ness is recomputed cron.next(now) by the daemon — there is no stored
next_due_at and no review block (slice 5: status + tempered is the whole
lifecycle).

Clears the outcome field so the next dispatch starts with a blank slate; the
worker treats an empty outcome as "previous run was accepted, write fresh" and
a non-empty outcome as "prior runs unaccepted, append below." Pass
--keep-outcome to preserve the existing outcome (rare; useful when accepting
a run whose digest the next worker should still see).

Routes to the owning daemon when reachable (a single in-process re-arm);
falls back to a local document write when the daemon is down. Appends a felt
history event recording the acceptance.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			path, fiberID, host := resolveFiber(args[0])
			f := readFiber(path)
			if f.Block == nil {
				return fmt.Errorf("fiber %s has no shuttle: block", args[0])
			}
			if err := ensureOwnedHere(f, args[0]); err != nil {
				return err
			}
			if f.Block.Kind != "standing" {
				return fmt.Errorf("accept only applies to standing roles (fiber has kind=%s)", f.Block.Kind)
			}
			// Awaiting is felt-native: status: closed + untempered (slice 5 — no
			// review.state axis). Accept re-arms it; the daemon's
			// LifecycleStore.accept (reached over HTTP below) does the same.
			if !(f.Status() == "closed" && f.Tempered() == nil) {
				return fmt.Errorf(
					"fiber %s is not awaiting review (accept requires status:closed + untempered; status=%q tempered=%v)",
					args[0], f.Status(), f.Tempered())
			}
			if f.Block.Schedule == nil {
				return fmt.Errorf("fiber %s has no schedule", args[0])
			}

			if output, err := postLifecycle("accept", map[string]any{
				"fiber":        fiberID,
				"keep_outcome": keepOutcome,
			}); err == nil {
				fmt.Print(output)
				return nil
			} else if !isLifecycleTransportError(err) {
				return err
			}

			// Offline fallback (daemon down). Re-arm straight from the doc
			// schedule — felt-native, no review/next_due frontmatter; the daemon
			// recomputes due-ness from the schedule on its next poll.
			computedNext, err := schema.NextOccurrence(f.Block.Schedule, time.Now())
			if err != nil {
				return fmt.Errorf("computing next occurrence: %w", err)
			}
			f.SetStatus("active")
			f.SetTempered(nil)
			f.ClearClosedAt()
			// No session block to clear: resume reads felt history, not a
			// doc-resident block (slice 6). A WriteBlock still wipes any legacy
			// `session:` key via knownShuttleKeys (clean cutover).
			if !keepOutcome {
				f.SetOutcome("")
			}
			if err := f.WriteBlock(f.Block); err != nil {
				return fmt.Errorf("writing fiber: %w", err)
			}
			_ = appendFeltHistory(host, fiberID, fmt.Sprintf("accepted run; next due %s", computedNext.Format(time.RFC3339)))
			fmt.Printf("accepted run for %s\n  next due: %s\n", args[0], computedNext.Format(time.RFC3339))
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
		agents := loadAgents()
		path, _, _ := resolveFiber(args[0])
		f := readFiber(path)
		if f.Block == nil {
			return fmt.Errorf("fiber %s has no shuttle: block (use 'shuttle repeat' to install first)", args[0])
		}

		if err := ensureOwnedHere(f, args[0]); err != nil {
			return err
		}

		agentID := args[1]
		// Resolve the new base agent together with the block's existing axes:
		// switching to an agent that can't carry the current effort/chrome fails
		// loud here rather than silently at dispatch.
		if _, _, err := agents.Resolve(agentID, f.Block.Effort, f.Block.Chrome); err != nil {
			return err
		}

		f.Block.Agent = agentID
		if err := f.WriteBlock(f.Block); err != nil {
			return fmt.Errorf("writing fiber: %w", err)
		}

		fmt.Printf("set agent for %s → %s\n", args[0], agentID)
		return nil
	},
}

var (
	setAgentEffort string
	setAgentChrome bool
)

// setAgentCmd is the axis-aware mutation verb: it composes base agent × effort ×
// chrome in one transition. set-model stays as the narrow base-agent verb; this
// is the superset (the alternative — separate set-effort/set-chrome verbs — was
// rejected to keep a single validated write that sees all three axes together).
var setAgentCmd = &cobra.Command{
	Use:   "set-agent <fiber> [agent]",
	Short: "Set the dispatch agent and/or axes (effort, chrome) for a fiber",
	Long: `Composes a fiber's dispatch axes — base agent, effort, chrome — and
writes them to the shuttle: block after validating the combination against the
agent registry's per-harness constraints (allowed effort levels, chrome
support). The base agent argument is optional: omit it to mutate only the axes
of the current agent. Pass --effort "" to clear effort back to the harness
default.`,
	Args: cobra.RangeArgs(1, 2),
	RunE: func(cmd *cobra.Command, args []string) error {
		agents := loadAgents()
		path, _, _ := resolveFiber(args[0])
		f := readFiber(path)
		if f.Block == nil {
			return fmt.Errorf("fiber %s has no shuttle: block (use 'shuttle repeat' to install first)", args[0])
		}
		if err := ensureOwnedHere(f, args[0]); err != nil {
			return err
		}

		agentID := f.Block.Agent
		if len(args) == 2 {
			agentID = args[1]
		}
		effort := f.Block.Effort
		if cmd.Flags().Changed("effort") {
			effort = setAgentEffort
		}
		chrome := f.Block.Chrome
		if cmd.Flags().Changed("chrome") {
			chrome = setAgentChrome
		}

		// Validate the full composition before writing.
		name := agentID
		if name == "" {
			if def, err := agents.Default(); err == nil {
				name = def.ID
			}
		}
		if _, _, err := agents.Resolve(name, effort, chrome); err != nil {
			return err
		}

		f.Block.Agent = agentID
		f.Block.Effort = effort
		f.Block.Chrome = chrome
		if err := f.WriteBlock(f.Block); err != nil {
			return fmt.Errorf("writing fiber: %w", err)
		}

		fmt.Printf("set agent for %s → %s", args[0], display(agentID, "(default)"))
		if effort != "" {
			fmt.Printf(" effort=%s", effort)
		}
		if chrome {
			fmt.Printf(" chrome")
		}
		fmt.Println()
		return nil
	},
}

func display(s, fallback string) string {
	if s == "" {
		return fallback
	}
	return s
}

// setInteractiveCmd is retired: interactivity is no longer a dispatch mode. It
// stays registered (hidden) so muscle-memory invocations land on a clear pointer
// rather than cobra's generic "unknown command".
var setInteractiveCmd = &cobra.Command{
	Use:    "set-interactive <fiber> <true|false>",
	Short:  "(retired) interactivity is no longer a dispatch mode",
	Hidden: true,
	Args:   cobra.ArbitraryArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		return fmt.Errorf(`set-interactive is retired: interactivity is no longer a dispatch mode.
  - Per-dispatch "talk to me first" intent goes in the From User directive
    (the kanban requeue/resume box, or a felt review-comment event).
  - Structural human-gates (2FA, send-in-his-voice) belong in the constitution
    text — the worker reads Desired State / Context and waits there.
  - To talk to any worker, finished or not, resume it from the kanban.`)
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
		if err := ensureOwnedHere(f, args[0]); err != nil {
			return err
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

func isLifecycleTransportError(err error) bool {
	if err == nil {
		return false
	}
	if _, ok := err.(lifecycleStatusError); ok {
		return false
	}
	return strings.Contains(err.Error(), "reaching daemon") ||
		strings.Contains(err.Error(), "SHUTTLE_LIFECYCLE_OFFLINE")
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
	setAgentCmd.Flags().StringVar(&setAgentEffort, "effort", "", `Effort level (harness-native token, e.g. low|medium|high|xhigh|max); "" clears`)
	setAgentCmd.Flags().BoolVar(&setAgentChrome, "chrome", false, "Enable chrome (claude harness only)")
	rootCmd.AddCommand(setAgentCmd)
	rootCmd.AddCommand(setInteractiveCmd)
	rootCmd.AddCommand(uninstallCmd)
}
