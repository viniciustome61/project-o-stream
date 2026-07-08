package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/atotto/clipboard"
	"github.com/gdamore/tcell/v2"
	"github.com/rivo/tview"
)

//Argumentos

type Args struct {
	Cameras       int
	Port          int
	ObsPort       int
	Latency       int
	FFmpeg        string
	DirectToObs   bool
	RelayToObs    bool
	ObsStatePort  int
	NoObsStateApi bool
}

func parseArgs() *Args {
	args := &Args{}
	flag.IntVar(&args.Cameras, "cameras", 1, "Number of camera slots to pre-create")
	flag.IntVar(&args.Port, "port", 7070, "Base SRT ingest port")
	flag.IntVar(&args.ObsPort, "obs-port", 15000, "Base OBS UDP output port")
	flag.IntVar(&args.Latency, "latency", 80, "SRT receive latency in milliseconds")
	flag.StringVar(&args.FFmpeg, "ffmpeg", "", "Path to ffmpeg executable")
	flag.BoolVar(&args.DirectToObs, "direct-to-obs", false, "Skip relay — give OBS the raw SRT URL")
	flag.BoolVar(&args.RelayToObs, "relay-to-obs", false, "Force relay mode even if --direct-to-obs was previously set")
	flag.IntVar(&args.ObsStatePort, "obs-state-port", ObsStatePort, "Local HTTP port for the OBS auto-source script")
	flag.BoolVar(&args.NoObsStateApi, "no-obs-state-api", false, "Disable the local OBS auto-source state endpoint")

	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Project-O Stream Receiver — Terminal UI (Go Edition)\n\n")
		fmt.Fprintf(os.Stderr, "TUI keys: c=copy OBS URL  s=copy log  l=cycle lens  t=torch\n")
		fmt.Fprintf(os.Stderr, "          z=zoom in  x=zoom out  k=kill slot  q=quit\n\n")
		flag.PrintDefaults()
	}

	flag.Parse()

	if args.RelayToObs {
		args.DirectToObs = false
	}
	if args.FFmpeg == "" {
		args.FFmpeg = "ffmpeg"
	}
	return args
}

// Mocks

type Receiver struct {
	Args        *Args
	Slots       []*SlotState
	StartTS     time.Time
	LanIP       string
	LanIPs      []string
	TailscaleIP string
	Stopping    bool

	logLock sync.Mutex
	log     []string
}

func (r *Receiver) LogMsg(msg string) {
	r.logLock.Lock()
	defer r.logLock.Unlock()
	ts := time.Now().Format("15:04:05")
	r.log = append(r.log, fmt.Sprintf("%s %s", ts, msg))
	// Limita o buffer de log a 200 linhas
	if len(r.log) > 200 {
		r.log = r.log[1:]
	}
}

func (r *Receiver) SendControl(slot *SlotState, cmd string, params ...map[string]interface{}) {
	slot.mu.RLock()
	ip := slot.IP
	phoneSlot := slot.PhoneSlotIndex
	slot.mu.RUnlock()

	if ip == "" {
		r.LogMsg(fmt.Sprintf("Cam %d: sem endereço do telemóvel para controlo remoto", slot.Index+1))
		return
	}

	payload := map[string]interface{}{
		"service":   "project-o-stream-control",
		"action":    cmd,
		"slotIndex": phoneSlot,
		"sentAt":    float64(time.Now().UnixMilli()) / 1000.0,
	}
	for _, p := range params {
		for k, v := range p {
			payload[k] = v
		}
	}

	data, err := json.Marshal(payload)
	if err != nil {
		return
	}

	conn, err := net.Dial("udp", net.JoinHostPort(ip, fmt.Sprintf("%d", ControlPort)))
	if err != nil {
		r.LogMsg(fmt.Sprintf("Cam %d: controlo remoto '%s' falhou: %v", slot.Index+1, cmd, err))
		return
	}
	defer conn.Close()

	// UDP é não-fiável — envia 3x como o receiver.py
	for i := 0; i < 3; i++ {
		conn.Write(data)
		time.Sleep(40 * time.Millisecond)
	}
	r.LogMsg(fmt.Sprintf("Cam %d: comando '%s' enviado para %s:%d", slot.Index+1, cmd, ip, ControlPort))
}

func (r *Receiver) CopyObsInput(slot *SlotState) {
	url := fmt.Sprintf("udp://127.0.0.1:%d", slot.OBSPort)
	if err := clipboard.WriteAll(url); err == nil {
		r.LogMsg(fmt.Sprintf("URL copiada: %s", url))
	} else {
		r.LogMsg(fmt.Sprintf("Erro ao copiar URL: %v", err))
	}
}

func (r *Receiver) KillSlotProcess(slot *SlotState) {
	slot.mu.Lock()
	proc := slot.Proc
	slot.mu.Unlock()

	if proc == nil || proc.Process == nil {
		r.LogMsg(fmt.Sprintf("Cam %d: nenhum processo FFmpeg ativo", slot.Index+1))
		return
	}
	if err := proc.Process.Kill(); err != nil {
		r.LogMsg(fmt.Sprintf("Cam %d: falha ao matar FFmpeg: %v", slot.Index+1, err))
		return
	}
	r.LogMsg(fmt.Sprintf("Cam %d: FFmpeg finalizado pelo utilizador (reinicia em 3s)", slot.Index+1))
}

// TUI

// SlotMetadata guarda os estados que não existem no SlotState
type SlotMetadata struct {
	TorchOn   bool
	ZoomLevel float64
}

type ReceiverApp struct {
	Receiver *Receiver
	App      *tview.Application
	Header   *tview.TextView
	Table    *tview.Table
	LogView  *tview.TextView
	Footer   *tview.TextView

	metaMap    map[int]*SlotMetadata
	metaLock   sync.RWMutex
	lastAction map[rune]time.Time
}

func NewReceiverApp(r *Receiver) *ReceiverApp {
	app := &ReceiverApp{
		Receiver:   r,
		App:        tview.NewApplication(),
		Header:     tview.NewTextView().SetDynamicColors(true).SetTextAlign(tview.AlignCenter),
		Table:      tview.NewTable().SetBorders(false).SetSelectable(true, false).SetFixed(1, 0),
		LogView:    tview.NewTextView().SetDynamicColors(true).SetScrollable(true).SetMaxLines(200),
		Footer:     tview.NewTextView().SetDynamicColors(true).SetTextAlign(tview.AlignLeft),
		metaMap:    make(map[int]*SlotMetadata),
		lastAction: make(map[rune]time.Time),
	}

	// Inicia o layout
	app.setupUI()
	return app
}

func (a *ReceiverApp) getMeta(index int) *SlotMetadata {
	a.metaLock.Lock()
	defer a.metaLock.Unlock()
	if meta, exists := a.metaMap[index]; exists {
		return meta
	}
	newMeta := &SlotMetadata{ZoomLevel: 1.0}
	a.metaMap[index] = newMeta
	return newMeta
}

func (a *ReceiverApp) setupUI() {
	// Cores da Tabela
	cols := []string{"●", "CAM", "DEVICE", "NETWORK", "RTT", "BATTERY", "THERMAL", "OBS INPUT", "STATUS"}
	for i, col := range cols {
		a.Table.SetCell(0, i, tview.NewTableCell(col).SetTextColor(tcell.ColorYellow).SetSelectable(false))
	}

	a.Footer.SetText(" [yellow]c[-] Copy OBS  [yellow]s[-] Copy log  [yellow]m[-] Mode  [yellow]l[-] Lens  [yellow]t[-] Torch  [yellow]z[-] Zoom+  [yellow]x[-] Zoom-  [yellow]k[-] Kill slot  [yellow]q[-] Quit")

	// Atalhos
	a.App.SetInputCapture(func(event *tcell.EventKey) *tcell.EventKey {
		if event.Key() == tcell.KeyCtrlC {
			a.actionQuit()
			return nil
		}

		switch event.Rune() {
		case 'c': // Copia o URL da câmera selecionada
			a.actionCopyOBSInput()
		case 's': // Copia o log do terminal
			a.actionCopyLog()
		case 'm': // Alterna o modo de rota do video da câmera selecionada
			a.actionCycleRelayMode()
		case 'l': // Volta o zoom da câmera selecionada para 1x
			a.actionCycleLens()
		case 't': // Liga/desliga a lanterna da câmera selecionada
			a.actionToggleTorch()
		case 'z': // Aumenta o zoom da câmera selecionada (1x - 8x, aumentando em 0.5x)
			a.actionZoomIn()
		case 'x': // Reduz o zoom da câmera (diminuindo em 0.5x, até o limite de 1x)
			a.actionZoomOut()
		case 'k': // Força o encerramento da câmera selecionada (caso trave)
			a.actionKillSlot()
		case 'q': // Encerra o receiver
			a.actionQuit()
			return nil
		}
		return event
	})

	// Layout
	flex := tview.NewFlex().SetDirection(tview.FlexRow).
		AddItem(a.Header, 2, 1, false).
		AddItem(a.Table, 0, 1, true).
		AddItem(a.LogView, 0, 1, false).
		AddItem(a.Footer, 1, 1, false)

	a.App.SetRoot(flex, true).SetFocus(a.Table)

	// Goroutine (atualizando a cada 250ms)
	go func() {
		ticker := time.NewTicker(250 * time.Millisecond)
		for range ticker.C {
			a.App.QueueUpdateDraw(func() {
				a.refresh()
			})
		}
	}()
}

func (a *ReceiverApp) refresh() {
	a.updateSubtitle()
	a.updateLog()

	for _, slot := range a.Receiver.Slots {
		a.updateSlotRow(slot)
	}
}

func (a *ReceiverApp) updateSubtitle() {
	connected := 0
	for _, s := range a.Receiver.Slots {
		if s.IsConnected() {
			connected++
		}
	}

	uptime := time.Since(a.Receiver.StartTS)
	hrs := int(uptime.Hours())
	mins := int(uptime.Minutes()) % 60
	secs := int(uptime.Seconds()) % 60

	mode := "relay→OBS"
	if a.Receiver.Args.DirectToObs {
		mode = "direct-to-OBS"
	}

	lanLabel := a.Receiver.LanIP
	if len(a.Receiver.LanIPs) > 1 {
		lanLabel = fmt.Sprintf("%s (+%d)", a.Receiver.LanIP, len(a.Receiver.LanIPs)-1)
	}

	tsPart := ""
	if a.Receiver.TailscaleIP != "" {
		tsPart = fmt.Sprintf("  Tailscale %s", a.Receiver.TailscaleIP)
	}

	connIndicator := "[red]○[-]"
	if connected > 0 {
		connIndicator = "[green]●[-]"
	}

	subtitle := fmt.Sprintf("up %02d:%02d:%02d  LAN %s%s  slots %d  %s  connected %s %d",
		hrs, mins, secs, lanLabel, tsPart, len(a.Receiver.Slots), mode, connIndicator, connected)

	a.Header.SetText(fmt.Sprintf("[white::b]Project-O Stream Receiver[-:-:-]\n%s", subtitle))
}

func (a *ReceiverApp) updateLog() {
	a.Receiver.logLock.Lock()
	defer a.Receiver.logLock.Unlock()
	a.LogView.SetText(strings.Join(a.Receiver.log, "\n"))
	a.LogView.ScrollToEnd()
}

func (a *ReceiverApp) updateSlotRow(s *SlotState) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	meta := a.getMeta(s.Index)
	isConnected := s.IP != "" && time.Since(s.TeleTS) < 20*time.Second
	row := s.Index + 1

	// 1. Ponto
	dot := "[dim]○[-]"
	if isConnected {
		dot = "[green]●[-]"
	}

	// 2. CAM
	cam := fmt.Sprintf("%d", s.Index+1)

	// 3. DEVICE
	dev := "[dim::i]waiting...[-:-:-]"
	if s.Hostname != "" {
		dev = fmt.Sprintf("[white]%s[-]", s.Hostname)
	}

	// 4. NETWORK
	net := fmt.Sprintf("[dim]SRT :%d[-]", s.SRTPort)
	if s.IP != "" {
		if s.Transport != "" {
			net = fmt.Sprintf("[white]%s  %s[-]", s.Transport, s.IP)
		} else {
			net = fmt.Sprintf("[white]%s[-]", s.IP)
		}
	}

	// 5. RTT
	rtt := "[dim]—[-]"
	if isConnected && s.RTTMs > 0 {
		color := "green"
		if s.RTTMs >= 80 {
			color = "red"
		} else if s.RTTMs >= 20 {
			color = "yellow"
		}
		rtt = fmt.Sprintf("[%s]%.0fms[-]", color, s.RTTMs)
	}

	// 6. BATTERY
	batt := "[dim]—[-]"
	if isConnected && s.Battery > 0 {
		pct := s.Battery * 100
		color := "green"
		if s.Battery < 2.0 {
			color = "red"
		} else if s.Battery < 5.0 {
			color = "yellow"
		}
		batt = fmt.Sprintf("[%s]%.0f%%[-]", color, pct)
	}

	// 7. THERMAL
	thermal := "[dim]—[-]"
	if isConnected && s.Thermal != "" {
		label, color := s.Thermal[:4], "white"
		switch strings.ToLower(s.Thermal) {
		case "nominal":
			label, color = "OK", "green"
		case "fair":
			label, color = "WARM", "yellow"
		case "serious":
			label, color = "HOT", "red"
		case "critical":
			label, color = "CRIT", "red::b"
		}
		thermal = fmt.Sprintf("[%s]%s[-]", color, strings.ToUpper(label))
	}

	// 8. OBS INPUT
	srtDirect := a.Receiver.Args.DirectToObs || s.RelayMode == "srt"
	obsDisplay := fmt.Sprintf("udp://127.0.0.1:%d", s.OBSPort)
	if srtDirect {
		obsDisplay = fmt.Sprintf("srt://0.0.0.0:%d", s.SRTPort)
	}
	obsColor := "dim"
	if isConnected || srtDirect {
		obsColor = "green"
	}
	obsText := fmt.Sprintf("[%s]%s[-]", obsColor, obsDisplay)

	// 9. STATUS
	st := s.FFmpegStatus
	status := fmt.Sprintf("[dim]%s[-]", st)
	if st == "srt-direct" {
		status = "[aqua]srt-direct[-]"
	} else if st == "restarting" || st == "idle" {
		status = fmt.Sprintf("[yellow]%s[-]", st)
	} else if strings.HasPrefix(st, "err") {
		status = fmt.Sprintf("[red]%s[-]", st)
	}

	if srtDirect {
		status += "  [aqua::b][SRT][-:-:-]"
	}
	if isConnected {
		if meta.TorchOn {
			status += "  [yellow]🔦[-]"
		}
		if meta.ZoomLevel != 1.0 {
			status += fmt.Sprintf("  [aqua]%.1fx[-]", meta.ZoomLevel)
		}
	}

	// Atualizar Células
	cells := []string{dot, cam, dev, net, rtt, batt, thermal, obsText, status}
	for col, val := range cells {
		a.Table.SetCell(row, col, tview.NewTableCell(val).SetExpansion(1))
	}
}

func (a *ReceiverApp) debounce(key rune, ms int) bool {
	now := time.Now()
	if lastT, exists := a.lastAction[key]; exists {
		if now.Sub(lastT).Milliseconds() < int64(ms) {
			return false
		}
	}
	a.lastAction[key] = now
	return true
}

func (a *ReceiverApp) getSelectedSlot() *SlotState {
	row, _ := a.Table.GetSelection()
	if row > 0 && row <= len(a.Receiver.Slots) {
		return a.Receiver.Slots[row-1]
	}
	return nil
}

func (a *ReceiverApp) actionCycleRelayMode() {
	if !a.debounce('m', 500) {
		return
	}
	slot := a.getSelectedSlot()
	if slot == nil {
		return
	}

	slot.mu.Lock()
	if slot.RelayMode == "obs" {
		slot.RelayMode = "srt"
	} else {
		slot.RelayMode = "obs"
	}
	newMode := slot.RelayMode
	proc := slot.Proc
	slot.mu.Unlock()

	// Ao mudar para SRT direto, mata o FFmpeg para libertar a porta;
	// o relayWorker vê o novo modo e não reinicia
	if newMode == "srt" && proc != nil && proc.Process != nil {
		proc.Process.Kill()
	}

	// O telemóvel tem de reconectar para o OBS apanhar o novo caminho
	a.Receiver.SendControl(slot, "reconnect")
	a.Receiver.LogMsg(fmt.Sprintf("Cam %d: switched to %s", slot.Index+1, newMode))
}

func (a *ReceiverApp) actionCycleLens() {
	if !a.debounce('l', 500) {
		return
	}
	slot := a.getSelectedSlot()
	if slot == nil {
		return
	}

	meta := a.getMeta(slot.Index)
	meta.ZoomLevel = 1.0
	a.Receiver.SendControl(slot, "cycleLens")
}

func (a *ReceiverApp) actionToggleTorch() {
	if !a.debounce('t', 500) {
		return
	}
	slot := a.getSelectedSlot()
	if slot == nil {
		return
	}

	meta := a.getMeta(slot.Index)
	meta.TorchOn = !meta.TorchOn
	a.Receiver.SendControl(slot, "toggleTorch", map[string]interface{}{"torch": meta.TorchOn})
}

func (a *ReceiverApp) actionZoomIn() {
	if !a.debounce('z', 500) {
		return
	}
	slot := a.getSelectedSlot()
	if slot == nil {
		return
	}

	meta := a.getMeta(slot.Index)
	if meta.ZoomLevel < 8.0 {
		meta.ZoomLevel += 0.5
	}
	a.Receiver.SendControl(slot, "setZoom", map[string]interface{}{"zoom": meta.ZoomLevel})
}

func (a *ReceiverApp) actionZoomOut() {
	if !a.debounce('x', 500) {
		return
	}
	slot := a.getSelectedSlot()
	if slot == nil {
		return
	}

	meta := a.getMeta(slot.Index)
	if meta.ZoomLevel > 1.0 {
		meta.ZoomLevel -= 0.5
	}
	a.Receiver.SendControl(slot, "setZoom", map[string]interface{}{"zoom": meta.ZoomLevel})
}

func (a *ReceiverApp) actionCopyOBSInput() {
	slot := a.getSelectedSlot()
	if slot != nil {
		a.Receiver.CopyObsInput(slot)
	}
}

func (a *ReceiverApp) actionCopyLog() {
	a.Receiver.logLock.Lock()
	text := strings.Join(a.Receiver.log, "\n")
	a.Receiver.logLock.Unlock()

	if err := clipboard.WriteAll(text); err == nil {
		a.Receiver.LogMsg("Log copiado para a área de transferência")
	}
}

func (a *ReceiverApp) actionKillSlot() {
	slot := a.getSelectedSlot()
	if slot != nil {
		a.Receiver.KillSlotProcess(slot)
	}
}

func (a *ReceiverApp) actionQuit() {
	for _, slot := range a.Receiver.Slots {
		slot.mu.RLock()
		srtMode := slot.RelayMode == "srt"
		hasPhone := slot.IP != ""
		slot.mu.RUnlock()
		if srtMode && hasPhone {
			a.Receiver.SendControl(slot, "stopStream")
		}
	}
	a.Receiver.Stopping = true
	a.App.Stop()
}

// Ponto de Entrada

func runReceiver() {
	args := parseArgs()

	// Simula a inicialização do Receiver
	receiver := &Receiver{
		Args:    args,
		StartTS: time.Now(),
		LanIP:   "192.168.1.100",
	}

	// Cria os slots
	receiver.Slots = make([]*SlotState, args.Cameras)
	for i := 0; i < args.Cameras; i++ {
		receiver.Slots[i] = &SlotState{
			Index:   i,
			SRTPort: args.Port + (i * 3),
			OBSPort: args.ObsPort + (i * 3),
		}
	}

	app := NewReceiverApp(receiver)

	// PEga sinais do SO
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigChan
		receiver.Stopping = true
		app.App.Stop()
	}()

	if err := app.App.Run(); err != nil {
		panic(err)
	}
}

// logInterceptor captura os logs do sistema e envia para TUI
type logInterceptor struct {
	receiver *Receiver
}

func (w *logInterceptor) Write(p []byte) (n int, err error) {
	// Remove espaços e quebras de linha invisíveis
	msg := strings.TrimSpace(string(p))
	if msg != "" {
		w.receiver.LogMsg(msg)
	}
	return len(p), nil
}

//É possível juntar esse arquivo ao receiver.go, se for necessário.
