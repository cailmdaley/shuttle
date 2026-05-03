package schema

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// FeltHost returns the root directory of the loom / felt host.
// Resolution order:
//  1. LOOM_HOME env var
//  2. ~/loom (the standard loom location)
func FeltHost() (string, error) {
	if loom := os.Getenv("LOOM_HOME"); loom != "" {
		return loom, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolving home directory: %w", err)
	}
	return filepath.Join(home, "loom"), nil
}

// ResolveFiberPath returns the absolute path of a fiber's .md file.
//
// Felt uses two layouts:
//   - Directory fiber: .felt/<id>/<basename>.md  (most fibers)
//   - Root/bare fiber: .felt/<basename>.md       (entry-point root fibers)
//
// The function checks the bare form first, then the directory form.
// If neither exists it tries shelling out to `felt ls -j <id>` to handle
// prefix/alias resolution (e.g. the user types a short prefix).
func ResolveFiberPath(fiberID string) (string, error) {
	host, err := FeltHost()
	if err != nil {
		return "", err
	}

	segments := strings.Split(fiberID, "/")
	basename := segments[len(segments)-1]

	feltDir := filepath.Join(host, ".felt")

	// Bare form: .felt/<basename>.md (only possible for un-slashed IDs).
	if !strings.Contains(fiberID, "/") {
		bare := filepath.Join(feltDir, basename+".md")
		if _, err := os.Stat(bare); err == nil {
			return bare, nil
		}
	}

	// Directory form: .felt/<id>/<basename>.md
	dir := filepath.Join(feltDir, filepath.FromSlash(fiberID), basename+".md")
	if _, err := os.Stat(dir); err == nil {
		return dir, nil
	}

	// Fall back to felt ls -j to handle prefix resolution.
	return resolveFiberViaFelt(host, fiberID)
}

// resolveFiberViaFelt shells out to `felt ls -j <query>` and returns the
// first match's file path. Used when prefix/alias resolution is needed.
func resolveFiberViaFelt(host, query string) (string, error) {
	cmd := exec.Command("felt", "-C", host, "ls", "-j", query)
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("fiber %q not found (felt ls error: %v)", query, err)
	}

	// Parse the JSONL output: one JSON object per line.
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) == 0 || lines[0] == "" {
		return "", fmt.Errorf("fiber %q not found", query)
	}

	// We just need the ID from the first result, then resolve the path.
	// Quick-parse: look for "id":"<value>" in the first line.
	id := extractJSONString(lines[0], "id")
	if id == "" {
		return "", fmt.Errorf("fiber %q not found (empty id in felt ls output)", query)
	}

	// Now resolve with the canonical ID.
	segments := strings.Split(id, "/")
	basename := segments[len(segments)-1]
	feltDir := filepath.Join(host, ".felt")

	if !strings.Contains(id, "/") {
		bare := filepath.Join(feltDir, basename+".md")
		if _, err := os.Stat(bare); err == nil {
			return bare, nil
		}
	}

	dir := filepath.Join(feltDir, filepath.FromSlash(id), basename+".md")
	if _, err := os.Stat(dir); err == nil {
		return dir, nil
	}

	return "", fmt.Errorf("fiber %q resolved to ID %q but file not found", query, id)
}

// extractJSONString extracts the first value for key from a JSON string
// without a full JSON parser (for lightweight use; assumes well-formed JSON).
func extractJSONString(line, key string) string {
	needle := `"` + key + `":"`
	idx := strings.Index(line, needle)
	if idx < 0 {
		return ""
	}
	start := idx + len(needle)
	end := strings.Index(line[start:], `"`)
	if end < 0 {
		return ""
	}
	return line[start : start+end]
}

// FiberIDFromPath derives a felt fiber ID from the absolute .md file path,
// given a host directory. Used to build tmux session names.
func FiberIDFromPath(host, mdPath string) (string, error) {
	feltDir := filepath.Join(host, ".felt")
	rel, err := filepath.Rel(feltDir, mdPath)
	if err != nil {
		return "", fmt.Errorf("computing relative path: %w", err)
	}
	rel = filepath.ToSlash(rel)
	// Strip trailing /<basename>.md suffix for directory fibers.
	if strings.Count(rel, "/") >= 1 {
		// e.g. ai-futures/shuttle/constitution-X/constitution-X.md
		// → ai-futures/shuttle/constitution-X
		lastSlash := strings.LastIndex(rel, "/")
		dirPart := rel[:lastSlash]
		basename := rel[lastSlash+1:]
		if strings.TrimSuffix(basename, ".md") == filepath.Base(dirPart) {
			return dirPart, nil
		}
	}
	// Bare fiber: just strip .md
	return strings.TrimSuffix(rel, ".md"), nil
}

// TmuxSessionName returns the tmux session name for a fiber ID.
func TmuxSessionName(fiberID string) string {
	// Shuttle uses the last path segment for tmux names to keep them short.
	// e.g. "ai-futures/shuttle/constitution-X" → "shuttle-constitution-X"
	segments := strings.Split(fiberID, "/")
	return "shuttle-" + segments[len(segments)-1]
}

// TmuxSessionExists checks whether a tmux session with the given name exists.
func TmuxSessionExists(sessionName string) bool {
	cmd := exec.Command("tmux", "has-session", "-t", sessionName)
	return cmd.Run() == nil
}
