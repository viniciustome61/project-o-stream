package lan_offer_targets

type OfferTarget struct {
	Host  string
	LanIP string
}

func lan_offer_targets(lanIPs []string) []OfferTarget {
	var targets []OfferTarget

	add := func(host, lanIP string) {
		t := OfferTarget{Host: host, LanIP: lanIP}

		for _, existing := range targets {
			if existing == t {
				return
			}
		}

		targets = append(targets, t)
	}

	for _, lanIP := range lanIPs {
		if broadcast := directed_broadcast(lanIP); broadcast != "" {
			add(broadcast, lanIP)
		}
		add("255.255.255.255", lanIP)
	}

	return targets
}