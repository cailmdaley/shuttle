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
