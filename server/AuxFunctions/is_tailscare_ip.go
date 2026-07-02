package is_tailscale_ip

import "net/netip"

var tailscalePrefix = netip.MustParsePrefix("100.64.0.0/10")

func is_tailscale_ip(ip string) bool {
	addr, err := netip.ParseAddr(ip)
	if err != nil {
		return false
	}

	return tailscalePrefix.Contains(addr)
}