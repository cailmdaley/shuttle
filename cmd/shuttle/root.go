package main

import (
	"fmt"
	"os"

	"github.com/cailmdaley/shuttle/pkg/schema"
	"github.com/spf13/cobra"
)

var (
	jsonOutput   bool
	feltHostFlag string
)

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

Read verbs:
  status       One-line-per-fiber status overview
  ps           Live tmux worker sessions only
  snapshot     Print the local daemon's state snapshot
  dispatch     Ask the local daemon to dispatch a fiber now
  session-name Print the canonical tmux session name for a fiber
  attach       Attach to a running worker's tmux session
  validate-identity
               Validate federated fiber UID readiness across daemon feeds

To stop a running worker, use 'shuttle pause <fiber>' — it disables
dispatch and kills the live worker (use --no-kill to preserve the worker).

The CLI edits local shuttle: frontmatter directly. Cross-host writes belong to
the kanban/backend HTTP surface, not to agent-facing shuttle-ctl. All write
verbs validate input before touching any file.

Use --felt-store <dir> to target a specific felt store when a fiber does not
live under the default LOOM_HOME or ~/loom store.`,
	CompletionOptions: cobra.CompletionOptions{HiddenDefaultCmd: true},
}

func init() {
	rootCmd.PersistentFlags().BoolVarP(&jsonOutput, "json", "j", false, "Output in JSON format")
	rootCmd.PersistentFlags().StringVar(&feltHostFlag, "felt-store", "", "Felt store root (directory containing .felt/)")
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

// resolveFiber resolves a fiber ID/query to its canonical (path, id, host)
// triple; exits on error. Callers that also need the intrinsic uid (e.g. to
// compute the uid-keyed tmux session name) use resolveFiberRef.
func resolveFiber(idOrQuery string) (string, string, string) {
	ref := resolveFiberRef(idOrQuery)
	return ref.Path, ref.ID, ref.Host
}

// resolveFiberRef resolves a fiber ID/query to its full canonical reference
// (path, id, uid, host); exits on error. The uid keys the rename-safe tmux
// session name.
func resolveFiberRef(idOrQuery string) *schema.FiberRef {
	host := feltHostFlag
	if host == "" {
		defaultStore, err := schema.FeltStore()
		if err != nil {
			fmt.Fprintf(os.Stderr, "shuttle: %v\n", err)
			os.Exit(1)
		}
		host = defaultStore
	}

	ref, err := schema.ResolveFiberInHost(host, idOrQuery)
	if err != nil {
		fmt.Fprintf(os.Stderr, "shuttle: %v\n", err)
		os.Exit(1)
	}
	return ref
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
