package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestResolveOriginURLFromDaemonOrigins(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/origins" {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		w.Write([]byte(`{"origins":[{"name":"local","url":"http://127.0.0.1:4000"},{"name":"candide","url":"http://127.0.0.1:4001"}]}`))
	}))
	defer srv.Close()

	prev := os.Getenv("SHUTTLE_DAEMON_URL")
	os.Setenv("SHUTTLE_DAEMON_URL", srv.URL)
	defer os.Setenv("SHUTTLE_DAEMON_URL", prev)

	got, err := resolveOriginURL("candide")
	if err != nil {
		t.Fatalf("resolveOriginURL: %v", err)
	}
	if got != "http://127.0.0.1:4001" {
		t.Fatalf("got %q", got)
	}
}

func TestResolveOriginURLUnknownListsConfiguredOrigins(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"origins":[{"name":"local","url":"http://127.0.0.1:4000"},{"name":"candide","url":"http://127.0.0.1:4001"}]}`))
	}))
	defer srv.Close()

	prev := os.Getenv("SHUTTLE_DAEMON_URL")
	os.Setenv("SHUTTLE_DAEMON_URL", srv.URL)
	defer os.Setenv("SHUTTLE_DAEMON_URL", prev)

	_, err := resolveOriginURL("nope")
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), `unknown origin "nope"; configured: candide, local`) {
		t.Fatalf("unexpected error: %v", err)
	}
}
