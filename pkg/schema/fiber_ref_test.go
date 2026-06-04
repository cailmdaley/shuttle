package schema_test

import (
	"os"
	"path/filepath"
	"testing"

	. "github.com/cailmdaley/shuttle/pkg/schema"
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

func TestResolveFiberInHost_FlatFiberInSymlinkedStore(t *testing.T) {
	// candide's sp-validation-restructuring shape: a ROOT-flat fiber in a
	// project's own .felt, mounted into loom as a symlinked sub-store. Queried by
	// its loom-traversal id (`sp_validation/sp-validation-restructuring` — what
	// felt returns for the bare leaf), the path is the flat `<sub>/<leaf>.md`.
	// Before the fix, exactFiberPath only built the dir layout for multi-segment
	// ids, so this 422'd "resolved to ID … but file not found".
	loom := t.TempDir()
	project := t.TempDir()

	projFelt := filepath.Join(project, ".felt")
	flat := filepath.Join(projFelt, "sp-validation-restructuring.md")
	writeFiberFile(t, flat)

	if err := os.MkdirAll(filepath.Join(loom, ".felt"), 0o755); err != nil {
		t.Fatalf("mkdir loom .felt: %v", err)
	}
	if err := os.Symlink(projFelt, filepath.Join(loom, ".felt", "sp_validation")); err != nil {
		t.Fatalf("symlink sub-store: %v", err)
	}

	ref, err := ResolveFiberInHost(loom, "sp_validation/sp-validation-restructuring")
	if err != nil {
		t.Fatalf("ResolveFiberInHost (flat in symlinked store): %v", err)
	}
	wantPath, err := filepath.EvalSymlinks(flat)
	if err != nil {
		t.Fatalf("EvalSymlinks: %v", err)
	}
	if ref.Path != wantPath {
		t.Fatalf("path = %q, want %q", ref.Path, wantPath)
	}
	// Canonical id is the project-relative (root-flat) slug.
	if ref.ID != "sp-validation-restructuring" {
		t.Fatalf("id = %q, want %q", ref.ID, "sp-validation-restructuring")
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
