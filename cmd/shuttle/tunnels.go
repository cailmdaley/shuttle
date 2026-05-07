package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"text/template"

	"github.com/cailmdaley/shuttle/pkg/schema"
	"github.com/spf13/cobra"
)

type tunnelSpec struct {
	Name      string
	LocalPort int
}

type tunnelTemplateData struct {
	Label       string
	SSHHost     string
	LocalPort   int
	AutoSSHPath string
	SSHAuthSock string
	LogPath     string
	Home        string
}

var defaultTunnelSpecs = map[string]tunnelSpec{
	"candide": {Name: "candide", LocalPort: 4001},
	"cineca":  {Name: "cineca", LocalPort: 4002},
}

var (
	tunnelsPlistDir  string
	tunnelsLogDir    string
	tunnelsAutoSSH   string
	tunnelsWriteOnly bool
)

var tunnelsCmd = &cobra.Command{
	Use:   "tunnels",
	Short: "Install launchd-managed autossh tunnels for Shuttle remotes",
	Long: `Manage the laptop-side autossh tunnels that map remote Shuttle daemons
onto local ports. The generated plists live under share/launchd/ and are
written into ~/Library/LaunchAgents by default.

Examples:
  shuttle tunnels install              # candide + cineca, write + bootstrap
  shuttle tunnels install candide      # only candide
  shuttle tunnels install --write-only # write plists but don't call launchctl`,
}

var tunnelsInstallCmd = &cobra.Command{
	Use:   "install [candide|cineca ...]",
	Short: "Write and optionally bootstrap launchd plists for Shuttle tunnels",
	Args:  cobra.ArbitraryArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		return installTunnels(args)
	},
}

func installTunnels(requested []string) error {
	specs, err := resolveTunnelSpecs(requested)
	if err != nil {
		return err
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("resolve home dir: %w", err)
	}
	plistDir := tunnelsPlistDir
	if plistDir == "" {
		plistDir = filepath.Join(home, "Library", "LaunchAgents")
	}
	logDir := tunnelsLogDir
	if logDir == "" {
		logDir = filepath.Join(home, ".local", "state", "shuttle")
	}

	autosshPath := tunnelsAutoSSH
	if autosshPath == "" {
		autosshPath, err = exec.LookPath("autossh")
		if err != nil {
			return fmt.Errorf("autossh not found on PATH (install with `brew install autossh` or pass --autossh-path)")
		}
	}

	if err := os.MkdirAll(plistDir, 0o755); err != nil {
		return fmt.Errorf("create plist dir %s: %w", plistDir, err)
	}
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		return fmt.Errorf("create log dir %s: %w", logDir, err)
	}

	tmpl, err := loadTunnelTemplate()
	if err != nil {
		return err
	}

	uid := os.Getuid()
	for _, spec := range specs {
		label := tunnelLabel(spec.Name)
		plistPath := filepath.Join(plistDir, label+".plist")
		logPath := filepath.Join(logDir, fmt.Sprintf("tunnel-%s.log", spec.Name))

		rendered, err := renderTunnelPlist(tmpl, tunnelTemplateData{
			Label:       label,
			SSHHost:     spec.Name,
			LocalPort:   spec.LocalPort,
			AutoSSHPath: autosshPath,
			SSHAuthSock: os.Getenv("SSH_AUTH_SOCK"),
			LogPath:     logPath,
			Home:        home,
		})
		if err != nil {
			return fmt.Errorf("render %s: %w", label, err)
		}
		if err := os.WriteFile(plistPath, rendered, 0o644); err != nil {
			return fmt.Errorf("write %s: %w", plistPath, err)
		}

		fmt.Printf("installed %s -> %s\n", label, plistPath)
		fmt.Printf("  log: %s\n", logPath)

		if tunnelsWriteOnly {
			continue
		}

		target := fmt.Sprintf("gui/%d/%s", uid, label)
		_ = runLaunchctl("bootout", target)
		if err := runLaunchctl("bootstrap", fmt.Sprintf("gui/%d", uid), plistPath); err != nil {
			return fmt.Errorf("bootstrap %s: %w", label, err)
		}
		if err := runLaunchctl("kickstart", "-k", target); err != nil {
			return fmt.Errorf("kickstart %s: %w", label, err)
		}
		fmt.Printf("  bootstrapped %s\n", target)
	}

	return nil
}

func resolveTunnelSpecs(requested []string) ([]tunnelSpec, error) {
	if len(requested) == 0 {
		names := make([]string, 0, len(defaultTunnelSpecs))
		for name := range defaultTunnelSpecs {
			names = append(names, name)
		}
		sort.Strings(names)
		resolved := make([]tunnelSpec, 0, len(names))
		for _, name := range names {
			resolved = append(resolved, defaultTunnelSpecs[name])
		}
		return resolved, nil
	}

	resolved := make([]tunnelSpec, 0, len(requested))
	seen := map[string]bool{}
	for _, name := range requested {
		spec, ok := defaultTunnelSpecs[name]
		if !ok {
			return nil, fmt.Errorf("unknown tunnel %q (supported: candide, cineca)", name)
		}
		if seen[name] {
			continue
		}
		seen[name] = true
		resolved = append(resolved, spec)
	}
	sort.Slice(resolved, func(i, j int) bool { return resolved[i].Name < resolved[j].Name })
	return resolved, nil
}

func loadTunnelTemplate() (*template.Template, error) {
	path, err := schema.FindSharePath(filepath.Join("launchd", "shuttle-tunnel.plist.tmpl"))
	if err != nil {
		return nil, err
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read template %s: %w", path, err)
	}
	return template.New("shuttle-tunnel").Parse(string(content))
}

func renderTunnelPlist(tmpl *template.Template, data tunnelTemplateData) ([]byte, error) {
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, data); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func tunnelLabel(name string) string {
	return fmt.Sprintf("com.cailmdaley.shuttle-tunnel-%s", name)
}

func runLaunchctl(args ...string) error {
	cmd := exec.Command("launchctl", args...)
	out, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}
	msg := string(bytes.TrimSpace(out))
	if msg == "" {
		msg = err.Error()
	}
	return fmt.Errorf("launchctl %v: %s", args, msg)
}

func init() {
	tunnelsInstallCmd.Flags().StringVar(&tunnelsPlistDir, "plist-dir", "", "Directory to write launchd plists into (default: ~/Library/LaunchAgents)")
	tunnelsInstallCmd.Flags().StringVar(&tunnelsLogDir, "log-dir", "", "Directory for autossh logs (default: ~/.local/state/shuttle)")
	tunnelsInstallCmd.Flags().StringVar(&tunnelsAutoSSH, "autossh-path", "", "Path to autossh (default: resolve on PATH)")
	tunnelsInstallCmd.Flags().BoolVar(&tunnelsWriteOnly, "write-only", false, "Write plist files but do not call launchctl bootstrap/kickstart")
	tunnelsCmd.AddCommand(tunnelsInstallCmd)
	rootCmd.AddCommand(tunnelsCmd)
}
