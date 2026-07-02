package main

import (
	"encoding/json"
	"sync"
	"time"
)

// StreamProfile representa as configurações de qualidade de mídia
type StreamProfile struct {
	Resolution string `json:"resolution"` // Ex: "1080p", "4K"
	FPS        int    `json:"fps"`        // Ex: 30, 60
	BitrateKbps int   `json:"bitrate_kbps"` // Ex: 12000, 50000
}

// SlotState orquestra o ciclo de vida e a saúde de um slot de transmissão
type SlotState struct {
	mu sync.RWMutex // Mutex para proteger o acesso concorrente ao slot

	// Identificação e Rede
	ID             int    `json:"id"`
	IP             string `json:"ip"`
	Hostname       string `json:"hostname"`
	PhoneSlotIndex int    `json:"phone_slot_index"` // Índice físico (ex: Telefone 1, 2, 3)
	Live           bool   `json:"live"`

	// Parâmetros de Mídia e Rede
	SRTPort       int           `json:"srt_port"`       // Porta SRT (ex: 7070)
	OBSPort       int           `json:"obs_port"`       // Porta UDP Localhost (ex: 15000)
	LatencyMs     int           `json:"latency_ms"`     // Latência SRT configurada (ex: 80)
	Profile       StreamProfile `json:"profile"`
	HEVCEnabled   bool          `json:"hevc_enabled"`   // Toggle para H.265 vs H.264

	// Telemetria e Monitoramento de Hardware
	Battery       float64   `json:"battery"`        // Nível da bateria em %
	Thermal       string    `json:"thermal"`        // Estado térmico (ex: "NORMAL", "THROTTLED")
	RTTMs         float64   `json:"rtt_ms"`         // Round Trip Time da rede em ms
	TeleTS        time.Time `json:"telemetry_ts"`   // Timestamp do último sinal de vida
	FFmpegStatus  string    `json:"ffmpeg_status"`  // WAITING_CONNECTION, RUNNING, DISCONNECTED
}

// UpdateFromDiscovery atualiza de forma segura os dados do slot 
// quando o Leandro (Funções Auxiliares) ou o Carlos (SlotAssigner) validarem um sinal UDP
func (s *SlotState) UpdateFromDiscovery(ip string, hostname string, phoneIndex int) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.IP = ip
	s.Hostname = hostname
	s.PhoneSlotIndex = phoneIndex
	s.Live = true
	s.TeleTS = time.Now() // Reseta o timestamp para evitar timeout imediato

	if s.FFmpegStatus == "" || s.FFmpegStatus == "DISCONNECTED" {
		s.FFmpegStatus = "WAITING_CONNECTION"
	}
}

// UpdateTelemetry injeta os dados de saúde do telemóvel recebidos na rota de telemetria
func (s *SlotState) UpdateTelemetry(battery float64, thermal string, rtt float64) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.Battery = battery
	s.Thermal = thermal
	s.RTTMs = rtt
	s.TeleTS = time.Now()
}

// CheckConflict resolve o requisito de segurança do README.
// Verifica se há outra máquina na rede Tailscale a tentar roubar um slot ativo.
func (s *SlotState) CheckConflict(incomingIP string, incomingHostname string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()

	// Se o slot já está ativo com um telemóvel, mas chega um sinal com IP ou Hostname diferente, há conflito!
	if s.Live && s.IP != "" && (s.IP != incomingIP || s.Hostname != incomingHostname) {
		return true
	}
	return false
}

// SetFFmpegStatus altera o estado do processo (usado pelo Vinicius no supervisor do FFmpeg)
func (s *SlotState) SetFFmpegStatus(status string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.FFmpegStatus = status
}

// CheckAndHandleTimeout limpa o slot caso o telemóvel fique offline (estoure o TTL)
func (s *SlotState) CheckAndHandleTimeout(ttl time.Duration) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.IP == "" {
		return false
	}

	if time.Since(s.TeleTS) > ttl {
		s.IP = ""
		s.Hostname = ""
		s.Live = false
		s.FFmpegStatus = "DISCONNECTED"
		return true
	}
	return false
}

// ToJSON converte o estado do slot para JSON (útil para a API do Pedro/ReceiverApp)
func (s *SlotState) ToJSON() ([]byte, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return json.Marshal(s)
}