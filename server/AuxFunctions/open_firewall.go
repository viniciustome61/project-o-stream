package open_firewall

import (
	"fmt"
	"os/exec"
)

func openFirewall(port int, proto string) {
	rule := fmt.Sprintf("Project-O-Stream-%s-%d", proto, port)

	cmd := exec.Command(
		"netsh",
		"advfirewall",
		"firewall",
		"show",
		"rule",
		"name="+rule,
	)

	if err := cmd.Run(); err == nil {
		return
	}

	exec.Command(
		"netsh",
		"advfirewall",
		"firewall",
		"add",
		"rule",
		"name="+rule,
		"dir=in",
		"protocol="+strings.ToLower(proto),
		fmt.Sprintf("localport=%d", port),
		"action=allow",
	).Run()
}