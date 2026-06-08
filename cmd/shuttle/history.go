package main

import (
	"encoding/json"
	"os/exec"
	"regexp"
)

// appendFeltHistory shells out to `felt -C <host> history append <fiberID>
// --summary <msg>`. Errors are silently ignored — history is best-effort;
// the primary mutation already succeeded.
func appendFeltHistory(host, fiberID, summary string) error {
	if host == "" {
		return nil
	}
	cmd := exec.Command("felt", "-C", host, "history", "append", fiberID, "--summary", summary)
	_ = cmd.Run()
	return nil
}

// appendFeltHistoryReviewComment files a `--kind review-comment` event so the
// dispatcher's check_resume_intent/3 can read resume_mode from the latest event.
// Summary may be empty (felt ≥ commit 4166815 accepts --summary "").
func appendFeltHistoryReviewComment(host, fiberID, summary, resumeMode string) error {
	if host == "" {
		return nil
	}
	cmd := exec.Command("felt", "-C", host, "history", "append", fiberID,
		"--kind", "review-comment",
		"--summary", summary,
		"--field", "resume_mode="+resumeMode,
	)
	_ = cmd.Run()
	return nil
}

// sessionIDPattern mirrors the dispatcher's Elixir extract_session_id/1 regex.
// The "<unknown>" sentinel (written when a dispatch couldn't capture a session
// id) carries `<`/`>`, which are absent from the character class, so it never
// matches — a session-less dispatch is correctly not resumable.
var sessionIDPattern = regexp.MustCompile(`(?:^|\s)session=([A-Za-z0-9._:-]+)`)

// extractSessionID pulls a worker session id out of a history event's text,
// mirroring the dispatcher's extract_session_id/1. Returns "" when the text
// carries no resumable session marker.
func extractSessionID(text string) string {
	m := sessionIDPattern.FindStringSubmatch(text)
	if m == nil || m[1] == "<unknown>" {
		return ""
	}
	return m[1]
}

// latestResumableSessionID returns the most recent worker session id recorded in
// the fiber's felt history, or "" when none is resumable. It scans the last 20
// events for a `session=<id>` marker (written by the "worker dispatched" event),
// mirroring the dispatcher's latest_history_session_id/1 so the arm path and the
// dispatcher agree on what "has a prior session" means.
//
// This is the resume arm path's guard against manufacturing a permanent block:
// arming a never-run fiber must not file `resume_mode: previous` (it would
// resolve to {:error, :missing_session_id} in the dispatcher and re-fail on
// every poll, forever). With no resumable session, the caller files `fresh`.
func latestResumableSessionID(host, fiberID string) string {
	if host == "" {
		return ""
	}
	out, err := exec.Command("felt", "-C", host, "history", fiberID,
		"--last", "20", "--json").Output()
	if err != nil {
		return ""
	}
	var events []struct {
		Payload struct {
			Text string `json:"text"`
		} `json:"payload"`
	}
	if err := json.Unmarshal(out, &events); err != nil {
		return ""
	}
	for _, e := range events {
		if id := extractSessionID(e.Payload.Text); id != "" {
			return id
		}
	}
	return ""
}
