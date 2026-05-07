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
	ID            string   `json:"id"`
	CLI           string   `json:"cli"`
	Wrapper       string   `json:"wrapper"`
	Provider      string   `json:"provider,omitempty"`
	Model         string   `json:"model,omitempty"`
	ExtraFlags    string   `json:"extra_flags,omitempty"`
	RequiresModel bool     `json:"requires_model,omitempty"`
	Aliases       []string `json:"aliases"`
	Default       bool     `json:"default"`
}

// AgentRegistry is the loaded registry of agents.
type AgentRegistry struct {
	agents []AgentRecord
}

// embeddedAgentJSON is provided by pkg/schema/agents_embedded.go (generated from share/agents.json)

// LoadAgentRegistry returns the built-in agent registry. If SHUTTLE_SHARE
// is set and contains a readable agents.json, that file takes precedence.
// Otherwise fall back to the embedded share/agents.json compiled into the binary.
func LoadAgentRegistry() (*AgentRegistry, error) {
	if path, err := FindSharePath("agents.json"); err == nil {
		return LoadAgentRegistryFromFile(path)
	}
	var agents []AgentRecord
	if err := json.Unmarshal(embeddedAgentJSON, &agents); err != nil {
		return nil, fmt.Errorf("parsing embedded agents.json: %w", err)
	}
	return &AgentRegistry{agents: agents}, nil
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

// FindSharePath locates a path under the Shuttle share directory by looking in:
//  1. SHUTTLE_SHARE/<rel>
//  2. The directory of the running binary (sibling share/<rel>)
//  3. The source-relative share/ dir (for go run / tests)
func FindSharePath(rel string) (string, error) {
	// Env override first.
	if dir := os.Getenv("SHUTTLE_SHARE"); dir != "" {
		p := filepath.Join(dir, rel)
		if _, err := os.Stat(p); err == nil {
			return filepath.Clean(p), nil
		}
	}

	// Next to the running binary (release layout: bin/ sibling to share/).
	if exe, err := os.Executable(); err == nil {
		// exe is .../bin/shuttle-ctl or .../bin/shuttle; share/ is adjacent.
		binDir := filepath.Dir(exe)
		for _, candidate := range []string{
			filepath.Join(binDir, "share", rel),
			filepath.Join(binDir, "..", "share", rel),
		} {
			if _, err := os.Stat(candidate); err == nil {
				return filepath.Clean(candidate), nil
			}
		}
	}

	// Source-relative (development: this file lives at pkg/schema/).
	_, thisFile, _, ok := runtime.Caller(0)
	if ok {
		candidate := filepath.Join(filepath.Dir(thisFile), "..", "..", "share", rel)
		if _, err := os.Stat(candidate); err == nil {
			return filepath.Clean(candidate), nil
		}
	}

	return "", fmt.Errorf("share path %q not found (set SHUTTLE_SHARE env to override)", rel)
}
