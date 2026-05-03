package schema

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// AgentRecord holds the configuration for one agent harness.
type AgentRecord struct {
	ID           string   `json:"id"`
	CLI          string   `json:"cli"`
	Wrapper      string   `json:"wrapper"`
	Provider     string   `json:"provider,omitempty"`
	Model        string   `json:"model,omitempty"`
	ExtraFlags   string   `json:"extra_flags,omitempty"`
	RequiresModel bool    `json:"requires_model,omitempty"`
	Aliases      []string `json:"aliases"`
	Default      bool     `json:"default"`
}

// AgentRegistry is the loaded registry of agents.
type AgentRegistry struct {
	agents []AgentRecord
}

// defaultAgents mirrors config/agents.exs as the Go baseline.
// Keep in sync with share/agents.json and config/agents.exs.
var defaultAgentRecords = []AgentRecord{
	{ID: "claude-sonnet", CLI: "claude", Wrapper: "claude", Model: "sonnet", ExtraFlags: "--dangerously-skip-permissions", Default: true},
	{ID: "claude-opus", CLI: "claude", Wrapper: "claude", Model: "opus", ExtraFlags: "--dangerously-skip-permissions"},
	{ID: "claude-haiku", CLI: "claude", Wrapper: "claude", Model: "haiku", ExtraFlags: "--dangerously-skip-permissions"},
	{ID: "codex", CLI: "codex", Wrapper: "codex", Model: "gpt-5.5", ExtraFlags: "--dangerously-bypass-approvals-and-sandbox", Aliases: []string{"codex"}},
	{ID: "codex-mini", CLI: "codex", Wrapper: "codex", Model: "gpt-5.4-mini", ExtraFlags: "--dangerously-bypass-approvals-and-sandbox"},
	{ID: "pi-sonnet", CLI: "pi", Wrapper: "pi", Provider: "openrouter", Model: "anthropic/claude-sonnet-4", RequiresModel: true},
	{ID: "pi-gpt", CLI: "pi", Wrapper: "pi", Provider: "openrouter", Model: "openai/gpt-4o", RequiresModel: true},
	{ID: "pi-kimi", CLI: "pi", Wrapper: "pi", Provider: "openrouter", Model: "moonshotai/kimi-k2.6", RequiresModel: true},
	{ID: "pi-deepseek-pro", CLI: "pi", Wrapper: "pi", Provider: "openrouter", Model: "deepseek/deepseek-v4-pro", RequiresModel: true},
	{ID: "pi-deepseek-flash", CLI: "pi", Wrapper: "pi", Provider: "openrouter", Model: "deepseek/deepseek-v4-flash", RequiresModel: true, Aliases: []string{"pi"}},
}

// LoadAgentRegistry returns the built-in agent registry. If SHUTTLE_SHARE
// is set and contains a readable agents.json, that file takes precedence.
func LoadAgentRegistry() (*AgentRegistry, error) {
	if path, err := findShareFile("agents.json"); err == nil {
		return LoadAgentRegistryFromFile(path)
	}
	return &AgentRegistry{agents: defaultAgentRecords}, nil
}

// LoadAgentRegistryFromFile reads agents.json from the given path.
func LoadAgentRegistryFromFile(path string) (*AgentRegistry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}
	var agents []AgentRecord
	if err := json.Unmarshal(data, &agents); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", path, err)
	}
	return &AgentRegistry{agents: agents}, nil
}

// Find returns the agent with the given ID or alias.
func (r *AgentRegistry) Find(nameOrAlias string) (AgentRecord, bool) {
	lower := strings.ToLower(nameOrAlias)
	// Exact ID match first.
	for _, a := range r.agents {
		if strings.ToLower(a.ID) == lower {
			return a, true
		}
	}
	// Alias match.
	for _, a := range r.agents {
		for _, alias := range a.Aliases {
			if strings.ToLower(alias) == lower {
				return a, true
			}
		}
	}
	return AgentRecord{}, false
}

// Default returns the registry's default agent, or an error if none is marked.
func (r *AgentRegistry) Default() (AgentRecord, error) {
	for _, a := range r.agents {
		if a.Default {
			return a, nil
		}
	}
	if len(r.agents) > 0 {
		return r.agents[0], nil
	}
	return AgentRecord{}, fmt.Errorf("agent registry is empty")
}

// IDs returns all agent IDs in the registry.
func (r *AgentRegistry) IDs() []string {
	ids := make([]string, len(r.agents))
	for i, a := range r.agents {
		ids[i] = a.ID
	}
	return ids
}

// findShareFile locates a file by looking in:
//  1. The directory of the running binary (sibling share/<name>)
//  2. The source-relative share/ dir (for go run / tests)
//  3. SHUTTLE_SHARE env override
func findShareFile(name string) (string, error) {
	// Env override first.
	if dir := os.Getenv("SHUTTLE_SHARE"); dir != "" {
		p := filepath.Join(dir, name)
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
	}

	// Next to the running binary (release layout: bin/ sibling to share/).
	if exe, err := os.Executable(); err == nil {
		// exe is .../bin/shuttle-ctl or .../bin/shuttle; share/ is adjacent.
		binDir := filepath.Dir(exe)
		for _, rel := range []string{
			filepath.Join(binDir, "share", name),
			filepath.Join(binDir, "..", "share", name),
		} {
			if _, err := os.Stat(rel); err == nil {
				return filepath.Clean(rel), nil
			}
		}
	}

	// Source-relative (development: this file lives at pkg/schema/).
	_, thisFile, _, ok := runtime.Caller(0)
	if ok {
		root := filepath.Join(filepath.Dir(thisFile), "..", "..", "share", name)
		if _, err := os.Stat(root); err == nil {
			return filepath.Clean(root), nil
		}
	}

	return "", fmt.Errorf("%s not found (set SHUTTLE_SHARE env to override)", name)
}
