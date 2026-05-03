package main

import (
	"fmt"
	"os"
)

func main() {
	if err := rootCmd.Execute(); err != nil {
		// For "invalid input" we already printed a clear message; others are unexpected.
		if err.Error() != "invalid input" {
			fmt.Fprintln(os.Stderr, "shuttle:", err)
		}
		os.Exit(1)
	}
}
