package main

import (
	"os/exec"

	"github.com/cailmdaley/shuttle-cli/pkg/schema"
)

// appendFeltHistory shells out to `felt history append <fiberID> --summary <msg>`.
// Errors are silently ignored — history is best-effort; the primary mutation
// already succeeded.
func appendFeltHistory(fiberID, summary string) error {
	host, err := schema.FeltHost()
	if err != nil {
		return nil // best effort
	}
	cmd := exec.Command("felt", "-C", host, "history", "append", fiberID, "--summary", summary)
	_ = cmd.Run()
	return nil
}
