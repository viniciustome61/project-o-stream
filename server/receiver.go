package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"sync"
	"time"
)

// Constantes do Protocolo (Baseadas no PROTOCOL.md e receiver.py)
const (
	DiscPort      = 7071
	TelePort      = 7075
	ObsStatePort  = 7077
	SlotTTL       = 120 * time.Second
	TeleFresh     = 20 * time.Second
	ProbeBytes    = "PROJECTO_STREAM_DISCOVER"
	NumCameras    = 4
	BaseSRTPort   = 7070
	BaseOBSPort   = 15000
)

// SlotState representa o estado de uma câmara conectada
type SlotState struct {
	mu             sync.RWMutex
	Index          int
	SRTPort        int
	OBSPort        int
	IP             string
	Hostname       string
	Transport      string
	Battery        float64
	Thermal        string
	RTTMs          float64
	Live           bool
	TeleTS         time.Time
	FFmpegStatus   string
	PhoneSlotIndex int
}

// IsConnected verifica se a telemetria é recente e há um IP
func (s *SlotState) IsConnected() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.IP != "" && time.Since(s.TeleTS) < TeleFresh
}

// SlotAssigner mapeia IPs para os Slots disponíveis
type SlotAssigner struct {
	mu    sync.Mutex
	slots []*SlotState
	table map[string]int // Mapeia IP -> Slot Index
}

func NewSlotAssigner(slots []*SlotState) *SlotAssigner {
	return &SlotAssigner{
		slots: slots,
		table: make(map[string]int),
	}
}

// Get encontra um slot existente para o IP ou aloca um novo
func (a *SlotAssigner) Get(ip string) int {
	a.mu.Lock()
	defer a.mu.Unlock()

	// Se já tem slot, devolve
	if idx, exists := a.table[ip]; exists {
		return idx
	}

	// Procura um slot livre (sem IP ou com telemetria expirada)
	for i, slot := range a.slots {
		slot.mu.RLock()
		isFree := slot.IP == "" || time.Since(slot.TeleTS) > SlotTTL
		slot.mu.RUnlock()

		if isFree {
			a.table[ip] = i
			return i
		}
	}

	// Fallback (se tudo estiver cheio, sobrescreve o primeiro)
	a.table[ip] = 0
	return 0
}

// --- WORKERS ---

// 1. Discovery Worker: Ouve pings UDP do app e responde com a oferta (portas)
func discoveryWorker(assigner *SlotAssigner, slots []*SlotState) {
	addr, err := net.ResolveUDPAddr("udp", fmt.Sprintf(":%d", DiscPort))
	if err != nil {
		log.Fatalf("Erro ao resolver porta Discovery: %v", err)
	}
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		log.Fatalf("Erro ao ouvir Discovery (7071): %v", err)
	}
	defer conn.Close()

	log.Printf("📡 Discovery a ouvir em UDP %d", DiscPort)
	buffer := make([]byte, 1024)
	hostname, _ := os.Hostname()

	for {
		n, clientAddr, err := conn.ReadFromUDP(buffer)
		if err != nil {
			continue
		}

		msg := string(buffer[:n])
		if msg == ProbeBytes {
			clientIP := clientAddr.IP.String()
			slotIdx := assigner.Get(clientIP)
			slot := slots[slotIdx]

			slot.mu.Lock()
			if slot.IP != clientIP {
				slot.IP = clientIP
				slot.TeleTS = time.Time{} // Reset telemetry
			}
			slot.mu.Unlock()

			// Cria o JSON de Oferta
			offer := map[string]interface{}{
				"service":    "project-o-stream",
				"host":       GetLocalIP(), // Função auxiliar para pegar IP local
				"hostname":   hostname,
				"srtPort":    slot.SRTPort,
				"obsUdpPort": slot.OBSPort,
				"transport":  "lan",
				"slotIndex":  slotIdx,
				"totalSlots": NumCameras,
			}

			offerJSON, _ := json.Marshal(offer)
			conn.WriteToUDP(offerJSON, clientAddr)
			log.Printf("✅ Offer enviado para %s (Slot %d - SRT: %d)", clientIP, slotIdx+1, slot.SRTPort)
		}
	}
}

// 2. Telemetry Worker: Recebe métricas do telemóvel e atualiza o estado
func telemetryWorker(assigner *SlotAssigner, slots []*SlotState) {
	addr, _ := net.ResolveUDPAddr("udp", fmt.Sprintf(":%d", TelePort))
	conn, _ := net.ListenUDP("udp", addr)
	defer conn.Close()

	log.Printf("📊 Telemetria a ouvir em UDP %d", TelePort)
	buffer := make([]byte, 2048)

	for {
		n, clientAddr, err := conn.ReadFromUDP(buffer)
		if err != nil {
			continue
		}

		var payload map[string]interface{}
		if err := json.Unmarshal(buffer[:n], &payload); err != nil {
			continue
		}

		if payload["service"] != "project-o-stream-telemetry" {
			continue
		}

		clientIP := clientAddr.IP.String()
		slotIdx := assigner.Get(clientIP)
		slot := slots[slotIdx]

		// Atualiza o estado da câmara com Mutex para thread-safety
		slot.mu.Lock()
		slot.IP = clientIP
		if v, ok := payload["battery"].(float64); ok {
			slot.Battery = v
		}
		if v, ok := payload["thermalState"].(string); ok {
			slot.Thermal = v
		}
		if v, ok := payload["live"].(bool); ok {
			slot.Live = v
		}
		if v, ok := payload["rttMs"].(float64); ok {
			slot.RTTMs = v
		}
		slot.TeleTS = time.Now()
		slot.mu.Unlock()
	}
}

// 3. Relay Worker: Gere o processo FFmpeg para um slot específico
func relayWorker(slot *SlotState) {
	for {
		// Verifica se a câmara está conectada antes de iniciar o FFmpeg
		if !slot.IsConnected() {
			time.Sleep(1 * time.Second)
			continue
		}

		slot.mu.Lock()
		slot.FFmpegStatus = "listening"
		srtPort := slot.SRTPort
		obsPort := slot.OBSPort
		slot.mu.Unlock()

		log.Printf("🎥 Iniciando FFmpeg para Cam %d (SRT: %d -> OBS: %d)", slot.Index+1, srtPort, obsPort)

		srtInput := fmt.Sprintf("srt://0.0.0.0:%d?mode=listener&transtype=live&latency=80000&rcvlatency=80000&peerlatency=80000&tlpktdrop=1&pkt_size=1316", srtPort)
		obsTarget := fmt.Sprintf("udp://127.0.0.1:%d?pkt_size=1316", obsPort)

		cmd := exec.Command("ffmpeg",
			"-hide_banner", "-loglevel", "error",
			"-fflags", "nobuffer", "-flags", "low_delay",
			"-probesize", "32k", "-analyzeduration", "0",
			"-i", srtInput,
			"-map", "0", "-c", "copy", "-f", "mpegts", obsTarget,
		)

		err := cmd.Run() // Bloqueia até o processo do ffmpeg morrer

		slot.mu.Lock()
		slot.FFmpegStatus = "idle"
		slot.mu.Unlock()

		if err != nil {
			log.Printf("⚠️ FFmpeg Cam %d caiu: %v. A reiniciar em 3s...", slot.Index+1, err)
			time.Sleep(3 * time.Second)
		} else {
			log.Printf("⏹️ FFmpeg Cam %d finalizado (Telemóvel desconectou).", slot.Index+1)
			time.Sleep(1 * time.Second)
		}
	}
}

// 4. OBS State Worker: Fornece API HTTP para automações do OBS
func obsStateWorker(slots []*SlotState) {
	http.HandleFunc("/state", func(w http.ResponseWriter, r *http.Request) {
		responseSlots := []map[string]interface{}{}

		for _, slot := range slots {
			slot.mu.RLock()
			responseSlots = append(responseSlots, map[string]interface{}{
				"index":            slot.Index,
				"sourceName":       fmt.Sprintf("Project-O Cam %d", slot.Index+1),
				"assigned":         slot.IP != "",
				"connected":        slot.IsConnected(),
				"live":             slot.Live,
				"obsInput":         fmt.Sprintf("udp://127.0.0.1:%d", slot.OBSPort),
				"srtPort":          slot.SRTPort,
				"obsUdpPort":       slot.OBSPort,
				"ip":               slot.IP,
				"battery":          slot.Battery,
				"thermal":          slot.Thermal,
				"ffmpegStatus":     slot.FFmpegStatus,
			})
			slot.mu.RUnlock()
		}

		response := map[string]interface{}{
			"service": "project-o-stream-receiver",
			"slots":   responseSlots,
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(response)
	})

	log.Printf("🌐 OBS State API a ouvir em http://127.0.0.1:%d/state", ObsStatePort)
	log.Fatal(http.ListenAndServe(fmt.Sprintf("127.0.0.1:%d", ObsStatePort), nil))
}

// Auxiliar: Encontra o IP da máquina na rede local
func GetLocalIP() string {
	conn, err := net.Dial("udp", "8.8.8.8:80")
	if err != nil {
		return "127.0.0.1"
	}
	defer conn.Close()
	localAddr := conn.LocalAddr().(*net.UDPAddr)
	return localAddr.IP.String()
}

// --- PONTO DE ENTRADA ---
func main() {
	log.Println("🚀 Iniciando Project-O Stream Server (Golang Edition)...")

	// Inicializar Slots
	slots := make([]*SlotState, NumCameras)
	for i := 0; i < NumCameras; i++ {
		slots[i] = &SlotState{
			Index:   i,
			SRTPort: BaseSRTPort + (i * 3),
			OBSPort: BaseOBSPort + (i * 3),
		}
	}

	assigner := NewSlotAssigner(slots)

	// Iniciar Goroutines (equivalente às threads do Python)
	go discoveryWorker(assigner, slots)
	go telemetryWorker(assigner, slots)
	go obsStateWorker(slots)

	for _, slot := range slots {
		go relayWorker(slot)
	}

	// Mantém o programa a correr indefinidamente
	select {}
}