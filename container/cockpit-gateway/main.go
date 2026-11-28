// cockpit-gateway: the remote cockpit's one door to the host (design 3.6b). It follows the
// records the host cockpit reads (bus inboxes, approval scenes, any `sources` lines) into one
// numbered journal and serves, to devices holding a key:
//
//	GET  /stream?since=<cursor>  server-sent events, resumable (Last-Event-ID works too)
//	GET  /snapshot               the newest records, bounded, and the cursor to stream from
//	POST /act                    one typed action (compose, alarm, approve, api allow-list)
//	GET  /p/<id>                 the pairing page of a live code, no key (page.go)
//	POST /pair                   a one-time pairing code for a new device key (pair.go)
//	GET  /reload?file=<name>     one cockpit .el file of the source tree, for a phone with live reload on
//	GET  /client                 the client's Elisp files, framed (client.go)
//	GET  /fonts                  the cockpit's font files (HOMUN_FONTS, colon-separated), framed alike
//	GET  /ca.crt                 the proxy's root certificate, to pin on first use (a live pairing's id too)
//
// It listens on a Unix socket in its service directory, which the proxy in the manager's
// container reaches over the shared ~/claude, so it is only ever behind the proxy's TLS; the
// proxy's login is skipped here (an own-auth marker), because every endpoint checks for itself.
// The key goes in the X-Homun-Key header. /ca.crt also takes the id of a live pairing
// (X-Homun-Pair), for the phone's first start.
//
//	cockpit-gateway serve    (GATEWAY_DIR: the service directory; device keys come from its devices/;
//	                          GATEWAY_LISTEN=127.0.0.1:<port> listens there instead, for tests)
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const defaultSources = `bus lines ~/claude/.services/bus/*/inbox.jsonl
scene files ~/claude/.homun/state/stage/*.json
closed files ~/claude/.homun/state/stage/closed/*.json
transcript pinned ~/claude
glance files ~/claude/.homun/state/phone/glance.json
`

type Server struct {
	devices     Devices
	journal     *Journal
	actor       *Actor
	beat        time.Duration
	client      Client
	pairs       Pairings
	devlog      *DevLog
	reloader    *Reloader
	uploads     string // where /upload saves: <dir>/<device>/<timestamp>-<name>
	uploadMax   int64  // the byte cap of one upload; 0 is 25 MB
	downloads   string // where /download serves from, read-only
	downloadMax int64  // the byte cap of one download; 0 is 200 MB
}

func (s *Server) auth(w http.ResponseWriter, r *http.Request) (Device, bool) {
	dev, ok := s.devices.Check(r.Header.Get("X-Homun-Key"))
	if !ok {
		http.Error(w, "unknown device key", http.StatusUnauthorized)
	} else if s.devlog != nil {
		s.devlog.Seen(dev.Name)
	}
	return dev, ok
}

func (s *Server) ca(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.devices.Check(r.Header.Get("X-Homun-Key")); ok || s.pairs.Live(r.Header.Get("X-Homun-Pair")) {
		s.client.serveCA(w, r)
		return
	}
	http.Error(w, "a device key or pairing code is needed", http.StatusForbidden)
}

func (s *Server) clientRoute(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.auth(w, r); ok {
		s.client.Serve(w, r)
	}
}

func (s *Server) fontsRoute(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.auth(w, r); ok {
		s.client.ServeFonts(w, r)
	}
}

// pair exchanges a pairing code (JSON {"code": ...}) for the device and its new key, once.
func (s *Server) pair(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var req struct{ Code string }
	if err := json.NewDecoder(io.LimitReader(r.Body, 4<<10)).Decode(&req); err != nil {
		http.Error(w, "bad request: "+err.Error(), http.StatusBadRequest)
		return
	}
	dev, key, err := s.pairs.Redeem(req.Code)
	if errors.Is(err, errPair) {
		time.Sleep(time.Second) // a guess costs a second, on top of the code being used up
		// 403, not 401: url.el answers a 401 by asking for a login, which hangs a first start
		http.Error(w, err.Error(), http.StatusForbidden)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	log.Printf("cockpit-gateway: paired device %s", dev.Name)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"device": dev, "key": key})
}

func (s *Server) snapshot(w http.ResponseWriter, r *http.Request) {
	dev, ok := s.auth(w, r)
	if !ok {
		return
	}
	cursor := s.journal.Cursor()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"cursor": cursor, "device": dev, "records": s.journal.Tail(400, 512<<10), "widgets": s.journal.Widgets(), "roles": s.roles(),
		"agent": agentIdentity(), "names": s.roleNames(),
	})
}

// agentIdentity is the display name from the host-local identities/agent.json, for the phone's
// assistant header; empty fields when there is none (the phone keeps its own fallback).
func agentIdentity() map[string]string {
	out := map[string]string{}
	home, _ := os.UserHomeDir()
	raw, err := os.ReadFile(filepath.Join(home, "claude/.services/identities/agent.json"))
	if err != nil {
		return out
	}
	var a struct{ Name, Emoji string }
	if json.Unmarshal(raw, &a) == nil {
		if a.Name != "" {
			out["name"] = a.Name
		}
		if a.Emoji != "" {
			out["emoji"] = a.Emoji
		}
	}
	return out
}

// roleNames maps a role key to its display name from the role registry (the merged copy when
// the entrypoint made one), for the phone's labels; the manager takes the local agent name.
func (s *Server) roleNames() map[string]string {
	out := map[string]string{}
	for _, f := range []string{os.Getenv("ROLES_FILE"), "/dev/shm/homun/roles.json", "/opt/homun/roles.json"} {
		raw, err := os.ReadFile(f)
		if f == "" || err != nil {
			continue
		}
		var reg map[string]struct{ Name string }
		if json.Unmarshal(raw, &reg) == nil {
			for k, v := range reg {
				if v.Name != "" {
					out[k] = v.Name
				}
			}
			break
		}
	}
	if n := agentIdentity()["name"]; n != "" {
		out["manager"] = n
	}
	return out
}

// roles are the bus's recipients (a directory each), for the phone's To: picker
func (s *Server) roles() []string {
	out := []string{}
	if s.actor == nil {
		return out
	}
	ents, _ := os.ReadDir(s.actor.bus)
	for _, e := range ents {
		if e.IsDir() && busRole.MatchString(e.Name()) {
			out = append(out, e.Name())
		}
	}
	return out
}

var busRole = regexp.MustCompile(`\A[a-z][a-z0-9_-]*\z`)

func (s *Server) stream(w http.ResponseWriter, r *http.Request) {
	dev, ok := s.auth(w, r)
	if !ok {
		return
	}
	if s.devlog != nil {
		s.devlog.Conn(dev.Name, 1)
		defer s.devlog.Conn(dev.Name, -1)
	}
	fl, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "no streaming", http.StatusInternalServerError)
		return
	}
	cursor := r.URL.Query().Get("since")
	if id := r.Header.Get("Last-Event-ID"); id != "" {
		cursor = id
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	tick := time.NewTicker(s.beat)
	defer tick.Stop()
	poll := time.NewTicker(time.Second)
	defer poll.Stop()
	for {
		// commands for this device only (remote check, remote upgrade): no id, so no cursor
		if s.devlog != nil {
			for _, cmd := range s.devlog.Pending(dev.Name) {
				body, _ := json.Marshal(map[string]any{"kind": "device", "source": dev.Name, "data": cmd})
				fmt.Fprintf(w, "event: device\ndata: %s\n\n", body)
			}
		}
		recs, reset, wake := s.journal.Since(cursor)
		if reset {
			cursor = s.journal.Cursor()
			fmt.Fprintf(w, "id: %s\nevent: reset\ndata: {}\n\n", cursor)
		}
		for _, rec := range recs {
			body, _ := json.Marshal(rec)
			cursor = fmt.Sprintf("%d-%d", s.journal.epoch, rec.Seq)
			fmt.Fprintf(w, "id: %s\nevent: %s\ndata: %s\n\n", cursor, rec.Kind, body)
		}
		if cursor == "" {
			cursor = s.journal.Cursor()
			fmt.Fprintf(w, "id: %s\nevent: hello\ndata: {}\n\n", cursor)
		}
		fl.Flush()
		select {
		case <-r.Context().Done():
			return
		case <-wake:
		case <-poll.C:
		case <-tick.C:
			fmt.Fprint(w, ": beat\n\n")
		}
	}
}

func (s *Server) act(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	dev, ok := s.auth(w, r)
	if !ok {
		return
	}
	var act Action
	if err := json.NewDecoder(io.LimitReader(r.Body, 128<<10)).Decode(&act); err != nil {
		http.Error(w, "bad action: "+err.Error(), http.StatusBadRequest)
		return
	}
	res := s.actor.Do(dev, act)
	w.Header().Set("Content-Type", "application/json")
	if !res.OK && res.Error == errDenied.Error() {
		w.WriteHeader(http.StatusForbidden)
	}
	json.NewEncoder(w).Encode(res)
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/stream", s.stream)
	mux.HandleFunc("/snapshot", s.snapshot)
	mux.HandleFunc("/act", s.act)
	mux.HandleFunc("/upload", s.upload)
	mux.HandleFunc("/download", s.download)
	mux.HandleFunc("/pair", s.pair)
	mux.HandleFunc("/p/", s.page)
	mux.HandleFunc("/client", s.clientRoute)
	mux.HandleFunc("/fonts", s.fontsRoute)
	mux.HandleFunc("/ca.crt", s.ca)
	mux.HandleFunc("/reload", s.reload)
	return mux
}

func serve(here, home, bus string) error {
	text := defaultSources
	if body, err := os.ReadFile(filepath.Join(here, "sources")); err == nil {
		text = string(body)
	}
	sources, err := ParseSources(text, home)
	if err != nil {
		return err
	}
	j := NewJournal(time.Now().Unix())
	j.Scan(sources)
	reloader := &Reloader{dir: envOr("HOMUN_ELISP", "/opt/homun/emacs")}
	reloader.Scan(j)
	widgets := filepath.Join(home, "claude/.homun/state/widgets")
	j.ScanWidgets(widgets)
	stage, approve := filepath.Join(home, "claude/.homun/state/stage"), filepath.Join(home, "claude/.services/approve")
	j.CloseOrphans(stage, approve, time.Now())
	go func() {
		for range time.Tick(time.Second) {
			j.Scan(sources)
			j.ScanWidgets(widgets)
			reloader.Scan(j)
			j.CloseOrphans(stage, approve, time.Now())
		}
	}()
	live := &Live{dir: filepath.Join(home, "claude/.services/manager/stream")}
	go func() {
		for now := range time.Tick(50 * time.Millisecond) {
			live.Scan()
			live.Emit(j, now)
		}
	}()
	emacs := strings.Fields(os.Getenv("HOMUN_EMACS"))
	if len(emacs) == 0 {
		// the constant form of the cockpit's API: the words are arguments, never evaluated; the
		// reply is the Lisp-printed string "ok\n..." or "err <code>\n..."
		emacs = []string{"emacsclient", "-s", filepath.Join(home, "claude/.services/emacs/socket"), "--eval", "(homun-rpc)"}
	}
	devices := Devices{dir: filepath.Join(here, "devices")}
	devlog := &DevLog{dir: devices.dir, now: time.Now, alarm: alarmManager(bus)}
	s := &Server{
		devlog:      devlog,
		devices:     devices,
		pairs:       Pairings{dir: filepath.Join(here, "pair"), devices: devices, now: time.Now},
		journal:     j,
		reloader:    reloader,
		uploads:     filepath.Join(home, "claude/.services/uploads"),
		uploadMax:   int64(envInt("HOMUN_UPLOAD_MAX_MB", 25)) << 20,
		downloads:   filepath.Join(home, "claude/.services/downloads/files"),
		downloadMax: int64(envInt("HOMUN_DOWNLOAD_MAX_MB", 200)) << 20,
		beat:        25 * time.Second,
		client: Client{src: envOr("HOMUN_ELISP", "/opt/homun/emacs"), ca: filepath.Join(home, "claude/.services/proxy/root.crt"),
			fonts: filepath.SplitList(os.Getenv("HOMUN_FONTS"))},
		actor: &Actor{
			bus: bus, approve: filepath.Join(home, "claude/.services/approve"), widgets: widgets,
			spool: filepath.Join(home, "claude/.services/host/requests/cockpit"),
			emacs: emacs, logFile: filepath.Join(here, "actions.jsonl"), now: time.Now,
			done: map[string]Result{}, sendHook: busSend(bus), devlog: devlog,
		},
	}
	sock := filepath.Join(here, "sock")
	var ln net.Listener
	if addr := os.Getenv("GATEWAY_LISTEN"); addr != "" {
		// a test gateway on 127.0.0.1:<port> (the emulator test), never the proxy's
		sock = addr
		ln, err = net.Listen("tcp", addr)
	} else {
		os.Remove(sock)
		ln, err = net.Listen("unix", sock)
		os.Chmod(sock, 0o600)
	}
	if err != nil {
		return err
	}
	log.Printf("cockpit-gateway: on %s, %d sources", sock, len(sources))
	return http.Serve(ln, s.Handler())
}

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func main() {
	home, _ := os.UserHomeDir()
	here := os.Getenv("GATEWAY_DIR")
	if here == "" {
		here = filepath.Join(home, "claude/.services/cockpit-gateway")
	}
	if len(os.Args) != 2 || os.Args[1] != "serve" {
		fmt.Fprintln(os.Stderr, "usage: cockpit-gateway serve (device keys: homun cockpit device on the host)")
		os.Exit(2)
	}
	// the one bus setting: GATEWAY_BUS, else under GATEWAY_DIR when that is set, else the live bus
	bus := os.Getenv("GATEWAY_BUS")
	if bus == "" && os.Getenv("GATEWAY_DIR") != "" {
		bus = filepath.Join(here, "bus")
	} else if bus == "" {
		bus = filepath.Join(home, "claude/.services/bus")
	}
	if err := serve(here, home, bus); err != nil {
		fmt.Fprintln(os.Stderr, "cockpit-gateway:", err)
		os.Exit(1)
	}
}

func envInt(name string, fallback int) int {
	if n, err := strconv.Atoi(os.Getenv(name)); err == nil && n > 0 {
		return n
	}
	return fallback
}
