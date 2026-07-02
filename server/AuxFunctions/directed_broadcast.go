package directed_broadcast

import (
	"netip"
	"is_lan_ip"
)

func directed_broadcast(ip string) string {
	addr, err := netip.ParseAddr(ip)
	if err != nil || !addr.Is4() || !is_lan_ip(ip) {
		return ""
	}

	b := addr.As4()
	b[3] = 255

	return netip.AddrFrom4(b).String()
}