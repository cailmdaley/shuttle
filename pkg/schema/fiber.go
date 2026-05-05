package schema

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// FiberRef is the canonical (felt-host, fiber-id, md-path) triple for a fiber.
// Host and ID are derived from the nearest real `.felt/` store, so symlinked
// project views canonicalize back to Shuttle's actual dispatch identity.
type FiberRef struct {
	Host string
	ID   string
	Path string
}

// FeltHost returns Shuttle's default felt host.
// Resolution order:
//  1. LOOM_HOME env var
//  2. ~/loom (the standard loom location)
func FeltHost() (string, error) {
	if loom := os.Getenv("LOOM_HOME"); loom != "" {
		return expandUserPath(loom)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolving home directory: %w", err)
	}
	return filepath.Join(home, "loom"), nil
}

// ResolveFiberPath returns the canonical absolute path of a fiber's .md file
// under the default felt host.
func ResolveFiberPath(fiberID string) (string, error) {
	host, err := FeltHost()
	if err != nil {
		return "", err
	}
	ref, err := ResolveFiberInHost(host, fiberID)
	if err != nil {
		return "", err
	}
	return ref.Path, nil
}

// ResolveFiberInHost resolves an ID/query relative to the given felt host and
// returns the canonical felt-host / fiber-id pair plus the realpath'd md file.
//
// Exact lookup checks the bare and directory layouts directly. When neither
// exists it falls back to `felt -C <host> ls -j <query>` so prefix/alias
// resolution still works.
func ResolveFiberInHost(host, idOrQuery string) (*FiberRef, error) {
	normalizedHost, err := expandUserPath(host)
	if err != nil {
		return nil, fmt.Errorf("resolving felt host %q: %w", host, err)
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

// FiberRefFromPath derives the canonical felt host + fiber id from an absolute
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
	cmd := exec.Command("tmux", "has-session", "-t", sessionName)
	return cmd.Run() == nil
}
