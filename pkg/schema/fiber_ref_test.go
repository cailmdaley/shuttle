package schema_test

import (
	"os"
	"path/filepath"
	"testing"

	. "github.com/cailmdaley/shuttle-cli/pkg/schema"
)

func writeFiberFile(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte("---\nname: test\n---\n"), 0o644); err != nil {
		t.Fatalf("write fiber: %v", err)
	}
}

func TestFiberRefFromPath_DirectoryFiber(t *testing.T) {
	host := t.TempDir()
	path := filepath.Join(host, ".felt", "ai-futures", "portolan", "kanban-modal", "kanban-modal.md")
	writeFiberFile(t, path)

	gotHost, gotID, err := FiberRefFromPath(path)
	if err != nil {
		t.Fatalf("FiberRefFromPath: %v", err)
	}
	wantHost, err := filepath.EvalSymlinks(host)
	if err != nil {
		t.Fatalf("EvalSymlinks(host): %v", err)
	}
	if gotHost != wantHost {
		t.Fatalf("host = %q, want %q", gotHost, wantHost)
	}
	if gotID != "ai-futures/portolan/kanban-modal" {
		t.Fatalf("id = %q, want %q", gotID, "ai-futures/portolan/kanban-modal")
	}
}

func TestFiberRefFromPath_RootFiber(t *testing.T) {
	host := t.TempDir()
	path := filepath.Join(host, ".felt", "portolan.md")
	writeFiberFile(t, path)

	gotHost, gotID, err := FiberRefFromPath(path)
	if err != nil {
		t.Fatalf("FiberRefFromPath: %v", err)
	}
	wantHost, err := filepath.EvalSymlinks(host)
	if err != nil {
		t.Fatalf("EvalSymlinks(host): %v", err)
	}
	if gotHost != wantHost {
		t.Fatalf("host = %q, want %q", gotHost, wantHost)
	}
	if gotID != "portolan" {
		t.Fatalf("id = %q, want %q", gotID, "portolan")
	}
}

func TestResolveFiberInHost_CanonicalizesSymlinkedProjectView(t *testing.T) {
	loom := t.TempDir()
	projectRoot := filepath.Join(t.TempDir(), "portolan")
	if err := os.MkdirAll(projectRoot, 0o755); err != nil {
		t.Fatalf("mkdir project root: %v", err)
	}

	canonicalPath := filepath.Join(
		loom,
		".felt",
		"ai-futures",
		"portolan",
		"kanban-modal",
		"kanban-modal.md",
	)
	writeFiberFile(t, canonicalPath)

	target := filepath.Join(loom, ".felt", "ai-futures", "portolan")
	if err := os.Symlink(target, filepath.Join(projectRoot, ".felt")); err != nil {
		t.Fatalf("symlink project .felt: %v", err)
	}

	ref, err := ResolveFiberInHost(projectRoot, "kanban-modal")
	if err != nil {
		t.Fatalf("ResolveFiberInHost: %v", err)
	}
	wantHost, err := filepath.EvalSymlinks(loom)
	if err != nil {
		t.Fatalf("EvalSymlinks(loom): %v", err)
	}
	if ref.Host != wantHost {
		t.Fatalf("host = %q, want %q", ref.Host, wantHost)
	}
	if ref.ID != "ai-futures/portolan/kanban-modal" {
		t.Fatalf("id = %q, want %q", ref.ID, "ai-futures/portolan/kanban-modal")
	}
	wantPath, err := filepath.EvalSymlinks(canonicalPath)
	if err != nil {
		t.Fatalf("EvalSymlinks(canonicalPath): %v", err)
	}
	if ref.Path != wantPath {
		t.Fatalf("path = %q, want %q", ref.Path, wantPath)
	}
}
