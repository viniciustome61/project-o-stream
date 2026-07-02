package best_lan_ip_for_client

import "same_lan_layer"

func best_lan_ip_for_client(clientIP string, lanIPs []string) string {
	for _, lanIP := range lanIPs {
		if same_lan_layer(clientIP, lanIP) {
			return lanIP
		}
	}

	if len(lanIPs) > 0 {
		return lanIPs[0]
	}

	return ""
}