package main

import (
	"fmt"

	"github.com/spf13/cobra"
)

func newSessionSetCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "session-set <fiber> <session-uuid>",
		Short: "Store the worker session UUID in the daemon runtime store",
		Long: `Record the session UUID from a just-dispatched worker in the owning
daemon's host-local runtime store. This is called by the Shuttle Elixir daemon
after a successful tmux spawn, not by users directly.

The UUID is used to resume the previous worker session when the user clicks
"Resume previous" on an awaiting-review Kanban card.

  shuttle session-set <fiber> <uuid>                  # store UUID
  shuttle session-set <fiber> <uuid> --agent claude-sonnet   # with agent name

The session handle is daemon-owned runtime state. It must not be written into
the synced fiber frontmatter.`,
		Args: cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			agentName, _ := cmd.Flags().GetString("agent")
			output, err := postSession("set", map[string]any{
				"fiber":      args[0],
				"session_id": args[1],
				"agent":      agentName,
			})
			if err != nil {
				return err
			}
			fmt.Print(output)
			return nil
		},
	}
	cmd.Flags().String("agent", "", "Agent ID used for this session (e.g. claude-sonnet)")
	return cmd
}

func newSessionClearCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "session-clear <fiber>",
		Short: "Clear the stored session UUID from the daemon runtime store",
		Long: `Remove the session handle from the owning daemon's host-local runtime
store. Called when a fiber moves to tempered/composted or when a session has
aged out and resume is no longer meaningful.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			output, err := postSession("clear", map[string]any{"fiber": args[0]})
			if err != nil {
				return err
			}
			fmt.Print(output)
			return nil
		},
	}
}

var sessionSetCmd = newSessionSetCmd()
var sessionClearCmd = newSessionClearCmd()

func init() {
	rootCmd.AddCommand(sessionSetCmd)
	rootCmd.AddCommand(sessionClearCmd)
}
