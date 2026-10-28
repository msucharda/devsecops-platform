// Uses the same executable lookup and redirected protocol as Terraform's external provider.
package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"time"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "expected executable and probe script")
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	// The provider probes even absolute paths; exec.Command skips that check for them.
	if _, err := exec.LookPath(os.Args[1]); err != nil && !errors.Is(err, exec.ErrDot) {
		fmt.Fprintln(os.Stderr, "Terraform external-program lookup failed:", err)
		os.Exit(1)
	}
	command := exec.CommandContext(ctx, os.Args[1], "-NoProfile", "-NonInteractive", "-File", os.Args[2])
	// Match the provider's Go 1.19 compatibility handling.
	if errors.Is(command.Err, exec.ErrDot) {
		command.Err = nil
	}
	command.Stdin = bytes.NewBufferString(`{"probe":"local-ci"}`)
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	if err := command.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "Terraform external-program launch failed:", err)
		os.Exit(1)
	}
}
