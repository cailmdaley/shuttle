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
		ref := resolveFiberRef(args[0])

		// Dual-recognition: a worker may be live under either the uid-keyed
		// name or the legacy leaf-only name. Attach to whichever exists,
		// preferring the uid-keyed canonical form.
		session := ""
		for _, candidate := range schema.TmuxSessionNames(ref.ID, ref.UID) {
			if tmuxSessionExists(candidate) {
				session = candidate
				break
			}
		}

		if session == "" {
			want := schema.TmuxSessionName(ref.ID, ref.UID)
			return fmt.Errorf("no tmux session %q — fiber %s has no live worker\n(run 'shuttle ps' to list active workers)", want, args[0])
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
