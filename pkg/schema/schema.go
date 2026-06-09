// Package schema provides types, validation, and YAML I/O for the shuttle:
// frontmatter block written by the shuttle CLI.
package schema

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/robfig/cron/v3"
	"gopkg.in/yaml.v3"
)

// ---- Types -----------------------------------------------------------------

// Block is the in-memory representation of the shuttle: YAML block.
// Fields mirror the JSON schema at share/schema.json. There is no enabled flag
// and no review axis: a fiber is shuttle-managed iff it carries this block, and
// it dispatches iff the felt-native status is "active". Lifecycle is status +
// tempered, uniform across kinds (slice 5: enabled/review dropped).
type Block struct {
	Kind       string    `json:"kind" yaml:"kind"`
	Host       string    `json:"host,omitempty" yaml:"host,omitempty"`
	ProjectDir string    `json:"project_dir,omitempty" yaml:"project_dir,omitempty"`
	Agent      string    `json:"agent,omitempty" yaml:"agent,omitempty"`
	Schedule   *Schedule `json:"schedule,omitempty" yaml:"schedule,omitempty"`
}

// Schedule holds the recurrence definition for a standing role.
type Schedule struct {
	Expr string `json:"expr" yaml:"expr"`
	TZ   string `json:"tz" yaml:"tz"`
}

// UnmarshalYAML accepts the canonical `tz` field as well as the legacy
// `timezone` alias used by pre-CLI standing-role frontmatter. Pre-CLI blocks
// also carried `kind: cron` on the schedule itself; we silently drop it (the
// outer `kind:` field on Block carries the role kind in the new schema).
// Output always uses `tz` so the legacy alias is rewritten on the next save.
func (s *Schedule) UnmarshalYAML(value *yaml.Node) error {
	var aux struct {
		Expr     string `yaml:"expr"`
		TZ       string `yaml:"tz"`
		Timezone string `yaml:"timezone"`
		Kind     string `yaml:"kind"` // legacy: ignored
	}
	if err := value.Decode(&aux); err != nil {
		return err
	}
	s.Expr = aux.Expr
	s.TZ = aux.TZ
	if s.TZ == "" {
		s.TZ = aux.Timezone
	}
	return nil
}

// UnmarshalJSON accepts the canonical `tz` field as well as the legacy
// `timezone` alias used by pre-CLI standing-role frontmatter serialized
// through felt's JSON view.
func (s *Schedule) UnmarshalJSON(data []byte) error {
	var aux struct {
		Expr     string `json:"expr"`
		TZ       string `json:"tz"`
		Timezone string `json:"timezone"`
		Kind     string `json:"kind"` // legacy: ignored
	}
	if err := json.Unmarshal(data, &aux); err != nil {
		return err
	}
	s.Expr = aux.Expr
	s.TZ = aux.TZ
	if s.TZ == "" {
		s.TZ = aux.Timezone
	}
	return nil
}

// UnmarshalJSON accepts the canonical `kind` field as well as the legacy
// `mode` alias used by pre-CLI shuttle blocks serialized through felt's JSON
// view. Output always normalizes to `Kind`. Legacy daemon-owned fields
// (enabled, review, next_due_at, last_run_at, session) and the retired
// `interactive` axis are NOT decoded — clean cutover, no read-tolerance: a felt
// JSON view that still carries them simply ignores them, and the next Go rewrite
// wipes them. Interactivity is no longer a dispatch mode — per-dispatch intent
// rides the From User directive, structural human-gates live in the constitution
// text, and resume-from-kanban is the universal way to talk to a worker. Resume
// reads the session id from felt history, not a doc-resident block.
func (b *Block) UnmarshalJSON(data []byte) error {
	var aux struct {
		Kind       string    `json:"kind"`
		Mode       string    `json:"mode"`
		Host       string    `json:"host"`
		ProjectDir string    `json:"project_dir"`
		Agent      string    `json:"agent"`
		Schedule   *Schedule `json:"schedule"`
	}
	if err := json.Unmarshal(data, &aux); err != nil {
		return err
	}
	b.Kind = aux.Kind
	if b.Kind == "" {
		b.Kind = aux.Mode
	}
	b.Host = aux.Host
	b.ProjectDir = aux.ProjectDir
	b.Agent = aux.Agent
	b.Schedule = aux.Schedule
	return nil
}

// ValidKinds enumerates the allowed kind values.
var ValidKinds = []string{"oneshot", "standing"}

// ---- Validation ------------------------------------------------------------

// ValidationError collects field-level errors.
type ValidationError struct {
	Field   string
	Message string
}

func (e ValidationError) Error() string {
	return fmt.Sprintf("%s: %s", e.Field, e.Message)
}

// ValidationErrors is a slice of validation errors.
type ValidationErrors []ValidationError

func (errs ValidationErrors) Error() string {
	msgs := make([]string, len(errs))
	for i, e := range errs {
		msgs[i] = e.Error()
	}
	return strings.Join(msgs, "\n")
}

// Validate checks a Block for correctness. Returns nil when valid.
// Accepts an Agents registry for agent-name validation; may be nil to skip.
func Validate(b *Block, agents *AgentRegistry) ValidationErrors {
	var errs ValidationErrors
	add := func(field, msg string) {
		errs = append(errs, ValidationError{Field: field, Message: msg})
	}

	if !contains(ValidKinds, b.Kind) {
		add("kind", fmt.Sprintf("must be one of %v, got %q", ValidKinds, b.Kind))
	}

	if b.Agent != "" && agents != nil {
		if _, ok := agents.Find(b.Agent); !ok {
			ids := agents.IDs()
			add("agent", fmt.Sprintf("unknown agent %q (known: %s)", b.Agent, strings.Join(ids, ", ")))
		}
	}

	if b.Kind == "standing" {
		if b.Schedule == nil {
			add("schedule", "required for kind=standing")
		} else {
			if err := ValidateCron(b.Schedule.Expr); err != nil {
				add("schedule.expr", err.Error())
			}
			if b.Schedule.TZ == "" {
				add("schedule.tz", "required")
			} else if _, err := time.LoadLocation(b.Schedule.TZ); err != nil {
				add("schedule.tz", fmt.Sprintf("unknown timezone %q: %v", b.Schedule.TZ, err))
			}
		}
	}

	return errs
}

// ValidateCron checks that expr is a valid 5-field standard cron expression.
func ValidateCron(expr string) error {
	_, err := cron.NewParser(cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow).Parse(expr)
	if err != nil {
		return fmt.Errorf("invalid cron expression %q: %w", expr, err)
	}
	return nil
}

// NextOccurrence returns the next scheduled time after `after`, using the
// cron expression and IANA timezone from the schedule.
func NextOccurrence(s *Schedule, after time.Time) (time.Time, error) {
	loc, err := time.LoadLocation(s.TZ)
	if err != nil {
		return time.Time{}, fmt.Errorf("loading timezone %q: %w", s.TZ, err)
	}

	sched, err := cron.NewParser(cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow).Parse(s.Expr)
	if err != nil {
		return time.Time{}, fmt.Errorf("parsing cron %q: %w", s.Expr, err)
	}

	// cron library works in the location of the time passed to Next().
	// Convert after to the target timezone so the schedule fires at local wall time.
	localAfter := after.In(loc)
	next := sched.Next(localAfter)
	return next, nil
}

// ---- Helpers ---------------------------------------------------------------

func contains(slice []string, s string) bool {
	for _, v := range slice {
		if v == s {
			return true
		}
	}
	return false
}

// StringPtr returns a pointer to s.
func StringPtr(s string) *string { return &s }
