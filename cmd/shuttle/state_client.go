package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// state_client.go — thin HTTP client for the local Shuttle daemon's
// state endpoints. The Go CLI is offline by default (felt+tmux); the
// `--remote` and `--all` flags on `status` are the first commands that
// reach into the daemon.
//
// Cross-host visibility goes through the local daemon's composite
// endpoint. The daemon's RemoteRegistry already polls each configured
// remote over its SSH-tunnel-mapped port and caches snapshots with
// freshness — the CLI simply renders that response. This keeps remote
// configuration in one place (Elixir mix config) rather than
// duplicating it in the Go CLI.

const defaultDaemonURL = "http://127.0.0.1:4000"

// daemonURL returns the local Shuttle daemon's base URL.
//
// Default: http://127.0.0.1:4000 (matches the daemon's bind address).
// Override via SHUTTLE_DAEMON_URL — useful when running multiple
// daemons or when a developer remaps the port. There is intentionally
// no flag for this; the daemon is a per-machine service, and a flag
// would invite the wrong mental model (CLI as remote-controller).
func daemonURL() string {
	if v := os.Getenv("SHUTTLE_DAEMON_URL"); v != "" {
		return v
	}
	return defaultDaemonURL
}

// SnapshotEntry mirrors a single row from `Shuttle.Poller.build_snapshot/1`'s
// `eligible` list. Field tags match the JSON keys the Elixir endpoint
// emits. Fields the CLI doesn't render today are still parsed so we can
// surface them later without changing the wire format.
type SnapshotEntry struct {
	FiberID        string `json:"fiber_id"`
	FeltStore      string `json:"felt_store,omitempty"`
	TmuxSession    string `json:"tmux_session,omitempty"`
	Agent          string `json:"agent,omitempty"`
	State          string `json:"state,omitempty"`
	RunID          string `json:"run_id,omitempty"`
	StartedAt      int64  `json:"started_at,omitempty"`
	LastActivityAt int64  `json:"last_activity_at,omitempty"`
	RuntimeSeconds int64  `json:"runtime_seconds,omitempty"`
}

// StandingRoleEntry mirrors `Poller.standing_role_snapshots/2` rows.
// Standing-role entries don't carry `agent` (it lives in the fiber
// frontmatter only); the CLI renders `(default)` in that column.
type StandingRoleEntry struct {
	FiberID    string         `json:"fiber_id"`
	State      string         `json:"state,omitempty"`
	RunID      string         `json:"run_id,omitempty"`
	NextDueAt  *int64         `json:"next_due_at,omitempty"`
	LastRunAt  *int64         `json:"last_run_at,omitempty"`
	Schedule   map[string]any `json:"schedule,omitempty"`
	Validation []any          `json:"validation_errors,omitempty"`
	Extra      map[string]any `json:"-"`
}

// RetryEntry mirrors `Poller.build_snapshot/1`'s `retrying` rows.
type RetryEntry struct {
	FiberID string `json:"fiber_id"`
	Attempt int    `json:"attempt,omitempty"`
	DueInMS int64  `json:"due_in_ms,omitempty"`
	Error   string `json:"error,omitempty"`
}

// Snapshot is the daemon's per-host runtime state.
type Snapshot struct {
	PollAt        int64               `json:"poll_at,omitempty"`
	Host          string              `json:"host,omitempty"`
	FeltStores    []string            `json:"felt_stores,omitempty"`
	Eligible      []SnapshotEntry     `json:"eligible,omitempty"`
	Retrying      []RetryEntry        `json:"retrying,omitempty"`
	StandingRoles []StandingRoleEntry `json:"standing_roles,omitempty"`
	ClaimedCount  int                 `json:"claimed_count,omitempty"`
}

// RemoteRecovery is the laptop daemon's per-origin self-healing state.
// Healthy is the steady state; non-healthy values describe the current
// recovery cascade or backoff window.
type RemoteRecovery struct {
	State       string `json:"state,omitempty"`
	Attempt     int    `json:"attempt,omitempty"`
	LastError   string `json:"last_error,omitempty"`
	LastAction  string `json:"last_action,omitempty"`
	NextRetryAt string `json:"next_retry_at,omitempty"`
}

// RemoteSnapshot is one entry in the composite endpoint's `remotes`
// map: a remote daemon's snapshot plus freshness metadata maintained
// by the laptop's `Shuttle.RemoteRegistry`.
type RemoteSnapshot struct {
	Snapshot     *Snapshot       `json:"snapshot"`
	LastPolledAt string          `json:"last_polled_at,omitempty"`
	Stale        bool            `json:"stale"`
	LastError    string          `json:"last_error,omitempty"`
	Recovery     *RemoteRecovery `json:"recovery,omitempty"`
}

// CompositeState is the response shape of GET /api/v1/state/composite.
type CompositeState struct {
	Local   *Snapshot                  `json:"local"`
	Remotes map[string]*RemoteSnapshot `json:"remotes"`
}

// fetchComposite calls GET /api/v1/state/composite and decodes the
// response. Returns a wrapped error on transport failure or non-200
// status, including the daemon URL so the user knows which daemon
// they're trying to reach.
func fetchComposite() (*CompositeState, error) {
	url := daemonURL() + "/api/v1/state/composite"
	return fetchCompositeFrom(url)
}

// fetchLocalHost calls GET /api/v1/state and returns the local daemon's
// own_host_id (the identity the poller compares a block's host: against).
// This is the authoritative source for stamping host on install/repeat —
// it's literally the value the dispatch predicate will check. Short timeout:
// callers fall back to SHUTTLE_HOST / os.Hostname() when the daemon is down.
func fetchLocalHost() (string, error) {
	url := daemonURL() + "/api/v1/state"
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("daemon returned %d: %s", resp.StatusCode, string(body))
	}

	var s Snapshot
	if err := json.Unmarshal(body, &s); err != nil {
		return "", err
	}
	return s.Host, nil
}

func postLifecycle(action string, payload map[string]any) (string, error) {
	if os.Getenv("SHUTTLE_LIFECYCLE_OFFLINE") != "" {
		return "", fmt.Errorf("daemon lifecycle disabled by SHUTTLE_LIFECYCLE_OFFLINE")
	}

	payload["action"] = action
	body, err := json.Marshal(payload)
	if err != nil {
		return "", fmt.Errorf("encoding lifecycle request: %w", err)
	}

	url := daemonURL() + "/api/v1/lifecycle"
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("reaching daemon at %s: %w", daemonURL(), err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("reading daemon response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return "", lifecycleStatusError{
			status: resp.StatusCode,
			body:   strings.TrimSpace(string(respBody)),
		}
	}
	return string(respBody), nil
}

type lifecycleStatusError struct {
	status int
	body   string
}

func (e lifecycleStatusError) Error() string {
	return fmt.Sprintf("daemon returned %d: %s", e.status, e.body)
}

func postSession(action string, payload map[string]any) (string, error) {
	if os.Getenv("SHUTTLE_SESSION_OFFLINE") != "" {
		return "", fmt.Errorf("daemon session bridge disabled by SHUTTLE_SESSION_OFFLINE")
	}

	payload["action"] = action
	body, err := json.Marshal(payload)
	if err != nil {
		return "", fmt.Errorf("encoding session request: %w", err)
	}

	url := daemonURL() + "/api/v1/session"
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("reaching daemon at %s: %w", daemonURL(), err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("reading daemon response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("daemon returned %d: %s", resp.StatusCode, string(respBody))
	}
	return string(respBody), nil
}

func fetchCompositeFrom(url string) (*CompositeState, error) {
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return nil, fmt.Errorf("reaching daemon at %s: %w (start the daemon with `make start` or set SHUTTLE_DAEMON_URL)", daemonURL(), err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("reading daemon response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("daemon returned %d: %s", resp.StatusCode, string(body))
	}

	var out CompositeState
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("parsing daemon response: %w", err)
	}
	return &out, nil
}
