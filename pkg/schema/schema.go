// Package schema provides types, validation, and YAML I/O for the shuttle:
// frontmatter block written by the shuttle CLI.
package schema

import (
	"fmt"
	"strings"
	"time"

	"github.com/robfig/cron/v3"
	"gopkg.in/yaml.v3"
)

// ---- Types -----------------------------------------------------------------

// Block is the in-memory representation of the shuttle: YAML block.
// Fields mirror the JSON schema at share/schema.json.
type Block struct {
	Enabled bool     `yaml:"enabled"`
	Kind    string   `yaml:"kind"`
	Agent   string   `yaml:"agent,omitempty"`
	Schedule *Schedule `yaml:"schedule,omitempty"`
	Review  *Review  `yaml:"review,omitempty"`
	// Session is daemon-owned: written at dispatch time, read at resume time.
	// The CLI preserves it through lifecycle operations (pause/resume/set-model).
	// Set via 'shuttle session-set'; cleared via 'shuttle session-clear'.
	Session *Session `yaml:"session,omitempty"`
	// Daemon-owned: the CLI reads these but only writes them in specific verbs.
	NextDueAt  *time.Time `yaml:"next_due_at,omitempty"`
	LastRunAt  *time.Time `yaml:"last_run_at,omitempty"`
}

// Session holds the most recent dispatch session for resume purposes.
// Written by the Elixir daemon after a successful worker spawn; read at
// the next dispatch to support resume-previous mode.
type Session struct {
	// ID is the harness-native session UUID.
	// - Claude: the UUID passed via --session-id (pre-specified).
	// - Codex/Pi: captured from the session JSONL after dispatch.
	ID           string    `yaml:"id"`
	// Agent is the agent ID used for this session (e.g. "claude-sonnet").
	Agent        string    `yaml:"agent,omitempty"`
	// DispatchedAt is when the session was spawned.
	DispatchedAt time.Time `yaml:"dispatched_at"`
}

// Schedule holds the recurrence definition for a standing role.
type Schedule struct {
	Expr string `yaml:"expr"`
	TZ   string `yaml:"tz"`
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

// Review holds the current review state for a standing role.
type Review struct {
	State         string  `yaml:"state,omitempty"`
	RunID         *string `yaml:"run_id,omitempty"`
	AcceptedRunID *string `yaml:"accepted_run_id,omitempty"`
}

// ValidKinds enumerates the allowed kind values.
var ValidKinds = []string{"oneshot", "standing"}

// ValidReviewStates enumerates the allowed review.state values.
var ValidReviewStates = []string{"scheduled", "running", "awaiting", "accepted", "aborted"}

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

	if b.Review != nil && b.Review.State != "" {
		if !contains(ValidReviewStates, b.Review.State) {
			add("review.state", fmt.Sprintf("must be one of %v, got %q", ValidReviewStates, b.Review.State))
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
