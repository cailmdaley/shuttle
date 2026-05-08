package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolveTunnelSpecs_DefaultsAllSorted(t *testing.T) {
	specs, err := resolveTunnelSpecs(nil)
	if err != nil {
		t.Fatalf("resolveTunnelSpecs(nil): %v", err)
	}
	if len(specs) != 2 {
		t.Fatalf("expected 2 default tunnels, got %d", len(specs))
	}
	if specs[0].Name != "candide" || specs[0].LocalPort != 4001 {
		t.Fatalf("unexpected first spec: %+v", specs[0])
	}
	if specs[0].HoldCommand != "sleep 2147483647" {
		t.Fatalf("expected candide hold command, got %+v", specs[0])
	}
	if specs[1].Name != "cineca" || specs[1].LocalPort != 4002 {
		t.Fatalf("unexpected second spec: %+v", specs[1])
	}
	if specs[1].HoldCommand != "" {
		t.Fatalf("expected cineca to use bare tunnel mode, got %+v", specs[1])
	}
}

func TestInstallTunnels_WriteOnlyWritesPlist(t *testing.T) {
	oldPlistDir, oldLogDir := tunnelsPlistDir, tunnelsLogDir
	oldAutoSSH, oldWriteOnly := tunnelsAutoSSH, tunnelsWriteOnly
	oldSock := os.Getenv("SSH_AUTH_SOCK")
	defer func() {
		tunnelsPlistDir, tunnelsLogDir = oldPlistDir, oldLogDir
		tunnelsAutoSSH, tunnelsWriteOnly = oldAutoSSH, oldWriteOnly
		if oldSock == "" {
			_ = os.Unsetenv("SSH_AUTH_SOCK")
		} else {
			_ = os.Setenv("SSH_AUTH_SOCK", oldSock)
		}
	}()

	tmp := t.TempDir()
	tunnelsPlistDir = filepath.Join(tmp, "LaunchAgents")
	tunnelsLogDir = filepath.Join(tmp, "logs")
	tunnelsAutoSSH = "/opt/homebrew/bin/autossh"
	tunnelsWriteOnly = true
	_ = os.Setenv("SSH_AUTH_SOCK", filepath.Join(tmp, "agent.sock"))

	if err := installTunnels([]string{"candide"}); err != nil {
		t.Fatalf("installTunnels(write-only): %v", err)
	}

	plistPath := filepath.Join(tunnelsPlistDir, "com.cailmdaley.shuttle-tunnel-candide.plist")
	body, err := os.ReadFile(plistPath)
	if err != nil {
		t.Fatalf("read plist: %v", err)
	}
	text := string(body)
	for _, want := range []string{
		"com.cailmdaley.shuttle-tunnel-candide",
		"/opt/homebrew/bin/autossh",
		"<string>-S</string>",
		"<string>none</string>",
		"4001:localhost:4000",
		"sleep 2147483647",
		"ControlMaster=no",
		"ExitOnForwardFailure=yes",
		"IdentityAgent=" + filepath.Join(tmp, "agent.sock"),
		"<key>SSH_AUTH_SOCK</key>",
		filepath.Join(tunnelsLogDir, "tunnel-candide.log"),
		"<key>NetworkState</key>",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("plist missing %q\n%s", want, text)
		}
	}
	if strings.Contains(text, "<string>-N</string>") {
		t.Fatalf("candide plist should use command-mode tunnel, got -N\n%s", text)
	}
}
