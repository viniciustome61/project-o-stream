package main

import (
    "sync"
    "time"
)


// Podemos modularizar o receiver.go depois em novos arquivos, depois de converter o que estiver em python para go

type SlotAssigner struct {
	mu sync.Mutex
	slots []*SlotState
	table map[string]SlotEntry
}