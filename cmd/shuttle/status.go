package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"

	"github.com/cailmdaley/shuttle-cli/pkg/schema"
	"github.com/spf13/cobra"
)

var statusAll bool

// FiberStatus is one row in the status output.
type FiberStatus struct {
	FiberID     string `json:"fiber_id"`
	Kind        string `json:"kind"`
	Enabled     bool   `json:"enabled"`
	Agent       string `json:"agent,omitempty"`
	State       string `json:"state"`
	Running     bool   `json:"running"`
	Session     string `json:"session,omitempty"`
	NextDueAt   string `json:"next_due_at,omitempty"`
	LastRunAt   string `json:"last_run_at,omitempty"`
	ReviewState string `json:"review_state,omitempty"`
}

var statusCmd = &cobra.Command{
	Use:   "status",
	Short: "One-line-per-fiber status overview",
	Long: `Prints one line per fiber that has a shuttle: block.
Sources: felt ls -j (for fibers with shuttle: blocks) + tmux ls (for live sessions).

Columns: fiber_id  kind  state  agent  next_due_at

--all includes recently-exited sessions that no longer have shuttle: blocks.
--json emits an array of objects instead.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		host := feltHostFlag
		if host == "" {
			defaultHost, err := schema.FeltHost()
			if err != nil {
				return err
			}
			host = defaultHost
		}

		// Read fibers through felt's JSON surface; shuttle remains the sole
		// owner of shuttle-block semantics, felt remains the sole reader.
		shuttleFibers, err := listShuttleFibers(host)
		if err != nil {
			return fmt.Errorf("listing fibers: %w", err)
		}

		// List live tmux sessions.
		liveSessions := liveTmuxSessions()

		// Build status rows.
		rows := make([]FiberStatus, 0, len(shuttleFibers))
		seenSessions := map[string]bool{}

		for _, entry := range shuttleFibers {
			session := schema.TmuxSessionName(entry.FiberID)
			live := liveSessions[session]
			seenSessions[session] = true

			state := computeState(entry.Block, live)

			row := FiberStatus{
				FiberID: entry.FiberID,
				Kind:    entry.Block.Kind,
				Enabled: entry.Block.Enabled,
				Agent:   entry.Block.Agent,
				State:   state,
				Running: live,
				Session: session,
			}
			if entry.Block.NextDueAt != nil {
				row.NextDueAt = entry.Block.NextDueAt.Format(time.RFC3339)
			}
			if entry.Block.LastRunAt != nil {
				row.LastRunAt = entry.Block.LastRunAt.Format(time.RFC3339)
			}
			if entry.Block.Review != nil {
				row.ReviewState = entry.Block.Review.State
			}
			rows = append(rows, row)
		}

		// Optionally include live sessions not matched to a shuttle: fiber.
		if statusAll {
			for session := range liveSessions {
				if !seenSessions[session] {
					rows = append(rows, FiberStatus{
						FiberID: strings.TrimPrefix(session, "shuttle-"),
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
	Long:  "Prints one line per live shuttle-* tmux session.",
	RunE: func(cmd *cobra.Command, args []string) error {
		live := liveTmuxSessions()
		if len(live) == 0 {
			fmt.Println("no live shuttle workers")
			return nil
		}

		type row struct{ session, fiberID string }
		rows := make([]row, 0, len(live))
		for session := range live {
			fiberID := strings.TrimPrefix(session, "shuttle-")
			rows = append(rows, row{session, fiberID})
		}
		sort.Slice(rows, func(i, j int) bool { return rows[i].session < rows[j].session })

		if jsonOutput {
			out := make([]map[string]string, len(rows))
			for i, r := range rows {
				out[i] = map[string]string{"session": r.session, "fiber_id": r.fiberID}
			}
			enc := json.NewEncoder(os.Stdout)
			enc.SetIndent("", "  ")
			return enc.Encode(out)
		}

		for _, r := range rows {
			fmt.Printf("%-40s  %s\n", r.session, r.fiberID)
		}
		return nil
	},
}

// ---- helpers ---------------------------------------------------------------

type shuttleEntry struct {
	FiberID string
	Block   *schema.Block
}

// listShuttleFibers reads every fiber through `felt ls -s all --json` and
// keeps the entries that carry a shuttle block.
func listShuttleFibers(host string) ([]shuttleEntry, error) {
	out, err := exec.Command("felt", "-C", host, "ls", "-s", "all", "--json").Output()
	if err != nil {
		return nil, fmt.Errorf("felt ls: %w", err)
	}

	var raw []struct {
		FiberID string          `json:"id"`
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
		ref, err := schema.ResolveFiberInHost(host, fiber.FiberID)
		if err != nil {
			continue
		}
		if seen[ref.ID] {
			continue
		}
		seen[ref.ID] = true
		entries = append(entries, shuttleEntry{FiberID: ref.ID, Block: &block})
	}
	return entries, nil
}

// liveTmuxSessions returns a set of tmux session names that start with "shuttle-".
func liveTmuxSessions() map[string]bool {
	out, err := exec.Command("tmux", "ls", "-F", "#{session_name}").Output()
	if err != nil {
		return map[string]bool{}
	}
	result := map[string]bool{}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "shuttle-") {
			result[line] = true
		}
	}
	return result
}

func computeState(b *schema.Block, running bool) string {
	if running {
		return "running"
	}
	if !b.Enabled {
		return "paused"
	}
	if b.Review != nil && b.Review.State != "" {
		switch b.Review.State {
		case "awaiting":
			return "awaiting-review"
		case "aborted":
			return "aborted"
		case "accepted":
			return "accepted"
		}
	}
	if b.Kind == "standing" {
		if b.NextDueAt != nil && b.NextDueAt.Before(time.Now()) {
			return "due"
		}
		return "scheduled"
	}
	return "idle"
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
	statusCmd.Flags().BoolVar(&statusAll, "all", false, "Include exited sessions not matched to a fiber")
	rootCmd.AddCommand(statusCmd)
	rootCmd.AddCommand(psCmd)
}
