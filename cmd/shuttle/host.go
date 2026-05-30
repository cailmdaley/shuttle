package main

import (
	"fmt"
	"os"
	"strings"
)

// resolveOwnHost determines the host id to stamp on a freshly installed
// block. A block is born owned: every install/repeat writes an explicit
// host: so the strict dispatch predicate (block.host == own_host_id) has a
// value to match, and no host-less block is produced by normal flows.
//
// Precedence:
//
//  1. explicit --host <name> — cross-host install (the operator is installing
//     a block destined for another daemon; the kanban create-form host
//     dropdown lands here too).
//  2. the local daemon's own_host_id via GET /api/v1/state .host — the
//     authoritative identity the poller will compare against. This is the
//     common path.
//  3. SHUTTLE_HOST env var — the same override the daemon itself honors;
//     keeps install working when the daemon is briefly down.
//  4. os.Hostname() — last-resort OS short name, matching the daemon's own
//     :inet.gethostname() fallback so a daemon-down install still stamps the
//     value the daemon will resolve to once it's back.
//
// Returns an error only if every source fails (daemon unreachable, env unset,
// and os.Hostname errors) — an empty host would silently never dispatch, so
// we fail loud instead.
func resolveOwnHost(flagVal string) (string, error) {
	if s := strings.TrimSpace(flagVal); s != "" {
		return s, nil
	}
	if h, err := fetchLocalHost(); err == nil {
		if h = strings.TrimSpace(h); h != "" {
			return h, nil
		}
	}
	if env := strings.TrimSpace(os.Getenv("SHUTTLE_HOST")); env != "" {
		return env, nil
	}
	if name, err := os.Hostname(); err == nil {
		if name = strings.TrimSpace(name); name != "" {
			return name, nil
		}
	}
	return "", fmt.Errorf(
		"could not resolve a host to stamp: daemon unreachable at %s, SHUTTLE_HOST unset, and os.Hostname() empty; pass --host <name> explicitly",
		daemonURL(),
	)
}
