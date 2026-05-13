package schema

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// FiberRef is the canonical (felt-store, fiber-id, md-path) triple for a fiber.
// Felt store and ID are derived from the nearest real `.felt/` store, so symlinked
// project views canonicalize back to Shuttle's actual dispatch identity.
type FiberRef struct {
	Host string
	ID   string
	Path string
}

// FeltStore returns Shuttle's default felt store (single).
// Resolution order:
//  1. LOOM_HOME env var
//  2. ~/loom (the standard loom location)
//
// Use this when one store is enough — e.g. addressing a fiber by id or running
// a -C-style felt invocation with a single root. For surfaces that need to see
// every fiber the daemon would dispatch, use FeltStores (plural).
func FeltStore() (string, error) {
	if loom := os.Getenv("LOOM_HOME"); loom != "" {
		return expandUserPath(loom)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolving home directory: %w", err)
	}
	return filepath.Join(home, "loom"), nil
}

// FeltStores returns every felt store the dispatcher considers. Mirrors
// Shuttle.FeltStores.configured_hosts/0 (lib/shuttle/felt_stores.ex) so the Go
// CLI sees the same surface the Elixir poller does:
//
//  1. LOOM_HOMES env var (comma-separated; non-empty wins)
//  2. ~/.shuttle/felt_stores.json (or $SHUTTLE_FELT_STORES_FILE) when present
//  3. Single host from FeltStore() (LOOM_HOME, then ~/loom)
//
// Without this, surfaces like `shuttle status` only ever read the single
// default store and silently miss everything pinned in the registry — which is
// the whole reason a multi-store registry exists.
func FeltStores() ([]string, error) {
	if envHosts := loomHomesEnv(); len(envHosts) > 0 {
		return envHosts, nil
	}
	if registered, err := registeredFeltStores(); err == nil && len(registered) > 0 {
		return registered, nil
	}
	store, err := FeltStore()
	if err != nil {
		return nil, err
	}
	return []string{store}, nil
}

// loomHomesEnv parses LOOM_HOMES into the same shape as the Elixir reader.
func loomHomesEnv() []string {
	raw := os.Getenv("LOOM_HOMES")
	if raw == "" {
		return nil
	}
	return normalizeFeltStores(strings.Split(raw, ","))
}

// registeredFeltStores reads the persisted ~/.shuttle/felt_stores.json file (or
// $SHUTTLE_FELT_STORES_FILE override) and returns its normalized store list.
// Missing file or empty list returns an empty slice with no error — callers
// fall back to the single default.
func registeredFeltStores() ([]string, error) {
	path, err := feltStoresRegistryPath()
	if err != nil {
		return nil, err
	}
	content, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}

	// Tolerate both wrapping shapes the Elixir writer accepts:
	//   {"version": 1, "felt_stores": [...]}  ← canonical
	//   [...]                                 ← bare list
	var wrapped struct {
		FeltStores []string `json:"felt_stores"`
	}
	if err := json.Unmarshal(content, &wrapped); err == nil && wrapped.FeltStores != nil {
		return normalizeFeltStores(wrapped.FeltStores), nil
	}
	var bare []string
	if err := json.Unmarshal(content, &bare); err == nil {
		return normalizeFeltStores(bare), nil
	}
	return nil, fmt.Errorf("parsing %s: unexpected shape", path)
}

func feltStoresRegistryPath() (string, error) {
	if env := os.Getenv("SHUTTLE_FELT_STORES_FILE"); env != "" {
		return expandUserPath(env)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolving home directory: %w", err)
	}
	return filepath.Join(home, ".shuttle", "felt_stores.json"), nil
}

// normalizeFeltStores mirrors Shuttle.FeltStores.normalize/1: trim, drop empty,
// expand `~`, deduplicate while preserving first-seen order.
func normalizeFeltStores(hosts []string) []string {
	seen := make(map[string]bool, len(hosts))
	out := make([]string, 0, len(hosts))
	for _, h := range hosts {
		h = strings.TrimSpace(h)
		if h == "" {
			continue
		}
		expanded, err := expandUserPath(h)
		if err != nil {
			continue
		}
		if seen[expanded] {
			continue
		}
		seen[expanded] = true
		out = append(out, expanded)
	}
	return out
}

// ResolveFiberPath returns the canonical absolute path of a fiber's .md file
// under the default felt store.
func ResolveFiberPath(fiberID string) (string, error) {
	store, err := FeltStore()
	if err != nil {
		return "", err
	}
	ref, err := ResolveFiberInHost(store, fiberID)
	if err != nil {
		return "", err
	}
	return ref.Path, nil
}

// ResolveFiberInHost resolves an ID/query relative to the given felt store and
// returns the canonical felt-store / fiber-id pair plus the realpath'd md file.
//
// Exact lookup checks the bare and directory layouts directly. When neither
// exists it falls back to `felt -C <host> ls -j <query>` so prefix/alias
// resolution still works.
func ResolveFiberInHost(host, idOrQuery string) (*FiberRef, error) {
	normalizedHost, err := expandUserPath(host)
	if err != nil {
		return nil, fmt.Errorf("resolving felt store %q: %w", host, err)
	}

	if path, ok := exactFiberPath(normalizedHost, idOrQuery); ok {
		return canonicalizeFiberPath(path)
	}

	resolvedID, err := resolveFiberIDViaFelt(normalizedHost, idOrQuery)
	if err != nil {
		return nil, err
	}

	path, ok := exactFiberPath(normalizedHost, resolvedID)
	if !ok {
		return nil, fmt.Errorf("fiber %q resolved to ID %q but file not found", idOrQuery, resolvedID)
	}
	return canonicalizeFiberPath(path)
}

func exactFiberPath(host, fiberID string) (string, bool) {
	segments := strings.Split(fiberID, "/")
	basename := segments[len(segments)-1]
	feltDir := filepath.Join(host, ".felt")

	if !strings.Contains(fiberID, "/") {
		bare := filepath.Join(feltDir, basename+".md")
		if _, err := os.Stat(bare); err == nil {
			return bare, true
		}
	}

	dir := filepath.Join(feltDir, filepath.FromSlash(fiberID), basename+".md")
	if _, err := os.Stat(dir); err == nil {
		return dir, true
	}
	return "", false
}

func resolveFiberIDViaFelt(host, query string) (string, error) {
	cmd := exec.Command("felt", "-C", host, "ls", "-j", query)
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("fiber %q not found (felt ls error: %v)", query, err)
	}

	var results []struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(out, &results); err != nil {
		return "", fmt.Errorf("parsing felt ls output: %w", err)
	}
	if len(results) == 0 || results[0].ID == "" {
		return "", fmt.Errorf("fiber %q not found", query)
	}
	return results[0].ID, nil
}

func canonicalizeFiberPath(path string) (*FiberRef, error) {
	canonicalPath := path
	if real, err := filepath.EvalSymlinks(path); err == nil {
		canonicalPath = real
	}
	host, fiberID, err := FiberRefFromPath(canonicalPath)
	if err != nil {
		return nil, err
	}
	return &FiberRef{Host: host, ID: fiberID, Path: canonicalPath}, nil
}

// FiberRefFromPath derives the canonical felt store + fiber id from an absolute
// md path by walking up to the nearest enclosing `.felt/` directory.
func FiberRefFromPath(mdPath string) (string, string, error) {
	if mdPath == "" {
		return "", "", fmt.Errorf("empty fiber path")
	}

	abs, err := filepath.Abs(mdPath)
	if err != nil {
		return "", "", fmt.Errorf("resolving absolute path: %w", err)
	}
	if real, err := filepath.EvalSymlinks(abs); err == nil {
		abs = real
	}

	feltDir, rel, err := feltStoreRelativePath(abs)
	if err != nil {
		return "", "", err
	}
	fiberID, err := fiberIDFromStorePath(rel)
	if err != nil {
		return "", "", err
	}
	return filepath.Dir(feltDir), fiberID, nil
}

func feltStoreRelativePath(path string) (string, string, error) {
	current := filepath.Dir(path)
	for {
		if filepath.Base(current) == ".felt" {
			rel, err := filepath.Rel(current, path)
			if err != nil {
				return "", "", fmt.Errorf("computing relative path: %w", err)
			}
			return current, filepath.ToSlash(rel), nil
		}
		next := filepath.Dir(current)
		if next == current {
			break
		}
		current = next
	}
	return "", "", fmt.Errorf("path %q is not under a .felt store", path)
}

func fiberIDFromStorePath(rel string) (string, error) {
	rel = strings.TrimPrefix(filepath.ToSlash(rel), "./")
	parts := strings.Split(rel, "/")
	if len(parts) == 0 {
		return "", fmt.Errorf("empty store-relative path")
	}
	file := parts[len(parts)-1]
	if !strings.HasSuffix(file, ".md") {
		return "", fmt.Errorf("path %q does not point at a markdown fiber", rel)
	}
	basename := strings.TrimSuffix(file, ".md")
	if len(parts) == 1 {
		return basename, nil
	}
	parent := parts[len(parts)-2]
	if parent != basename {
		return "", fmt.Errorf("unexpected fiber layout under .felt: %q", rel)
	}
	return strings.Join(parts[:len(parts)-1], "/"), nil
}

func expandUserPath(path string) (string, error) {
	if path == "" {
		return "", fmt.Errorf("empty path")
	}
	if path == "~" || strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("resolving home directory: %w", err)
		}
		if path == "~" {
			path = home
		} else {
			path = filepath.Join(home, path[2:])
		}
	}
	if filepath.IsAbs(path) {
		return filepath.Clean(path), nil
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	return filepath.Clean(abs), nil
}

// TmuxSessionName returns the canonical tmux session name for a fiber ID.
func TmuxSessionName(fiberID string) string {
	// Preserve the full fiber ID so every surface (Elixir dispatcher, Go CLI,
	// portolan UI, manual tmux attach) agrees on the same worker session name.
	// tmux accepts `/` in session names on macOS and Linux.
	return "shuttle-" + fiberID
}

// TmuxSessionExists checks whether a tmux session with the given name exists.
func TmuxSessionExists(sessionName string) bool {
	cmd := exec.Command("tmux", "has-session", "-t", "="+sessionName)
	return cmd.Run() == nil
}
