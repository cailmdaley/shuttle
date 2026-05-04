package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/cailmdaley/shuttle-cli/pkg/schema"
	"github.com/spf13/cobra"
)

var sessionNameCmd = &cobra.Command{
	Use:   "session-name <fiber>",
	Short: "Print the canonical tmux session name for a fiber",
	Long: `Resolves the fiber to its canonical fiber ID and prints the tmux session
name Shuttle uses for the worker (shuttle-<fiber-id>).`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		_, fiberID := resolveFiber(args[0])
		session := schema.TmuxSessionName(fiberID)

		if jsonOutput {
			payload := map[string]string{"fiber_id": fiberID, "session": session}
			enc := json.NewEncoder(os.Stdout)
			enc.SetIndent("", "  ")
			return enc.Encode(payload)
		}

		fmt.Println(session)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(sessionNameCmd)
}
