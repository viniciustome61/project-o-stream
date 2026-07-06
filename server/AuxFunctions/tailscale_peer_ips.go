package tailscale_peer_ips

import (
	"encoding/json"
	"os/exec"
	"slices"
	"is_tailscale_ip"
)

type TailscaleStatus struct {
	Peer map[string]TailscalePeer `json:"Peer"`
}

type TailscalePeer struct {
	Online       bool     `json:"Online"`
	TailscaleIPs []string `json:"TailscaleIPs"`
}

func tailscale_peer_ips(selfIP string) []string {
	cmd := exec.Command("tailscale", "status", "--json")

	output, err := cmd.Output()
	if err != nil {
		return []string{}
	}

	var status TailscaleStatus
	if err := json.Unmarshal(output, &status); err != nil {
		return []string{}
	}

	var peerIPs []string

	for _, peer := range status.Peer {
		if !peer.Online {
			continue
		}

		for _, ip := range peer.TailscaleIPs {
			if is_tailscale_ip(ip) &&
				ip != selfIP &&
				!slices.Contains(peerIPs, ip) {

				peerIPs = append(peerIPs, ip)
			}
		}
	}

	return peerIPs
}