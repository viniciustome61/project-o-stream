package tailscale_ip

import (
	"os/exec"
	"strings"
)

func tailscale_ip() (string, error) {
	cmd := exec.Command("tailscale", "ip", "-4")

	output, err := cmd.Output()
	if err != nil {
		return "", err
	}

	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	if len(lines) == 0 || lines[0] == "" {
		return "", nil
	}

	return strings.TrimSpace(lines[0]), nil
}