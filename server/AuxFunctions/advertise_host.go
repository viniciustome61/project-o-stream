package advertise_host

import (
	"best_lan_ip_for_client"
	"is_lan_ip"
	"is_tailscale_ip"
)

func advertise_host(probeSourceIP string, lanIPs []string, tailscaleIP string) string {
	lanIP := best_lan_ip_for_client(probeSourceIP, lanIPs)

	if is_lan_ip(probeSourceIP) && lanIP != "" {
		return lanIP
	}

	if is_tailscale_ip(probeSourceIP) && tailscaleIP != "" {
		return tailscaleIP
	}

	if lanIP != "" {
		return lanIP
	}

	if tailscaleIP != "" {
		return tailscaleIP
	}

	return probeSourceIP
}