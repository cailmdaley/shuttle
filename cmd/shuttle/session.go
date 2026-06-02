package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/cailmdaley/shuttle/pkg/schema"
	"github.com/spf13/cobra"
)

func newSessionSetCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "session-set <fiber> <session-uuid>",
		Short: "Store the worker session UUID in the shuttle block (daemon-owned)",
		Long: `Record the session UUID from a just-dispatched worker in the fiber's
shuttle: block. This is called by the Shuttle Elixir daemon after a successful
tmux spawn, not by users directly.

The UUID is used to resume the previous worker session when the user clicks
"Resume previous" on an awaiting-review Kanban card.

  shuttle session-set <fiber> <uuid>                  # store UUID
  shuttle session-set <fiber> <uuid> --agent claude-sonnet   # with agent name

The session field is daemon-owned: it is preserved through user lifecycle
operations (pause, resume, set-model) and replaced on each new dispatch.`,
		Args: cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			agentName, _ := cmd.Flags().GetString("agent")
			if output, err := postSession("set", map[string]any{
				"fiber":      args[0],
				"session_id": args[1],
				"agent":      agentName,
			}); err == nil {
				fmt.Print(output)
				return nil
			} else if !isSessionTransportError(err) {
				return err
			}

			path, _, _ := resolveFiber(args[0])
			f := readFiber(path)
			if f.Block == nil {
				return fmt.Errorf("fiber %s has no shuttle: block", args[0])
			}
			now := time.Now().UTC()
			f.Block.Session = &schema.Session{
				ID:           args[1],
				Agent:        agentName,
				DispatchedAt: now,
			}
			// Write directly — no validation needed. The block was already valid
			// when installed; session is daemon-owned and not user-validated.
			if err := f.WriteBlock(f.Block); err != nil {
				return fmt.Errorf("writing fiber: %w", err)
			}
			fmt.Printf("session %s stored for %s\n", args[1], args[0])
			return nil
		},
	}
	cmd.Flags().String("agent", "", "Agent ID used for this session (e.g. claude-sonnet)")
	return cmd
}

func newSessionClearCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "session-clear <fiber>",
		Short: "Clear the stored session UUID from the shuttle block",
		Long: `Remove the session field from the fiber's shuttle: block. Called when
a fiber moves to tempered/composted or when a session has aged out and
resume is no longer meaningful.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if output, err := postSession("clear", map[string]any{"fiber": args[0]}); err == nil {
				fmt.Print(output)
				return nil
			} else if !isSessionTransportError(err) {
				return err
			}

			path, _, _ := resolveFiber(args[0])
			f := readFiber(path)
			if f.Block == nil {
				return fmt.Errorf("fiber %s has no shuttle: block", args[0])
			}
			if f.Block.Session == nil {
				fmt.Printf("%s has no session to clear\n", args[0])
				return nil
			}
			f.Block.Session = nil
			if err := f.WriteBlock(f.Block); err != nil {
				return fmt.Errorf("writing fiber: %w", err)
			}
			fmt.Printf("session cleared for %s\n", args[0])
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

func isSessionTransportError(err error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(err.Error(), "reaching daemon") ||
		strings.Contains(err.Error(), "SHUTTLE_SESSION_OFFLINE")
}
