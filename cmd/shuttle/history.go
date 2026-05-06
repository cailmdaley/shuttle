package main

import "os/exec"

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
