package batt_bar

import (
	"math"
	"strings"
)

func batt_bar(pct float64, width int) string {
	filled := int(math.Round(pct * float64(width)))

	return strings.Repeat("▮", filled) +
		strings.Repeat("▯", width-filled)
}