package same_lan_layer

import (
	"net/netip"
	"is_lan_ip"
)
func sameLanLayer(left, right string) bool {
	leftAddr, err := netip.ParseAddr(left)
	if err != nil {
		return false
	}

	rightAddr, err := netip.ParseAddr(right)
	if err != nil {
		return false
	}

	if !leftAddr.Is4() || !rightAddr.Is4() {
		return false
	}

	if !is_lan_ip(left) || !is_lan_ip(right) {
		return false
	}

	leftParts := strings.Split(left, ".")
	rightParts := strings.Split(right, ".")

	return leftParts[0] == rightParts[0] &&
		leftParts[1] == rightParts[1] &&
		leftParts[2] == rightParts[2]
}