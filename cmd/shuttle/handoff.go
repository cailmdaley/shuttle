package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/spf13/cobra"
)

// endOwnTmuxSession tears down the tmux session this process is running in — the
// worker's `shuttle-<id>` session. Folded into `handoff` so the worker's exit is
// ONE command (write the clean-exit marker, then end the session) instead of a
// marker-write followed by a separate `kill $PPID`. Best-effort and a no-op
// outside tmux (e.g. a manual/test invocation), so it never kills a stray shell:
// it asks tmux for the *current* session name and kills exactly that.
func endOwnTmuxSession() {
	if os.Getenv("TMUX") == "" {
		return
	}
	name, err := exec.Command("tmux", "display-message", "-p", "#S").Output()
	if err != nil {
		return
	}
	session := strings.TrimSpace(string(name))
	if session == "" {
		return
	}
	// This kills our own pane mid-call; the marker is already durably on disk
	// (os.Rename completed before we got here), so nothing is lost.
	_ = exec.Command("tmux", "kill-session", "-t", session).Run()
}

// shuttleDataDir resolves the per-host Shuttle data directory, mirroring the
// Elixir side (Shuttle.Markers.data_dir/0, WaitingTracker.default_events_file/0):
// $SHUTTLE_DATA_DIR, else ~/.shuttle. This is the FIRST SHUTTLE_DATA_DIR resolver
// on the Go side — the CLI had none — so it must agree byte-for-byte with the
// daemon's resolution, or the dispatch and handoff markers land in different
// trees and continuation silently breaks.
func shuttleDataDir() (string, error) {
	if dir := os.Getenv("SHUTTLE_DATA_DIR"); dir != "" {
		return dir, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolving home directory: %w", err)
	}
	return filepath.Join(home, ".shuttle"), nil
}

// handoffMarkerPath is the extensionless handoff marker for the given runtime
// key: $SHUTTLE_DATA_DIR/handoff/<key>. The Elixir reader (Markers.handoff_path/1)
// resolves the identical path; the key is the daemon-supplied SHUTTLE_FIBER_KEY,
// never recomputed here.
func handoffMarkerPath(key string) (string, error) {
	dir, err := shuttleDataDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "handoff", key), nil
}

// writeHandoffMarker atomically writes {"at": <RFC3339 UTC now>} to the handoff
// marker for key. Atomic (temp file + os.Rename), matching the Elixir writer, so
// a reader never sees a half-written marker. The marker carries NO session_uuid:
// the worker doesn't know its own UUID (the daemon captured it into the dispatch
// marker); the handoff is a pure clean-exit signal whose `at` the daemon compares
// against dispatch.dispatched_at to decide fresh-vs-resume.
func writeHandoffMarker(key string) (string, error) {
	path, err := handoffMarkerPath(key)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", fmt.Errorf("creating handoff dir: %w", err)
	}

	// RFC3339Nano with a trailing Z (UTC). The Elixir reader parses this via
	// DateTime.from_iso8601; both no-fractional and fractional forms parse, and
	// DateTime comparison is on the wire value, so >= microsecond precision is
	// exact.
	at := time.Now().UTC().Format(time.RFC3339Nano)
	payload, err := json.Marshal(map[string]string{"at": at})
	if err != nil {
		return "", fmt.Errorf("encoding handoff marker: %w", err)
	}

	tmp, err := os.CreateTemp(filepath.Dir(path), ".handoff-*.tmp")
	if err != nil {
		return "", fmt.Errorf("creating temp marker: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // no-op once the rename succeeds

	if _, err := tmp.Write(payload); err != nil {
		tmp.Close()
		return "", fmt.Errorf("writing temp marker: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return "", fmt.Errorf("closing temp marker: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return "", fmt.Errorf("renaming marker into place: %w", err)
	}
	return path, nil
}

func newHandoffCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "handoff <fiber>",
		Short: "Write the clean-exit handoff marker for a worker",
		Long: `Writes the per-host handoff marker ($SHUTTLE_DATA_DIR/handoff/<key> =
{"at": <now>}) that tells the daemon this worker exited CLEANLY — so the next
dispatch starts fresh instead of resuming a dead transcript.

A worker calls this as its FINAL action, after rewriting the constitution's
'## Status' block: it writes the marker and then ends its own tmux session — so
the exit is one command, no separate 'kill $PPID'. The runtime key comes from
SHUTTLE_FIBER_KEY, which the daemon exports at dispatch so the worker's marker and
the daemon's dispatch marker line up byte-for-byte; this command fails loudly when
that env is unset (the worker was not launched by the daemon).

The <fiber> argument is accepted for symmetry with the other verbs and to make
the call self-documenting, but the marker is keyed strictly by SHUTTLE_FIBER_KEY —
never recomputed from the fiber ref — so the two writers can never diverge.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			key := os.Getenv("SHUTTLE_FIBER_KEY")
			if key == "" {
				return fmt.Errorf("SHUTTLE_FIBER_KEY is unset — handoff is only valid inside a daemon-launched worker")
			}
			path, err := writeHandoffMarker(key)
			if err != nil {
				return err
			}
			fmt.Printf("handoff marker written: %s\n", path)
			// Final act: end our own tmux session (no-op outside tmux). The
			// marker is already durably on disk, so the kill loses nothing.
			endOwnTmuxSession()
			return nil
		},
	}
}

var handoffCmd = newHandoffCmd()

func init() {
	rootCmd.AddCommand(handoffCmd)
}
