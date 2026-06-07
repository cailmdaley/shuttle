package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/cailmdaley/shuttle/pkg/schema"
	"github.com/spf13/cobra"
)

var sessionNameCmd = &cobra.Command{
	Use:   "session-name <fiber>",
	Short: "Print the canonical tmux session name for a fiber",
	Long: `Resolves the fiber to its canonical fiber ID and prints the tmux session
name Shuttle uses for the worker (<leaf>-<uid>-shuttle).`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ref := resolveFiberRef(args[0])
		fiberID := ref.ID
		session := schema.TmuxSessionName(fiberID, ref.UID)

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
