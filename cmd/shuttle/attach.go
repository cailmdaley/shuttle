package main

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"

	"github.com/cailmdaley/shuttle/pkg/schema"
	"github.com/spf13/cobra"
)

var tmuxSessionExists = schema.TmuxSessionExists

var killTmuxSession = func(session string) error {
	return exec.Command("tmux", "kill-session", "-t", session).Run()
}

var attachCmd = &cobra.Command{
	Use:   "attach <fiber>",
	Short: "Attach to a running worker's tmux session",
	Long: `Convenience wrapper for: tmux attach -t shuttle-<fiber-id>

Resolves the fiber ID to Shuttle's canonical tmux session name and executes
tmux attach. Exits with a clear error if no session exists.`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		_, fiberID, _ := resolveFiber(args[0])
		session := schema.TmuxSessionName(fiberID)

		if !tmuxSessionExists(session) {
			return fmt.Errorf("no tmux session %q — fiber %s has no live worker\n(run 'shuttle ps' to list active workers)", session, args[0])
		}

		tmux, err := exec.LookPath("tmux")
		if err != nil {
			return fmt.Errorf("tmux not found: %w", err)
		}

		// Replace the current process with tmux attach (exec).
		return syscall.Exec(tmux, []string{"tmux", "attach", "-t", session}, os.Environ())
	},
}

var abortCmd = &cobra.Command{
	Use:   "abort <fiber>",
	Short: "Kill a running worker's tmux session",
	Long: `Kills the tmux session for the fiber's worker and marks the shuttle: block
with review.state=aborted so the daemon distinguishes user-abort from a crash.

The daemon's GenServer watcher observes the session disappearing on its next
watcher tick and reconciles: marks the run as aborted, appends history, releases
supervision.`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		path, fiberID, _ := resolveFiber(args[0])
		session := schema.TmuxSessionName(fiberID)

		// Mark the block BEFORE killing the session so the daemon can distinguish
		// user-abort from crash when it reconciles on the next watcher tick.
		f := readFiber(path)
		if f.Block != nil {
			if f.Block.Review == nil {
				f.Block.Review = &schema.Review{}
			}
			f.Block.Review.State = "aborted"
			if err := f.WriteBlock(f.Block); err != nil {
				return fmt.Errorf("writing abort marker: %w", err)
			}
		}

		if !tmuxSessionExists(session) {
			fmt.Printf("no live session %q — abort marker written, nothing to kill\n", session)
			return nil
		}

		if err := killTmuxSession(session); err != nil {
			return fmt.Errorf("killing tmux session %q: %w", session, err)
		}

		fmt.Printf("aborted %s (killed session %s; daemon will reconcile on next tick)\n", args[0], session)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(attachCmd)
	rootCmd.AddCommand(abortCmd)
}
