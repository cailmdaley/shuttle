package schema_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	. "github.com/cailmdaley/shuttle-cli/pkg/schema"
)

// ---- Validation tests -------------------------------------------------------

func TestValidate_ValidOneshot(t *testing.T) {
	b := &Block{Enabled: true, Kind: "oneshot"}
	if errs := Validate(b, nil); len(errs) != 0 {
		t.Fatalf("expected no errors, got: %v", errs)
	}
}

func TestValidate_ValidStanding(t *testing.T) {
	b := &Block{
		Enabled: true,
		Kind:    "standing",
		Schedule: &Schedule{Expr: "0 9 * * 1-5", TZ: "Europe/Paris"},
		Review:   &Review{State: "scheduled"},
	}
	if errs := Validate(b, nil); len(errs) != 0 {
		t.Fatalf("expected no errors, got: %v", errs)
	}
}

func TestValidate_BadCron(t *testing.T) {
	b := &Block{
		Enabled:  true,
		Kind:     "standing",
		Schedule: &Schedule{Expr: "0 25 * * *", TZ: "UTC"},
	}
	errs := Validate(b, nil)
	if len(errs) == 0 {
		t.Fatal("expected validation error for invalid cron")
	}
	if !strings.Contains(errs[0].Field, "schedule.expr") {
		t.Fatalf("expected schedule.expr error, got field=%q", errs[0].Field)
	}
}

func TestValidate_BadTimezone(t *testing.T) {
	b := &Block{
		Enabled:  true,
		Kind:     "standing",
		Schedule: &Schedule{Expr: "0 9 * * *", TZ: "Atlantis/Bermuda"},
	}
	errs := Validate(b, nil)
	if len(errs) == 0 {
		t.Fatal("expected validation error for unknown timezone")
	}
	if !strings.Contains(errs[0].Field, "schedule.tz") {
		t.Fatalf("expected schedule.tz error, got field=%q", errs[0].Field)
	}
}

func TestValidate_MissingScheduleForStanding(t *testing.T) {
	b := &Block{Enabled: true, Kind: "standing"}
	errs := Validate(b, nil)
	if len(errs) == 0 {
		t.Fatal("expected error: schedule required for standing")
	}
}

func TestValidate_BadKind(t *testing.T) {
	b := &Block{Enabled: true, Kind: "weekly"}
	errs := Validate(b, nil)
	if len(errs) == 0 {
		t.Fatal("expected validation error for unknown kind")
	}
}

// ---- Cron next occurrence ---------------------------------------------------

func TestNextOccurrence(t *testing.T) {
	s := &Schedule{Expr: "0 9 * * 1-5", TZ: "Europe/Paris"}
	// Use a reference time: Monday 2026-05-04 08:00 Paris time.
	paris, _ := time.LoadLocation("Europe/Paris")
	after := time.Date(2026, 5, 4, 6, 0, 0, 0, time.UTC) // 08:00 Paris
	next, err := NextOccurrence(s, after)
	if err != nil {
		t.Fatalf("NextOccurrence error: %v", err)
	}
	if next.In(paris).Hour() != 9 {
		t.Fatalf("expected hour=9, got %d", next.In(paris).Hour())
	}
}

// ---- YAML round-trip --------------------------------------------------------

const sampleFiber = `---
name: Test Fiber
status: active
tags:
  - constitution
  - test
created-at: 2026-01-01T00:00:00Z
outcome: testing
---

Body text here.
`

const sampleFiberWithShuttle = `---
name: Standing Test
status: active
tags:
  - constitution
  - standing
created-at: 2026-01-01T00:00:00Z
shuttle:
  mode: standing
  schedule:
    kind: cron
    expr: "0 9 * * 1-5"
    timezone: Europe/Paris
  review:
    state: scheduled
    run_id: null
  next_due_at: "2099-01-01T09:00:00+01:00"
---

Body.
`

func writeTmpFiber(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "fiber.md")
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatalf("writing temp fiber: %v", err)
	}
	return path
}

func TestReadFiber_NoShuttleBlock(t *testing.T) {
	path := writeTmpFiber(t, sampleFiber)
	f, err := ReadFiber(path)
	if err != nil {
		t.Fatalf("ReadFiber: %v", err)
	}
	if f.Block != nil {
		t.Fatalf("expected nil Block for fiber without shuttle: block")
	}
}

func TestReadFiber_OldFormatShuttleBlock(t *testing.T) {
	path := writeTmpFiber(t, sampleFiberWithShuttle)
	f, err := ReadFiber(path)
	if err != nil {
		t.Fatalf("ReadFiber: %v", err)
	}
	if f.Block == nil {
		t.Fatal("expected non-nil Block")
	}
	// Old format: kind="" (was mode=standing), TZ="" (was timezone=)
	if f.Block.Kind != "" {
		t.Logf("Block.Kind=%q (old format uses mode not kind)", f.Block.Kind)
	}
}

func TestWriteBlock_PreservesNonShuttleFrontmatter(t *testing.T) {
	path := writeTmpFiber(t, sampleFiber)
	f, err := ReadFiber(path)
	if err != nil {
		t.Fatalf("ReadFiber: %v", err)
	}

	block := &Block{
		Enabled: true,
		Kind:    "oneshot",
	}
	if err := f.WriteBlock(block); err != nil {
		t.Fatalf("WriteBlock: %v", err)
	}

	// Re-read and check.
	f2, err := ReadFiber(path)
	if err != nil {
		t.Fatalf("re-read: %v", err)
	}
	if f2.Block == nil {
		t.Fatal("expected shuttle block after write")
	}
	if !f2.Block.Enabled {
		t.Fatal("expected enabled=true")
	}
	if f2.Block.Kind != "oneshot" {
		t.Fatalf("expected kind=oneshot, got %q", f2.Block.Kind)
	}

	// Check body preserved.
	raw, _ := os.ReadFile(path)
	if !strings.Contains(string(raw), "Body text here.") {
		t.Fatal("body text was lost after WriteBlock")
	}
	// Check non-shuttle frontmatter preserved.
	if !strings.Contains(string(raw), "name: Test Fiber") {
		t.Fatal("name field lost after WriteBlock")
	}
}

func TestWriteBlock_Uninstall(t *testing.T) {
	path := writeTmpFiber(t, sampleFiber)
	f, _ := ReadFiber(path)
	block := &Block{Enabled: true, Kind: "oneshot"}
	_ = f.WriteBlock(block)

	// Now uninstall (nil block).
	f2, _ := ReadFiber(path)
	if err := f2.WriteBlock(nil); err != nil {
		t.Fatalf("WriteBlock(nil): %v", err)
	}

	raw, _ := os.ReadFile(path)
	if strings.Contains(string(raw), "shuttle:") {
		t.Fatal("shuttle: key still present after uninstall")
	}
}

func TestWriteBlock_AtomicOnBadWrite(t *testing.T) {
	path := writeTmpFiber(t, sampleFiber)
	original, _ := os.ReadFile(path)

	f, _ := ReadFiber(path)
	// Corrupt the block to force an error during encoding... actually,
	// we can't easily simulate a mid-write crash here. Instead, verify
	// that after a successful write the file is complete (not truncated).
	block := &Block{Enabled: true, Kind: "standing", Schedule: &Schedule{Expr: "0 9 * * 1-5", TZ: "UTC"}}
	if err := f.WriteBlock(block); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	after, _ := os.ReadFile(path)
	if len(after) == 0 {
		t.Fatal("file was truncated")
	}
	// Original body still present.
	if !strings.Contains(string(after), "Body text here.") {
		t.Logf("original:\n%s", original)
		t.Logf("after:\n%s", after)
		t.Fatal("body lost after write")
	}
}

// ---- Agent registry ---------------------------------------------------------

func TestAgentRegistry_FindByID(t *testing.T) {
	reg := &AgentRegistry{}
	// Build a minimal registry via LoadAgentRegistryFromFile on a temp JSON.
	dir := t.TempDir()
	agentJSON := `[{"id":"test-agent","cli":"test","wrapper":"test","aliases":[],"default":true}]`
	agentsPath := filepath.Join(dir, "agents.json")
	_ = os.WriteFile(agentsPath, []byte(agentJSON), 0644)

	reg, err := LoadAgentRegistryFromFile(agentsPath)
	if err != nil {
		t.Fatalf("LoadAgentRegistryFromFile: %v", err)
	}
	a, ok := reg.Find("test-agent")
	if !ok {
		t.Fatal("expected to find test-agent")
	}
	if a.ID != "test-agent" {
		t.Fatalf("expected id=test-agent, got %q", a.ID)
	}
}

func TestAgentRegistry_FindByAlias(t *testing.T) {
	dir := t.TempDir()
	agentJSON := `[{"id":"my-agent","cli":"cli","wrapper":"w","aliases":["shortname"],"default":false}]`
	_ = os.WriteFile(filepath.Join(dir, "agents.json"), []byte(agentJSON), 0644)
	reg, _ := LoadAgentRegistryFromFile(filepath.Join(dir, "agents.json"))

	_, ok := reg.Find("shortname")
	if !ok {
		t.Fatal("expected to find by alias 'shortname'")
	}
}

func TestValidate_UnknownAgent(t *testing.T) {
	dir := t.TempDir()
	agentJSON := `[{"id":"known","cli":"cli","wrapper":"w","aliases":[],"default":true}]`
	_ = os.WriteFile(filepath.Join(dir, "agents.json"), []byte(agentJSON), 0644)
	agents, _ := LoadAgentRegistryFromFile(filepath.Join(dir, "agents.json"))

	b := &Block{Enabled: true, Kind: "oneshot", Agent: "unknown-agent"}
	errs := Validate(b, agents)
	if len(errs) == 0 {
		t.Fatal("expected validation error for unknown agent")
	}
	if errs[0].Field != "agent" {
		t.Fatalf("expected field=agent, got %q", errs[0].Field)
	}
}

// ---- Status helpers --------------------------------------------------------

func TestStatus_Present(t *testing.T) {
	path := writeTmpFiber(t, sampleFiber) // sampleFiber has status: active
	f, err := ReadFiber(path)
	if err != nil {
		t.Fatalf("ReadFiber: %v", err)
	}
	if got := f.Status(); got != "active" {
		t.Fatalf("expected status=active, got %q", got)
	}
}

func TestStatus_Missing(t *testing.T) {
	noStatus := `---
name: No Status Fiber
tags:
  - constitution
created-at: 2026-01-01T00:00:00Z
---

Body.
`
	path := writeTmpFiber(t, noStatus)
	f, err := ReadFiber(path)
	if err != nil {
		t.Fatalf("ReadFiber: %v", err)
	}
	if got := f.Status(); got != "" {
		t.Fatalf("expected empty status for missing field, got %q", got)
	}
}

func TestSetStatus_AddsField(t *testing.T) {
	noStatus := `---
name: No Status Fiber
tags:
  - constitution
created-at: 2026-01-01T00:00:00Z
---

Body.
`
	path := writeTmpFiber(t, noStatus)
	f, err := ReadFiber(path)
	if err != nil {
		t.Fatalf("ReadFiber: %v", err)
	}
	f.SetStatus("active")
	if err := f.WriteBlock(nil); err != nil {
		t.Fatalf("WriteBlock: %v", err)
	}

	// Re-read and verify.
	f2, err := ReadFiber(path)
	if err != nil {
		t.Fatalf("re-read: %v", err)
	}
	if got := f2.Status(); got != "active" {
		t.Fatalf("expected status=active after SetStatus, got %q", got)
	}

	// Confirm body and other fields are preserved.
	raw, _ := os.ReadFile(path)
	if !strings.Contains(string(raw), "Body.") {
		t.Fatal("body lost after SetStatus")
	}
	if !strings.Contains(string(raw), "name: No Status Fiber") {
		t.Fatal("name field lost after SetStatus")
	}
}

func TestSetStatus_OverwritesExisting(t *testing.T) {
	path := writeTmpFiber(t, sampleFiber) // status: active
	f, err := ReadFiber(path)
	if err != nil {
		t.Fatalf("ReadFiber: %v", err)
	}
	f.SetStatus("closed")
	if err := f.WriteBlock(nil); err != nil {
		t.Fatalf("WriteBlock: %v", err)
	}

	f2, err := ReadFiber(path)
	if err != nil {
		t.Fatalf("re-read: %v", err)
	}
	if got := f2.Status(); got != "closed" {
		t.Fatalf("expected status=closed after SetStatus, got %q", got)
	}
}

func TestSetStatus_RoundTripsWithBlock(t *testing.T) {
	// Confirm SetStatus + WriteBlock(non-nil) writes both atomically.
	noStatus := `---
name: No Status Fiber
tags:
  - constitution
created-at: 2026-01-01T00:00:00Z
---

Body.
`
	path := writeTmpFiber(t, noStatus)
	f, err := ReadFiber(path)
	if err != nil {
		t.Fatalf("ReadFiber: %v", err)
	}
	f.SetStatus("active")
	block := &Block{Enabled: true, Kind: "oneshot"}
	if err := f.WriteBlock(block); err != nil {
		t.Fatalf("WriteBlock: %v", err)
	}

	f2, err := ReadFiber(path)
	if err != nil {
		t.Fatalf("re-read: %v", err)
	}
	if got := f2.Status(); got != "active" {
		t.Fatalf("expected status=active, got %q", got)
	}
	if f2.Block == nil || !f2.Block.Enabled || f2.Block.Kind != "oneshot" {
		t.Fatalf("expected shuttle block enabled+oneshot, got %+v", f2.Block)
	}
}
