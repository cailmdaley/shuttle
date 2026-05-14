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
	Long: `Convenience wrapper for: tmux attach -t <leaf>-shuttle

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

func init() {
	rootCmd.AddCommand(attachCmd)
}
