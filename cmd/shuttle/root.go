package main

import (
	"fmt"
	"os"

	"github.com/cailmdaley/shuttle-cli/pkg/schema"
	"github.com/spf13/cobra"
)

var jsonOutput bool

var rootCmd = &cobra.Command{
	Use:           "shuttle",
	Short:         "Shuttle CLI — schema-validating agent tool for fiber dispatch",
	SilenceUsage:  true, // don't show usage on every error
	SilenceErrors: true, // we print errors ourselves in main()
	Long: `shuttle manages the shuttle: frontmatter block that drives fiber dispatch.

Write verbs (offline, validate-before-write):
  install      Install a fiber as a one-shot dispatch role
  repeat       Install a fiber as a standing (recurring) role
  pause        Pause dispatch and park a fiber in drafts
  resume       Resume a paused, still-open fiber
  reopen       Requeue a closed fiber back into active work
  close        Close a fiber and optionally set tempered=true|false
  set-outcome  Set the outcome field on a shuttle-managed fiber
  accept       Accept a completed standing-role run and advance the schedule
  set-model    Change the agent for a fiber
  uninstall    Remove the shuttle: block from a fiber

Read + abort verbs (offline, no daemon IPC):
  status       One-line-per-fiber status overview
  ps           Live tmux worker sessions only
  session-name Print the canonical tmux session name for a fiber
  attach       Attach to a running worker's tmux session
  abort        Kill a worker's tmux session

The CLI edits shuttle: frontmatter directly. The running daemon picks up changes
on its next poll. All write verbs validate input before touching any file.`,
	CompletionOptions: cobra.CompletionOptions{HiddenDefaultCmd: true},
}

func init() {
	rootCmd.PersistentFlags().BoolVarP(&jsonOutput, "json", "j", false, "Output in JSON format")
}

// loadAgents loads the agent registry; exits with a clear error on failure.
func loadAgents() *schema.AgentRegistry {
	reg, err := schema.LoadAgentRegistry()
	if err != nil {
		fmt.Fprintf(os.Stderr, "shuttle: cannot load agent registry: %v\n", err)
		os.Exit(1)
	}
	return reg
}

// resolveFiber resolves a fiber ID/query to its file path; exits on error.
func resolveFiber(idOrQuery string) (string, string) {
	path, err := schema.ResolveFiberPath(idOrQuery)
	if err != nil {
		fmt.Fprintf(os.Stderr, "shuttle: %v\n", err)
		os.Exit(1)
	}
	host, _ := schema.FeltHost()
	fiberID, err := schema.FiberIDFromPath(host, path)
	if err != nil {
		fiberID = idOrQuery
	}
	return path, fiberID
}

// readFiber reads a fiber; exits on error.
func readFiber(path string) *schema.FiberFile {
	f, err := schema.ReadFiber(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "shuttle: reading fiber: %v\n", err)
		os.Exit(1)
	}
	return f
}

// validateAndExit validates a block; exits nonzero with messages on failure.
// agents may be nil to skip agent-name validation.
func validateAndExit(b *schema.Block, agents *schema.AgentRegistry) {
	errs := schema.Validate(b, agents)
	if len(errs) == 0 {
		return
	}
	fmt.Fprintln(os.Stderr, "shuttle: validation failed:")
	for _, e := range errs {
		fmt.Fprintf(os.Stderr, "  %s\n", e)
	}
	os.Exit(1)
}

// writeBlock validates then writes; exits on error.
func writeBlock(f *schema.FiberFile, block *schema.Block, agents *schema.AgentRegistry) {
	if block != nil {
		validateAndExit(block, agents)
	}
	if err := f.WriteBlock(block); err != nil {
		fmt.Fprintf(os.Stderr, "shuttle: writing fiber: %v\n", err)
		os.Exit(1)
	}
}
