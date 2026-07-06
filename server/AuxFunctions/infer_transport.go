
package infer_transport

import (
	"net/netip"
	"is_tailscale_ip"
)

func infer_transport(ip string) string {
	addr, err := netip.ParseAddr(ip)
	if err != nil {
		return "lan"
	}

	if is_tailscale_ip(ip) {
		return "tailscale"
	}

	if addr.IsPrivate() {
		return "lan"
	}

	return "wan"
}