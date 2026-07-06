package windows_lan_ips

import (
	"os/exec"
	"strings"
	"add_lan_candidate"
)

func windows_lan_ips() []string {
	cmd := exec.Command(
		"powershell",
		"-NoProfile",
		"-Command",
		`Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
		Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.|100\.)' } |
		Sort-Object InterfaceMetric,PrefixLength |
		Select-Object -ExpandProperty IPAddress`,
	)

	output, err := cmd.Output()
	if err != nil {
		return []string{}
	}

	var ips []string

	for _, line := range strings.Split(string(output), "\n") {
		ip := strings.TrimSpace(line)
		if ip != "" {
			ips = add_lan_candidates(ips, ip)
		}
	}

	return ips
}