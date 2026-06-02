package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
)

func TestSessionSetCmd_UsesDaemonSessionWhenAvailable(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "session-fiber", `---
name: Session fiber
status: active
shuttle:
  enabled: true
  kind: oneshot
---

Body.
`)
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}

	var payload map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/session" {
			t.Fatalf("unexpected request path %q", r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatalf("decode payload: %v", err)
		}
		_, _ = w.Write([]byte("session worker-session stored for session-fiber\n"))
	}))
	defer srv.Close()
	enableDaemonSession(t, srv.URL)

	cmd := newSessionSetCmd()
	cmd.SetArgs([]string{"session-fiber", "worker-session", "--agent", "codex"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	if !bytes.Equal(before, after) {
		t.Fatalf("daemon path should not rewrite frontmatter. before:\n%s\nafter:\n%s", before, after)
	}
	if payload["action"] != "set" ||
		payload["fiber"] != "session-fiber" ||
		payload["session_id"] != "worker-session" ||
		payload["agent"] != "codex" {
		t.Fatalf("unexpected session payload: %#v", payload)
	}
}

func TestSessionClearCmd_UsesDaemonSessionWhenAvailable(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "session-fiber", `---
name: Session fiber
status: active
shuttle:
  enabled: true
  kind: oneshot
  session:
    id: old-session
---

Body.
`)
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}

	var payload map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/session" {
			t.Fatalf("unexpected request path %q", r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatalf("decode payload: %v", err)
		}
		_, _ = w.Write([]byte("session cleared for session-fiber\n"))
	}))
	defer srv.Close()
	enableDaemonSession(t, srv.URL)

	cmd := newSessionClearCmd()
	cmd.SetArgs([]string{"session-fiber"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	if !bytes.Equal(before, after) {
		t.Fatalf("daemon path should not rewrite frontmatter. before:\n%s\nafter:\n%s", before, after)
	}
	if payload["action"] != "clear" || payload["fiber"] != "session-fiber" {
		t.Fatalf("unexpected session payload: %#v", payload)
	}
}

func TestSessionSetCmd_FailsClosedWhenDaemonUnavailable(t *testing.T) {
	host, cleanup := withTempHost(t)
	defer cleanup()

	path := writeFiber(t, host, "session-fiber", `---
name: Session fiber
status: active
shuttle:
  enabled: true
  kind: oneshot
---

Body.
`)
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}

	enableDaemonSession(t, "http://127.0.0.1:1")

	cmd := newSessionSetCmd()
	cmd.SetArgs([]string{"session-fiber", "worker-session", "--agent", "codex"})
	if err := cmd.Execute(); err == nil {
		t.Fatalf("expected daemon transport error")
	}

	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fiber: %v", err)
	}
	if !bytes.Equal(before, after) {
		t.Fatalf("session command must not fall back to frontmatter writes. before:\n%s\nafter:\n%s", before, after)
	}
}

func enableDaemonSession(t *testing.T, url string) {
	t.Helper()
	prevOffline, hadOffline := os.LookupEnv("SHUTTLE_SESSION_OFFLINE")
	prevURL, hadURL := os.LookupEnv("SHUTTLE_DAEMON_URL")

	_ = os.Unsetenv("SHUTTLE_SESSION_OFFLINE")
	_ = os.Setenv("SHUTTLE_DAEMON_URL", url)

	t.Cleanup(func() {
		if hadOffline {
			_ = os.Setenv("SHUTTLE_SESSION_OFFLINE", prevOffline)
		} else {
			_ = os.Unsetenv("SHUTTLE_SESSION_OFFLINE")
		}
		if hadURL {
			_ = os.Setenv("SHUTTLE_DAEMON_URL", prevURL)
		} else {
			_ = os.Unsetenv("SHUTTLE_DAEMON_URL")
		}
	})
}
