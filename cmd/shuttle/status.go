package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"

	"github.com/cailmdaley/shuttle/pkg/schema"
	"github.com/spf13/cobra"
)

var (
	statusIncludeOrphans bool
	statusAll            bool
	statusRemote         string
)

// FiberStatus is one row in the status output.
//
// Origin is empty for local rows; for cross-host rows (rendered via
// `--remote` or `--all`) it carries the remote name (e.g. "candide")
// — so JSON consumers can group/filter without re-deriving it.
type FiberStatus struct {
	FiberID   string `json:"fiber_id"`
	Origin    string `json:"origin,omitempty"`
	Kind      string `json:"kind,omitempty"`
	Agent     string `json:"agent,omitempty"`
	State     string `json:"state"`
	Running   bool   `json:"running"`
	Session   string `json:"session,omitempty"`
	NextDueAt string `json:"next_due_at,omitempty"`
	LastRunAt string `json:"last_run_at,omitempty"`
	Stale     bool   `json:"stale,omitempty"`
}

var statusCmd = &cobra.Command{
	Use:   "status",
	Short: "One-line-per-fiber status overview",
	Long: `Prints one line per fiber that has a shuttle: block.
Sources: projected felt ls -j (for fibers with shuttle: blocks) + tmux ls (for live sessions).

Columns: fiber_id  kind  state  agent  next_due_at

Cross-host (queries the local daemon's /api/v1/state/composite):
  --all           local + every configured remote (composite snapshot).
  --remote NAME   only the named remote.

The daemon's RemoteRegistry polls each remote over its SSH-tunnel-mapped
port; the CLI just renders that response. Rows from a remote include an
"origin" column. Stale remotes (registry hasn't heard back recently) are
flagged with "[stale]" in the state column.

Other flags:
  --include-orphans  include live Shuttle tmux sessions that no longer
                     map cleanly to a shuttle: block (rare; useful for
                     reconciling after manual cleanup).
  --json             emit an array of objects instead.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		// Cross-host paths route through the local daemon; --remote and
		// --all are mutually exclusive (--remote NAME implies "filter").
		if statusAll || statusRemote != "" {
			return runStatusCrossHost()
		}

		hosts, err := statusHosts()
		if err != nil {
			return err
		}

		// Read fibers through felt's JSON surface across every host; shuttle
		// remains the sole owner of shuttle-block semantics, felt remains the
		// sole reader. A fiber visible from multiple hosts (e.g. via a felt
		// symlink into a project-canonical store) canonicalizes to one
		// FiberRef.ID, so cross-host dedup is on that key.
		shuttleFibers, err := listShuttleFibersAcrossHosts(hosts)
		if err != nil {
			return fmt.Errorf("listing fibers: %w", err)
		}

		// List live tmux sessions.
		liveSessions := liveTmuxSessions()
		sessionOwners := sessionOwnerMap(shuttleFibers)

		// Build status rows.
		rows := make([]FiberStatus, 0, len(shuttleFibers))
		seenSessions := map[string]bool{}

		for _, entry := range shuttleFibers {
			// The canonical (uid-keyed) name is the row's display session, but
			// liveness recognizes either name form so a worker launched before
			// the uid-keyed cutover still reads as running.
			session := schema.TmuxSessionName(entry.FiberID, entry.UID)
			live := false
			for _, candidate := range schema.TmuxSessionNames(entry.FiberID, entry.UID) {
				if liveSessions[candidate] && sessionOwners[candidate] == entry.FiberID {
					live = true
					session = candidate
					seenSessions[candidate] = true
					break
				}
			}

			state := computeState(entry.Block, entry.Status, live)

			row := FiberStatus{
				FiberID: entry.FiberID,
				Kind:    entry.Block.Kind,
				Agent:   entry.Block.Agent,
				State:   state,
				Running: live,
				Session: session,
			}
			rows = append(rows, row)
		}

		// Optionally include live sessions not matched to a shuttle: fiber.
		if statusIncludeOrphans {
			for session := range liveSessions {
				if !seenSessions[session] {
					rows = append(rows, FiberStatus{
						FiberID: session,
						State:   "running",
						Running: true,
						Session: session,
					})
				}
			}
		}

		sort.Slice(rows, func(i, j int) bool { return rows[i].FiberID < rows[j].FiberID })

		if jsonOutput {
			enc := json.NewEncoder(os.Stdout)
			enc.SetIndent("", "  ")
			return enc.Encode(rows)
		}

		printStatusTable(rows)
		return nil
	},
}

var psCmd = &cobra.Command{
	Use:   "ps",
	Short: "Live tmux worker sessions",
	Long:  "Prints one line per live Shuttle tmux session.",
	RunE: func(cmd *cobra.Command, args []string) error {
		live := liveTmuxSessions()
		if len(live) == 0 {
			fmt.Println("no live shuttle workers")
			return nil
		}

		hosts, err := statusHosts()
		if err != nil {
			return err
		}
		owners := map[string]string{}
		if shuttleFibers, err := listShuttleFibersAcrossHosts(hosts); err == nil {
			owners = sessionOwnerMap(shuttleFibers)
		}

		type row struct{ session, fiberID string }
		rows := make([]row, 0, len(live))
		for session := range live {
			rows = append(rows, row{session: session, fiberID: owners[session]})
		}
		sort.Slice(rows, func(i, j int) bool { return rows[i].session < rows[j].session })

		if jsonOutput {
			out := make([]map[string]string, len(rows))
			for i, r := range rows {
				row := map[string]string{"session": r.session}
				if r.fiberID != "" {
					row["fiber_id"] = r.fiberID
				}
				out[i] = row
			}
			enc := json.NewEncoder(os.Stdout)
			enc.SetIndent("", "  ")
			return enc.Encode(out)
		}

		for _, r := range rows {
			if r.fiberID != "" {
				fmt.Printf("%-40s  %s\n", r.session, r.fiberID)
			} else {
				fmt.Println(r.session)
			}
		}
		return nil
	},
}

// ---- helpers ---------------------------------------------------------------

type shuttleEntry struct {
	FiberID string
	UID     string
	Status  string
	Block   *schema.Block
}

// listShuttleFibersAcrossHosts queries each host with listShuttleFibers and
// merges the results, deduplicating by canonical FiberRef.ID. A host failure
// is non-fatal: we log to stderr and continue with the rest, matching the
// daemon's per-host best-effort scan.
func listShuttleFibersAcrossHosts(hosts []string) ([]shuttleEntry, error) {
	if len(hosts) == 0 {
		return nil, fmt.Errorf("no felt stores configured")
	}
	merged := make([]shuttleEntry, 0)
	seen := map[string]bool{}
	var firstErr error
	for _, host := range hosts {
		entries, err := listShuttleFibers(host)
		if err != nil {
			fmt.Fprintf(os.Stderr, "shuttle: host %q: %v\n", host, err)
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		for _, e := range entries {
			if seen[e.FiberID] {
				continue
			}
			seen[e.FiberID] = true
			merged = append(merged, e)
		}
	}
	// All hosts failed → surface the first error so the operator notices;
	// any successful host means we have data, return it.
	if len(merged) == 0 && firstErr != nil {
		return nil, firstErr
	}
	return merged, nil
}

// listShuttleFibers reads a narrow projected felt listing and keeps the entries
// that carry a shuttle block.
func listShuttleFibers(host string) ([]shuttleEntry, error) {
	out, err := projectedShuttleFiberListing(host)
	if err != nil {
		out, err = exec.Command("felt", "-C", host, "ls", "-s", "all", "--json").Output()
	}
	if err != nil {
		return nil, fmt.Errorf("felt ls: %w", err)
	}

	var raw []struct {
		FiberID string          `json:"id"`
		UID     string          `json:"uid"`
		Status  string          `json:"status"`
		Path    string          `json:"path"`
		Shuttle json.RawMessage `json:"shuttle"`
	}
	if err := json.Unmarshal(out, &raw); err != nil {
		return nil, fmt.Errorf("parsing felt ls JSON: %w", err)
	}

	entries := make([]shuttleEntry, 0, len(raw))
	seen := map[string]bool{}
	for _, fiber := range raw {
		if fiber.FiberID == "" || len(fiber.Shuttle) == 0 || string(fiber.Shuttle) == "null" {
			continue
		}
		var block schema.Block
		if err := json.Unmarshal(fiber.Shuttle, &block); err != nil {
			continue
		}
		// felt carries the physical path in the bulk listing; canonicalize from
		// it directly (symlink-resolve, re-derive store + id from the real
		// .felt/ root) instead of a per-fiber resolution round-trip.
		id := fiber.FiberID
		if fiber.Path != "" {
			if _, canonical, err := schema.FiberRefFromPath(fiber.Path); err == nil {
				id = canonical
			}
		}
		if seen[id] {
			continue
		}
		seen[id] = true
		entries = append(entries, shuttleEntry{FiberID: id, UID: fiber.UID, Status: fiber.Status, Block: &block})
	}
	return entries, nil
}

// projectedShuttleFiberListing requests the full felt record (no `--json-field`
// projection) so felt's carried `path` survives — the projector cannot emit
// `path`, which is injected at the read chokepoint, not a frontmatter field.
func projectedShuttleFiberListing(host string) ([]byte, error) {
	return exec.Command(
		"felt",
		"-C", host,
		"ls",
		"-s", "all",
		"--json",
		"--has-field", "shuttle",
	).Output()
}

func statusHosts() ([]string, error) {
	if feltHostFlag != "" {
		return []string{feltHostFlag}, nil
	}
	return schema.FeltStores()
}

// sessionOwnerMap maps every session-name form a fiber could carry — both the
// uid-keyed canonical name and the legacy leaf-only name — back to its fiber.
// The uid-keyed names are collision-free; the legacy leaf-only names keep the
// existing collision guard (two open fibers sharing a leaf drop out of the map
// rather than mis-attributing a live worker).
func sessionOwnerMap(entries []shuttleEntry) map[string]string {
	owners := map[string]string{}
	collisions := map[string]bool{}
	for _, entry := range entries {
		if entry.Status == "closed" {
			continue
		}
		for _, session := range schema.TmuxSessionNames(entry.FiberID, entry.UID) {
			if existing, ok := owners[session]; ok && existing != entry.FiberID {
				delete(owners, session)
				collisions[session] = true
				continue
			}
			if !collisions[session] {
				owners[session] = entry.FiberID
			}
		}
	}
	return owners
}

// liveTmuxSessions returns a set of live Shuttle tmux session names.
func liveTmuxSessions() map[string]bool {
	out, err := exec.Command("tmux", "ls", "-F", "#{session_name}").Output()
	if err != nil {
		return map[string]bool{}
	}
	result := map[string]bool{}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		line = strings.TrimSpace(line)
		if schema.IsTmuxSessionName(line) {
			result[line] = true
		}
	}
	return result
}

// computeState derives the display state from tmux liveness and the felt-native
// status — the sole lifecycle axis (slice 5: no enabled flag, no review state).
// "awaiting/accepted/composted" are status:closed facts; the closed-state
// verdict (tempered) is a fiber field the bulk listing here doesn't carry, so
// closed collapses to "closed" — the kanban (which has tempered) makes the
// finer call.
func computeState(b *schema.Block, status string, running bool) string {
	if running {
		return "running"
	}
	switch status {
	case "open":
		return "paused"
	case "closed":
		return "closed"
	case "active":
		if b.Kind == "standing" {
			return "scheduled"
		}
		return "idle"
	default:
		return nonEmpty(status, "unknown")
	}
}

func printStatusTable(rows []FiberStatus) {
	if len(rows) == 0 {
		fmt.Println("no shuttle fibers")
		return
	}
	fmt.Printf("%-50s  %-9s  %-14s  %-18s  %s\n",
		"FIBER", "KIND", "STATE", "NEXT_DUE_AT", "AGENT")
	fmt.Println(strings.Repeat("─", 110))
	for _, r := range rows {
		agent := r.Agent
		if agent == "" {
			agent = "(default)"
		}
		next := r.NextDueAt
		if next == "" {
			next = "-"
		}
		fmt.Printf("%-50s  %-9s  %-14s  %-18s  %s\n",
			truncate(r.FiberID, 50), r.Kind, r.State, next, agent)
	}
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return "…" + s[len(s)-(n-1):]
}

func init() {
	statusCmd.Flags().BoolVar(&statusIncludeOrphans, "include-orphans", false,
		"Include live Shuttle tmux sessions with no matching shuttle block")
	statusCmd.Flags().BoolVar(&statusAll, "all", false,
		"Show local plus all configured remotes (queries daemon /api/v1/state/composite)")
	statusCmd.Flags().StringVar(&statusRemote, "remote", "",
		"Show only the named remote (queries daemon /api/v1/state/composite)")
	statusCmd.MarkFlagsMutuallyExclusive("all", "remote")
	rootCmd.AddCommand(statusCmd)
	rootCmd.AddCommand(psCmd)
}
