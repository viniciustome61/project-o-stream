package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

// Constantes do Protocolo (Baseadas no PROTOCOL.md e receiver.py)
const (
	DiscPort     = 7071
	DiscPushPort = 7072
	TelePort     = 7075
	ControlPort  = 7076
	ObsStatePort = 7077
	SlotTTL      = 120 * time.Second
	TeleFresh    = 20 * time.Second
	ProbeBytes   = "PROJECTO_STREAM_DISCOVER"
	LanProbe     = "PROJECTO_STREAM_LAN_PROBE"
	LanAck       = "PROJECTO_STREAM_LAN_ACK"
	NumCameras   = 4
	BaseSRTPort  = 7070
	BaseOBSPort  = 15000
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
	Proc           *exec.Cmd
	RelayMode      string // "obs" = relay FFmpeg→UDP | "srt" = OBS liga-se diretamente à porta SRT
}

// clearPhone limpa os dados do telemóvel quando este desconecta (paridade
// com o receiver.py, que não espera o TTL expirar)
func (s *SlotState) clearPhone() {
	s.mu.Lock()
	s.IP = ""
	s.Hostname = ""
	s.Transport = ""
	s.TeleTS = time.Time{}
	s.Live = false
	s.Battery = 0
	s.Thermal = ""
	s.RTTMs = 0
	s.mu.Unlock()
}

// srtListenerURL devolve o URL SRT em modo listener usado tanto pelo FFmpeg
// como pelo OBS em modo direto
func (s *SlotState) srtListenerURL(latencyMs int) string {
	latUs := latencyMs * 1000
	return fmt.Sprintf(
		"srt://0.0.0.0:%d?mode=listener&transtype=live&latency=%d&rcvlatency=%d&peerlatency=%d&tlpktdrop=1&pkt_size=1316",
		s.SRTPort, latUs, latUs, latUs)
}

// IsConnected verifica se a telemetria é recente e há um IP
func (s *SlotState) IsConnected() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.IP != "" && time.Since(s.TeleTS) < TeleFresh
}

//=========================
//	SlotAssigner
//=========================

// SlotAssigner mapeia IPs para os Slots disponíveis
type SlotAssigner struct {
	mu    sync.RWMutex // Alterado para RWMutex para suportar RLock()
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

// Lookup: Função responsável por consultar o IP
func (a *SlotAssigner) Lookup(ip string) (int, bool) {
	a.mu.RLock()
	defer a.mu.RUnlock() // Correção: era Unlock, mudei para RUnlock

	idx, exists := a.table[ip]
	if !exists {
		return 0, false
	}

	// Verifica se o slot expirou olhando diretamente para o SlotState
	slot := a.slots[idx]
	slot.mu.RLock()
	expired := time.Since(slot.TeleTS) > SlotTTL
	slot.mu.RUnlock()

	if expired {
		return 0, false
	}

	return idx, true
}

// Bind: Função responsável por criar um novo bind
func (a *SlotAssigner) Bind(ip string, slot int) {
	a.mu.Lock()
	defer a.mu.Unlock()

	// Correção: Adicionado as chaves {} no if
	if slot < 0 || slot >= len(a.slots) {
		return
	}

	a.table[ip] = slot
}

// Remap: Função responsável por reconfigurar o slot
func (a *SlotAssigner) Remap(ip string, newSlot int) {
	a.mu.Lock()
	defer a.mu.Unlock()

	if _, exists := a.table[ip]; exists {
		if newSlot >= 0 && newSlot < len(a.slots) {
			a.table[ip] = newSlot
		}
	}
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
	tsIP := TailscaleIP()

	for {
		n, clientAddr, err := conn.ReadFromUDP(buffer)
		if err != nil {
			continue
		}

		msg := string(buffer[:n])

		// O app mede a latência de cada endpoint com LAN_PROBE e espera LAN_ACK
		if msg == LanProbe {
			conn.WriteToUDP([]byte(LanAck), clientAddr)
			continue
		}

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

			// Cria o JSON de Oferta. lanIps e tailscaleIp são candidatos
			// extra de endpoint que o app testa por latência
			lanIP := GetLocalIP()
			lanIPs := []string{}
			for _, t := range broadcastTargets() {
				lanIPs = append(lanIPs, t.lanIP)
			}
			offer := map[string]interface{}{
				"service":     "project-o-stream",
				"host":        lanIP,
				"lanIp":       lanIP,
				"lanIps":      lanIPs,
				"tailscaleIp": tsIP,
				"hostname":    hostname,
				"srtPort":     slot.SRTPort,
				"obsUdpPort":  slot.OBSPort,
				"transport":   "lan",
				"slotIndex":   slotIdx,
				"totalSlots":  len(slots),
			}

			offerJSON, _ := json.Marshal(offer)
			conn.WriteToUDP(offerJSON, clientAddr)
			// Backup: o app também ouve ofertas na porta fixa 7072 — a resposta
			// unicast para a porta efémera do probe nem sempre chega (hotspot/iOS)
			conn.WriteToUDP(offerJSON, &net.UDPAddr{IP: clientAddr.IP, Port: DiscPushPort})
			log.Printf("✅ Offer enviado para %s (Slot %d - SRT: %d)", clientIP, slotIdx+1, slot.SRTPort)
		}
	}
}

// 1b. LAN Offer Worker: envia ofertas por broadcast para a porta 7072 a cada
// segundo — é o caminho de descoberta de reserva que o app usa quando a
// resposta unicast ao probe não chega (equivalente ao _lan_offer_worker do
// receiver.py).
func lanOfferWorker(slots []*SlotState) {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{Port: 0})
	if err != nil {
		log.Printf("⚠️ LAN offer worker indisponível: %v", err)
		return
	}
	defer conn.Close()

	hostname, _ := os.Hostname()
	slot := slots[0]

	for {
		for _, target := range broadcastTargets() {
			slot.mu.RLock()
			offer := map[string]interface{}{
				"service":    "project-o-stream",
				"host":       target.lanIP,
				"lanIp":      target.lanIP,
				"hostname":   hostname,
				"srtPort":    slot.SRTPort,
				"obsUdpPort": slot.OBSPort,
				"transport":  "lan",
				"slotIndex":  0,
				"totalSlots": len(slots),
			}
			slot.mu.RUnlock()

			offerJSON, _ := json.Marshal(offer)
			conn.WriteToUDP(offerJSON, &net.UDPAddr{IP: target.broadcast, Port: DiscPushPort})
		}
		time.Sleep(1 * time.Second)
	}
}

type offerTarget struct {
	lanIP     string
	broadcast net.IP
}

// broadcastTargets devolve o broadcast dirigido de cada interface IPv4 privada
func broadcastTargets() []offerTarget {
	targets := []offerTarget{}
	ifaces, err := net.Interfaces()
	if err != nil {
		return targets
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipNet, ok := addr.(*net.IPNet)
			if !ok {
				continue
			}
			ip4 := ipNet.IP.To4()
			if ip4 == nil || !ip4.IsPrivate() {
				continue
			}
			mask := ipNet.Mask
			bcast := make(net.IP, 4)
			for i := 0; i < 4; i++ {
				bcast[i] = ip4[i] | ^mask[i]
			}
			targets = append(targets, offerTarget{lanIP: ip4.String(), broadcast: bcast})
		}
	}
	return targets
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
		if v, ok := payload["hostname"].(string); ok {
			slot.Hostname = v
		}
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
func relayWorker(slot *SlotState, args *Args) {
	// O listener SRT tem de estar sempre ativo — o telemóvel liga-se como
	// caller logo após o discovery, antes de qualquer telemetria chegar.
	log.Printf("🎧 Cam %d: à espera de SRT na porta %d", slot.Index+1, slot.SRTPort)
	for {
		slot.mu.RLock()
		mode := slot.RelayMode
		srtPort := slot.SRTPort
		obsPort := slot.OBSPort
		slot.mu.RUnlock()

		// Modo SRT direto: o OBS liga-se à porta SRT, sem relay FFmpeg
		if args.DirectToObs || mode == "srt" {
			slot.mu.Lock()
			slot.FFmpegStatus = "srt-direct"
			slot.mu.Unlock()
			time.Sleep(200 * time.Millisecond)
			continue
		}

		slot.mu.Lock()
		slot.FFmpegStatus = "listening"
		slot.mu.Unlock()

		srtInput := slot.srtListenerURL(args.Latency)
		obsTarget := fmt.Sprintf("udp://127.0.0.1:%d?pkt_size=1316", obsPort)

		cmd := exec.Command(args.FFmpeg,
			"-hide_banner", "-loglevel", "error",
			"-fflags", "nobuffer", "-flags", "low_delay",
			"-probesize", "32k", "-analyzeduration", "0",
			"-i", srtInput,
			"-map", "0", "-c", "copy", "-f", "mpegts", obsTarget,
		)

		if err := cmd.Start(); err != nil {
			slot.mu.Lock()
			slot.FFmpegStatus = "err ffmpeg not found"
			slot.mu.Unlock()
			log.Printf("⚠️ FFmpeg Cam %d não iniciou: %v. A tentar em 3s...", slot.Index+1, err)
			time.Sleep(3 * time.Second)
			continue
		}

		slot.mu.Lock()
		slot.Proc = cmd // guarda o handle para o hotkey 'k' (kill slot)
		slot.mu.Unlock()

		t0 := time.Now()
		err := cmd.Wait() // Bloqueia até o processo do ffmpeg morrer
		elapsed := time.Since(t0)

		slot.mu.Lock()
		slot.Proc = nil
		slot.FFmpegStatus = "idle"
		modeNow := slot.RelayMode
		slot.mu.Unlock()

		// O modo mudou para SRT enquanto o FFmpeg corria (hotkey 'm' mata o
		// processo para libertar a porta) — não é um erro
		if args.DirectToObs || modeNow == "srt" {
			continue
		}

		switch {
		case err == nil && elapsed > 2*time.Second:
			// Saída limpa depois de streaming: o telemóvel desconectou
			log.Printf("⏹️ Cam %d: telemóvel desconectou.", slot.Index+1)
			slot.clearPhone()
			time.Sleep(1 * time.Second)
		case err != nil && elapsed > 2*time.Second:
			log.Printf("⚠️ FFmpeg Cam %d caiu: %v. A reiniciar em 3s...", slot.Index+1, err)
			slot.mu.Lock()
			slot.FFmpegStatus = "restarting"
			slot.mu.Unlock()
			time.Sleep(3 * time.Second)
		default:
			// Morreu logo ao arrancar (porta ocupada, ffmpeg sem SRT, etc.)
			log.Printf("⚠️ FFmpeg Cam %d (SRT %d) saiu em %.1fs: %v. Retry em 3s...", slot.Index+1, srtPort, elapsed.Seconds(), err)
			slot.mu.Lock()
			slot.FFmpegStatus = "err - retry 3s"
			slot.mu.Unlock()
			time.Sleep(3 * time.Second)
		}
	}
}

// 4. OBS State Worker: Fornece API HTTP para automações do OBS
func obsStateWorker(slots []*SlotState, args *Args) {
	http.HandleFunc("/state", func(w http.ResponseWriter, r *http.Request) {
		responseSlots := []map[string]interface{}{}

		for _, slot := range slots {
			slot.mu.RLock()
			mode := "udp"
			obsInput := fmt.Sprintf("udp://127.0.0.1:%d?pkt_size=1316", slot.OBSPort)
			if args.DirectToObs || slot.RelayMode == "srt" {
				mode = "srt"
				obsInput = slot.srtListenerURL(args.Latency)
			}
			// O script obs_auto_sources.py só cria a source quando
			// obsSourcePresent é true: slot atribuído e telemetria fresca
			// (ou ainda nenhuma telemetria recebida)
			sourcePresent := slot.IP != "" &&
				(slot.TeleTS.IsZero() || time.Since(slot.TeleTS) < TeleFresh)
			connected := slot.IP != "" && time.Since(slot.TeleTS) < TeleFresh
			responseSlots = append(responseSlots, map[string]interface{}{
				"index":            slot.Index,
				"sourceName":       fmt.Sprintf("Project-O Cam %d", slot.Index+1),
				"assigned":         slot.IP != "",
				"connected":        connected,
				"live":             slot.Live,
				"obsSourcePresent": sourcePresent,
				"obsInput":         obsInput,
				"obsInputUrl":      obsInput,
				"mode":             mode,
				"relayMode":        slot.RelayMode,
				"srtPort":          slot.SRTPort,
				"obsUdpPort":       slot.OBSPort,
				"ip":               slot.IP,
				"hostname":         slot.Hostname,
				"transport":        slot.Transport,
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

// TailscaleIP devolve o IPv4 desta máquina na tailnet (100.64.0.0/10), ou ""
func TailscaleIP() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipNet, ok := addr.(*net.IPNet)
			if !ok {
				continue
			}
			ip4 := ipNet.IP.To4()
			if ip4 != nil && ip4[0] == 100 && ip4[1] >= 64 && ip4[1] <= 127 {
				return ip4.String()
			}
		}
	}
	return ""
}

// tailscalePeerIPs consulta o CLI do Tailscale pelos IPv4 dos peers da tailnet
func tailscalePeerIPs() []string {
	out, err := exec.Command("tailscale", "status", "--json").Output()
	if err != nil {
		return nil
	}
	var status struct {
		Peer map[string]struct {
			TailscaleIPs []string `json:"TailscaleIPs"`
			Online       bool     `json:"Online"`
		} `json:"Peer"`
	}
	if err := json.Unmarshal(out, &status); err != nil {
		return nil
	}
	peers := []string{}
	for _, peer := range status.Peer {
		if !peer.Online {
			continue
		}
		for _, ip := range peer.TailscaleIPs {
			parsed := net.ParseIP(ip)
			if parsed != nil && parsed.To4() != nil {
				peers = append(peers, ip)
			}
		}
	}
	return peers
}

// 1c. Tailnet Offer Worker: envia ofertas unicast na porta 7072 a cada peer
// online da tailnet — permite descoberta sem broadcast quando o telemóvel
// está fora da LAN (equivalente ao _tailnet_offer_worker do receiver.py)
func tailnetOfferWorker(slots []*SlotState, tsIP string) {
	if tsIP == "" {
		return
	}
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{Port: 0})
	if err != nil {
		return
	}
	defer conn.Close()

	hostname, _ := os.Hostname()
	slot := slots[0]
	log.Printf("🔗 Ofertas Tailscale na porta UDP %d (self %s)", DiscPushPort, tsIP)

	peers := tailscalePeerIPs()
	lastRefresh := time.Now()

	for {
		if time.Since(lastRefresh) > 30*time.Second {
			peers = tailscalePeerIPs()
			lastRefresh = time.Now()
		}
		for _, peer := range peers {
			slot.mu.RLock()
			offer := map[string]interface{}{
				"service":     "project-o-stream",
				"host":        tsIP,
				"tailscaleIp": tsIP,
				"hostname":    hostname,
				"srtPort":     slot.SRTPort,
				"obsUdpPort":  slot.OBSPort,
				"transport":   "tailscale",
				"slotIndex":   0,
				"totalSlots":  len(slots),
			}
			slot.mu.RUnlock()
			offerJSON, _ := json.Marshal(offer)
			conn.WriteToUDP(offerJSON, &net.UDPAddr{IP: net.ParseIP(peer), Port: DiscPushPort})
		}
		time.Sleep(1 * time.Second)
	}
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

// ensureFirewall garante uma regra inbound do Windows Firewall para este
// executável (o firewall dropa UDP inbound silenciosamente sem ela). Precisa
// de admin para criar — se falhar, apenas avisa.
func ensureFirewall() {
	exePath, err := os.Executable()
	if err != nil {
		return
	}
	const ruleName = "Project O Stream Go Receiver"
	check := exec.Command("netsh", "advfirewall", "firewall", "show", "rule", "name="+ruleName)
	if check.Run() == nil {
		return // regra já existe
	}
	add := exec.Command("netsh", "advfirewall", "firewall", "add", "rule",
		"name="+ruleName, "dir=in", "action=allow", "program="+exePath, "enable=yes")
	if add.Run() == nil {
		log.Printf("🧱 Regra de firewall criada para %s", exePath)
	} else {
		log.Printf("⚠️ Sem regra de firewall (corre uma vez como admin se o telemóvel não descobrir o PC)")
	}
}

// healthCheck valida as dependências externas ao arranque
func healthCheck(args *Args) {
	if path, err := exec.LookPath(args.FFmpeg); err != nil {
		log.Printf("❌ FFmpeg não encontrado ('%s') — o relay para o OBS não vai funcionar", args.FFmpeg)
	} else {
		log.Printf("✅ FFmpeg: %s", path)
	}
	if _, err := exec.LookPath("tailscale"); err != nil {
		log.Printf("ℹ️ Tailscale CLI não encontrado — descoberta remota limitada à LAN")
	}
}

// --- PONTO DE ENTRADA ---
func main() {
	args := parseArgs()

	//Inicializa o Receiver usado pela TUI
	receiver := &Receiver{
		Args:        args,
		StartTS:     time.Now(),
		LanIP:       GetLocalIP(),
		TailscaleIP: TailscaleIP(),
	}
	for _, t := range broadcastTargets() {
		receiver.LanIPs = append(receiver.LanIPs, t.lanIP)
	}
	log.SetFlags(0)                                    // Remove a data/hora duplicada do pacote log nativo
	log.SetOutput(&logInterceptor{receiver: receiver}) // Sequestra os logs

	// Prepara os Slots de câmeras
	relayMode := "obs"
	if args.DirectToObs {
		relayMode = "srt"
	}
	receiver.Slots = make([]*SlotState, args.Cameras)
	for i := 0; i < args.Cameras; i++ {
		receiver.Slots[i] = &SlotState{
			Index:     i,
			SRTPort:   args.Port + (i * 3),
			OBSPort:   args.ObsPort + (i * 3),
			RelayMode: relayMode,
		}
	}

	// Pre-flight: firewall + dependências
	ensureFirewall()
	healthCheck(args)

	// Cria o Assigner
	assigner := NewSlotAssigner(receiver.Slots)

	// Inicia as goroutines
	go discoveryWorker(assigner, receiver.Slots)
	go lanOfferWorker(receiver.Slots)
	go tailnetOfferWorker(receiver.Slots, receiver.TailscaleIP)
	go telemetryWorker(assigner, receiver.Slots)
	if !args.NoObsStateApi {
		go obsStateWorker(receiver.Slots, args)
	}
	for _, slot := range receiver.Slots {
		go relayWorker(slot, args)
	}

	// Inicia a Interface Gráfica TUI
	app := NewReceiverApp(receiver)

	// Ctrl+C para fechar de forma limpa
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigChan
		receiver.Stopping = true
		app.App.Stop()
	}()

	// Executa a TUI
	if err := app.App.Run(); err != nil {
		panic(err)
	}
}
