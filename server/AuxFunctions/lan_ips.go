package lan_ips

import (
	"net"
	"runtime"
	"add_lan_candidates"
)

func lan_ips() []string {
	var ips []string

	if ip, err := defaultRouteIP(); err == nil {
		ips = add_lan_candidates(ips, ip)
	}

	for _, ip := range windowsLanIPs() {
		ips = add_lan_candidates(ips, ip)
	}

	// Windows Mobile Hotspot/ICS geralmente usa 192.168.137.1.
	if runtime.GOOS == "windows" {
		ips = add_lan_candidates(ips, "192.168.137.1")
	}

	hostname, err := net.LookupHost("localhost")
	if err == nil {
		for _, ip := range hostname {
			ips = add_lan_candidates(ips, ip)
		}
	}

	return ips
}