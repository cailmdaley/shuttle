package main

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"

	"github.com/cailmdaley/shuttle-cli/pkg/schema"
	"github.com/spf13/cobra"
)

var migrateDryRun bool

var migrateCmd = &cobra.Command{
	Use:   "migrate",
	Short: "Add shuttle: blocks to currently-eligible constitution fibers",
	Long: `Walks the loom and adds shuttle.enabled=true / shuttle.kind=oneshot to every
fiber that has the 'constitution' tag and not the 'draft' tag — the pre-CLI
eligibility predicate. After migration the daemon switches to reading
shuttle.enabled instead of tag predicates.

Migration is idempotent: fibers that already have shuttle: blocks are skipped
(or have enabled/kind fields filled in if missing).

  shuttle migrate [--dry-run]

Pre-flight check: run with --dry-run to see what would change.

For existing standing roles (shuttle.mode=standing), the script:
  - Renames mode → kind
  - Renames schedule.timezone → schedule.tz
  - Adds enabled: true
  - Translates agent:<name> felt tag → shuttle.agent and removes the tag

The eligibility cutover (daemon + kanban) is a separate step coordinated
by the operator after verifying migration output.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		host, err := schema.FeltHost()
		if err != nil {
			return err
		}

		// Get candidates: felt ls -t constitution -j -s all
		candidates, err := runFeltLS(host)
		if err != nil {
			return fmt.Errorf("listing constitution fibers: %w", err)
		}

		var changed, skipped, errors int

		for _, candidate := range candidates {
			fiberID, _ := candidate["id"].(string)
			if fiberID == "" {
				continue
			}
			tags := extractTagsFromRecord(candidate)

			// Pre-CLI eligibility: constitution tag + not draft tag
			if !contains(tags, "constitution") || contains(tags, "draft") {
				continue
			}

			mdPath, err := schema.ResolveFiberPath(fiberID)
			if err != nil {
				fmt.Fprintf(cmd.ErrOrStderr(), "  skip %s: cannot resolve path: %v\n", fiberID, err)
				skipped++
				continue
			}

			f, err := schema.ReadFiber(mdPath)
			if err != nil {
				fmt.Fprintf(cmd.ErrOrStderr(), "  skip %s: cannot read: %v\n", fiberID, err)
				skipped++
				continue
			}

			block, action := upgradeFiber(f, tags)
			if action == "skip" {
				skipped++
				continue
			}

			fmt.Printf("  %-6s %s\n", action, fiberID)
			if block.Agent != "" {
				fmt.Printf("         agent: %s\n", block.Agent)
			}

			if migrateDryRun {
				changed++
				continue
			}

			if err := f.WriteBlock(block); err != nil {
				fmt.Fprintf(cmd.ErrOrStderr(), "  ERROR writing %s: %v\n", fiberID, err)
				errors++
				continue
			}

			// If we translated an agent:<name> tag, remove it via felt edit.
			if agentTag := extractAgentTag(tags); agentTag != "" && block.Agent != "" {
				removeAgentTag(host, fiberID, agentTag)
			}
			changed++
		}

		qualifier := ""
		if migrateDryRun {
			qualifier = " (dry run)"
		}
		fmt.Printf("\nmigration%s: %d changed, %d skipped, %d errors\n",
			qualifier, changed, skipped, errors)

		if errors > 0 {
			return fmt.Errorf("migration completed with %d errors", errors)
		}
		return nil
	},
}

// upgradeFiber determines what changes to make to a fiber and returns the
// new block plus an action string ("add", "upgrade", "skip").
func upgradeFiber(f *schema.FiberFile, tags []string) (*schema.Block, string) {
	existing := f.Block

	if existing != nil {
		// Already has shuttle: block. Fill in any missing new fields.
		if existing.Kind != "" && existing.Enabled {
			return existing, "skip"
		}
		// Upgrade: old format (mode: standing, timezone, no enabled/kind).
		block := migrateExistingBlock(existing, tags)
		return block, "upgrade"
	}

	// No shuttle: block at all. It's an ordinary constitution fiber.
	block := &schema.Block{
		Enabled: true,
		Kind:    "oneshot",
	}
	if agent := extractAgentTag(tags); agent != "" {
		block.Agent = agent
	}
	return block, "add"
}

// migrateExistingBlock converts an old-format shuttle: block to the new format.
// Old format: mode=standing, schedule.timezone, no enabled/kind fields.
func migrateExistingBlock(old *schema.Block, tags []string) *schema.Block {
	block := *old // copy

	// Rename mode→kind if needed.
	if block.Kind == "" && old.Schedule != nil {
		block.Kind = "standing"
	}
	if block.Kind == "" {
		block.Kind = "oneshot"
	}

	// Fill enabled.
	block.Enabled = true

	// Agent from tag.
	if block.Agent == "" {
		if agent := extractAgentTag(tags); agent != "" {
			block.Agent = agent
		}
	}

	return &block
}

// extractAgentTag returns the agent name from an agent:<name> tag, or "".
func extractAgentTag(tags []string) string {
	for _, t := range tags {
		if strings.HasPrefix(t, "agent:") {
			return strings.TrimPrefix(t, "agent:")
		}
	}
	return ""
}

// removeAgentTag shells out to felt edit --untag agent:<name>.
func removeAgentTag(host, fiberID, agentTag string) {
	tagVal := "agent:" + agentTag
	cmd := exec.Command("felt", "-C", host, "edit", fiberID, "--untag", tagVal)
	_ = cmd.Run()
}

// runFeltLS runs `felt ls -t constitution -j -s all` and returns parsed objects.
// felt outputs a JSON array when -j is used.
func runFeltLS(host string) ([]map[string]interface{}, error) {
	out, err := exec.Command("felt", "-C", host, "ls", "-t", "constitution", "-j", "-s", "all").Output()
	if err != nil {
		return nil, fmt.Errorf("felt ls: %v", err)
	}

	var records []map[string]interface{}
	if err := json.Unmarshal(out, &records); err != nil {
		return nil, fmt.Errorf("parsing felt ls output: %w", err)
	}
	return records, nil
}

// extractTagsFromRecord extracts the tags string slice from a felt ls JSON record.
func extractTagsFromRecord(record map[string]interface{}) []string {
	raw, ok := record["tags"]
	if !ok {
		return nil
	}
	switch v := raw.(type) {
	case []interface{}:
		tags := make([]string, 0, len(v))
		for _, t := range v {
			if s, ok := t.(string); ok {
				tags = append(tags, s)
			}
		}
		return tags
	case string:
		if v == "" {
			return nil
		}
		return strings.Split(v, ",")
	default:
		return nil
	}
}

func contains(slice []string, s string) bool {
	for _, v := range slice {
		if v == s {
			return true
		}
	}
	return false
}

func init() {
	migrateCmd.Flags().BoolVar(&migrateDryRun, "dry-run", false, "Print what would change without writing")
	rootCmd.AddCommand(migrateCmd)
}
