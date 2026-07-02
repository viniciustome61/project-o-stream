package is_lan_ip

import (
	"fmt"
 	"slices"
)

func is_lan_ip(ip string) bool {
	addr, err := netip.ParseAddr(ip)
	if err != nil {
		return false
	}

	return addr.Is4() &&
		addr.IsPrivate() &&
		!addr.IsLoopback() &&
		!addr.IsLinkLocalUnicast()
}