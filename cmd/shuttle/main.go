// Command shuttle-ctl is a thin transitional shim: it execs `felt shuttle <args>`,
// forwarding every argument and the full environment.
//
// The dispatch CLI that used to live here was absorbed into felt under the
// `felt shuttle` command group (the shuttle->felt merge, Stage 3): one Go binary,
// one data model, one schema. This binary survives only so the networked daemon's
// `shuttle-ctl` shell-outs (transition.ex, lifecycle_controller.ex, dispatcher.ex)
// and existing muscle memory keep working through the transition. It is deleted
// once nothing references the `shuttle-ctl` name.
//
// syscall.Exec replaces the process image with felt, so exit code, stdio, signals,
// and the environment (e.g. the daemon's SHUTTLE_LIFECYCLE_OFFLINE / SHUTTLE_HOST)
// pass through transparently — the caller cannot tell it didn't run shuttle-ctl
// directly. felt is resolved on PATH, the same PATH the daemon already relies on to
// shell `felt ls` / `felt show` for polling.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"
)

func main() {
	feltPath, err := exec.LookPath("felt")
	if err != nil {
		fmt.Fprintln(os.Stderr,
			"shuttle-ctl: felt not found on PATH — shuttle-ctl is now a shim for `felt shuttle`:", err)
		os.Exit(127)
	}
	// argv[0] is the binary path; the dispatch surface is `felt shuttle <args>`.
	argv := append([]string{feltPath, "shuttle"}, os.Args[1:]...)
	if err := syscall.Exec(feltPath, argv, os.Environ()); err != nil {
		fmt.Fprintln(os.Stderr, "shuttle-ctl: exec felt failed:", err)
		os.Exit(1)
	}
}
