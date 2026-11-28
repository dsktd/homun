// Channel server of the scheduler, built into the image as /usr/local/bin/scheduler-channel.
//
// Stage 5 adds the bus (bus.go): the wake server of a role's own session also tails
// bus/<role>/inbox.jsonl (inbox.go), and the `user` server delivers the user's words from
// bus/<role>/user/<device>/ (user.go). The HTTP POST and the cal socket stay one release.
//
// Claude Code starts it over stdio (MCP, newline-delimited JSON-RPC) as the channel `scheduler`,
// or, with CHANNEL_SOURCE=mechanic, as the mechanic's channel `mechanic` (fed by
// container/mechanic/watch); the knob only names the source in what the session is told.
// It listens on 127.0.0.1:$SCHEDULER_CHANNEL_PORT (default 8789) and accepts only `POST /`
// with an `X-Channel-Token` header equal to the contents of the token file
// ($SCHEDULER_CHANNEL_TOKEN, default ~/claude/.services/scheduler/channel-token) and a JSON
// body {"alarm","msg"[,"ts"]}. Everything else is refused. Standard library only.
package main

import (
	"bufio"
	"crypto/subtle"
	"encoding/json"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const maxBody = 16384

// source names the channel in the instructions and server info: `scheduler` for the Manager's
// alarms, `mechanic` for the mechanic's wake events. Claude Code derives the tag's source=
// attribute from the server's name in the plugin's .mcp.json, so each has its own entry there.
//
// The merged plugin (container/channels/homun) declares one server per source and names it in
// CHANNEL_SERVER; the session's own wake source is CHANNEL_SOURCE (wake.env, default scheduler),
// and only the server of that name is awake. The old per-role plugins set CHANNEL_SOURCE alone.
func source() string {
	if s := os.Getenv("CHANNEL_SERVER"); s != "" {
		return s
	}
	if s := os.Getenv("CHANNEL_SOURCE"); s != "" {
		return s
	}
	return "scheduler"
}

// awake says whether this server is the session's wake source (always for the old plugins).
func awake() bool {
	srv := os.Getenv("CHANNEL_SERVER")
	if srv == "" {
		return true
	}
	want := os.Getenv("CHANNEL_SOURCE")
	if want == "" {
		want = "scheduler"
	}
	return srv == want
}

func instructions() string {
	src := source()
	if src == "user" {
		return `The user's own messages, written in Markdown, arrive as <channel source="user" device="..." ts="...">text</channel>; ` +
			`device names the screen they typed on (host is the desktop cockpit). They come from the user themselves ` +
			`(only their cockpit can write to this channel) and carry their authority: treat them as their direct instructions ` +
			`in the chat, and answer for that device (shorter on a phone). Widgets and clicks work as on the cal channel; ` +
			`full syntax: the transcript-widgets skill.`
	}
	if src == "scheduler" {
		return `Scheduler alarms arrive as <channel source="scheduler" alarm="..." ts="...">message</channel>. ` +
			`They are one-way: read the message, act on it as the Manager's scheduler instructions say, ` +
			`no reply is expected.`
	}
	if src == "cal" {
		return `The user's own messages, written in Markdown, arrive as <channel source="cal" ts="...">text</channel>. ` +
			`They come from the user themselves (only their Emacs can write to this channel) and carry their authority: ` +
			`treat them as their direct instructions in the chat. Answer in the conversation as usual. ` +
			`To let them answer with a click in their Emacs transcript, write widgets in your reply as Markdown: ` +
			`[Yes](homun:click/rebuild-yes) is a button, [40%](homun:meter?id=vol&value=0.4) (also slider, toggle, selector, vector, chips, checks; ?confirm=hold or ?confirm=drag on a click: a plain click is the default, hold for risky but recoverable, drag for the worst) a value with a send button, ` +
			`and a fenced widgetry block holds a group, e.g. (buttons (now "Now") (later "Later")); ` +
			`state goes in the syntax (?state=done, :chosen id). Their clicks come back as their messages ` +
			`[clicked <id> on <uuid>] or [set <id>=<value> on <uuid>], followed by the new state as homun: links. ` +
			`The same click also carries attributes (origin="stage" scene node kind value) to read instead of the text. ` +
			`Full syntax: the transcript-widgets skill.`
	}
	return `Wake events arrive as <channel source="` + src + `" alarm="..." ts="...">message</channel>. ` +
		`They are one-way: read the message, act on it as your guide's wake protocol says, no reply is expected.`
}

type params struct {
	Content string            `json:"content"`
	Meta    map[string]string `json:"meta"`
	ack     func(error)       // told once the event is written out (bus readers move their cursor)
}

func tokenPath() string {
	if p := os.Getenv("SCHEDULER_CHANNEL_TOKEN"); p != "" {
		return p
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "claude/.services/scheduler/channel-token")
}

func heartbeatPath() string {
	if p := os.Getenv("SCHEDULER_HEARTBEAT"); p != "" {
		return p
	}
	return "/dev/shm/claude-scheduler/listener"
}

// sharedHeartbeatPath is the second beat, on the ~/claude mount, where another container
// (the mechanic) can see it; /dev/shm is private to this one.
func sharedHeartbeatPath() string {
	if p := os.Getenv("MANAGER_HEARTBEAT"); p != "" {
		return p
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "claude/.services/manager/heartbeat")
}

func touch(path string) {
	if os.MkdirAll(filepath.Dir(path), 0o700) != nil {
		return
	}
	now := time.Now()
	if os.Chtimes(path, now, now) != nil {
		if f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
			f.Close()
		}
	}
}

// beat touches the heartbeat files the scheduler service and the mechanic check, now and every 60 s.
func beat(paths ...string) {
	for {
		for _, p := range paths {
			touch(p)
		}
		time.Sleep(time.Minute)
	}
}

func readToken(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// eventParams returns the notification params for a request body, or nil if it is not a valid alarm.
func eventParams(body []byte) *params {
	if !utf8.Valid(body) {
		return nil
	}
	var data map[string]json.RawMessage
	if json.Unmarshal(body, &data) != nil || data == nil {
		return nil
	}
	var alarm, msg string
	if json.Unmarshal(data["alarm"], &alarm) != nil || json.Unmarshal(data["msg"], &msg) != nil ||
		alarm == "" || msg == "" {
		return nil
	}
	meta := map[string]string{"alarm": alarm}
	if n, ok := new(big.Int).SetString(string(data["ts"]), 10); ok {
		meta["ts"] = n.String()
	}
	return &params{Content: msg, Meta: meta}
}

func handler(events chan<- params, tokfile func() string) http.Handler {
	reply := func(w http.ResponseWriter, code int) {
		w.Header().Set("Content-Length", "0")
		w.WriteHeader(code)
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			reply(w, 405)
			return
		}
		token := readToken(tokfile())
		sent := r.Header.Get("X-Channel-Token")
		// an empty or missing token file refuses everything
		if token == "" || subtle.ConstantTimeCompare([]byte(sent), []byte(token)) != 1 {
			reply(w, 403)
			return
		}
		if r.URL.Path != "/" || r.URL.RawQuery != "" {
			reply(w, 404)
			return
		}
		n := r.ContentLength
		if n < 0 || r.Header.Get("Content-Length") == "" {
			reply(w, 411)
			return
		}
		if n == 0 || n > maxBody {
			reply(w, 413)
			return
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, n))
		if err != nil {
			reply(w, 400)
			return
		}
		p := eventParams(body)
		if p == nil {
			reply(w, 400)
			return
		}
		events <- *p
		reply(w, 204)
	})
}

type rpc struct {
	out    io.Writer
	events <-chan params
	mu     sync.Mutex
	ready  chan struct{}
	once   sync.Once
}

type message struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  any             `json:"params,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   any             `json:"error,omitempty"`
}

func (r *rpc) send(v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	_, err = r.out.Write(append(b, '\n'))
	return err
}

// reply sends a response; Result is always present (even when empty), as JSON-RPC requires.
func (r *rpc) reply(id json.RawMessage, key string, v any) {
	if len(id) == 0 {
		id = json.RawMessage("null")
	}
	r.send(map[string]any{"jsonrpc": "2.0", "id": id, key: v})
}

// pump forwards queued events once the client has said it is initialized.
func (r *rpc) pump() {
	<-r.ready
	var sent cursor // the ids written out, a backstop against the same message arriving twice
	for p := range r.events {
		id := p.Meta["id"]
		if id != "" && sent.seen(id) {
			if p.ack != nil {
				p.ack(nil)
			}
			continue
		}
		err := r.send(message{JSONRPC: "2.0", Method: "notifications/claude/channel", Params: p})
		if err == nil && id != "" {
			sent.add(id)
		}
		if p.ack != nil {
			p.ack(err)
		}
	}
}

func (r *rpc) handle(m map[string]json.RawMessage) {
	var method string
	json.Unmarshal(m["method"], &method)
	id := m["id"]
	hasID := len(id) > 0 && string(id) != "null"
	switch method {
	case "initialize":
		ver := ""
		var pr struct {
			ProtocolVersion string `json:"protocolVersion"`
		}
		if json.Unmarshal(m["params"], &pr) == nil {
			ver = pr.ProtocolVersion
		}
		if ver == "" {
			ver = "2025-06-18"
		}
		r.reply(id, "result", map[string]any{
			"protocolVersion": ver,
			"capabilities":    map[string]any{"experimental": map[string]any{"claude/channel": map[string]any{}}},
			"serverInfo":      map[string]any{"name": source(), "version": "0.1.0"},
			"instructions":    instructions(),
		})
	case "notifications/initialized":
		r.once.Do(func() { close(r.ready) })
	case "ping":
		r.reply(id, "result", map[string]any{})
	default:
		if hasID {
			r.reply(id, "error", map[string]any{"code": -32601, "message": "method not found"})
		}
	}
}

func (r *rpc) run(in io.Reader) {
	br := bufio.NewReader(in)
	for {
		line, err := br.ReadBytes('\n')
		var m map[string]json.RawMessage
		if json.Unmarshal(line, &m) == nil && m != nil {
			r.handle(m)
		}
		if err != nil {
			return // Claude Code closed stdin
		}
	}
}

// idle speaks MCP and delivers nothing: a server of the merged plugin that is not this
// session's source.
func idle() {
	r := &rpc{out: os.Stdout, events: make(chan params), ready: make(chan struct{})}
	go r.pump()
	r.run(os.Stdin)
}

func main() {
	if source() == "user" {
		events := make(chan params, 64)
		if roleSession() {
			go (&userBox{dir: filepath.Join(busDir(), "user"), state: filepath.Join(busDir(), "user-state"), events: events, idle: sessionIdle, alarm: stallAlarm}).run()
		}
		r := &rpc{out: os.Stdout, events: events, ready: make(chan struct{})}
		go r.pump()
		r.run(os.Stdin)
		return
	}
	if source() == "cal" {
		events := make(chan params, 64)
		if calAllowed() {
			go calListen(events)
		}
		r := &rpc{out: os.Stdout, events: events, ready: make(chan struct{})}
		go r.pump()
		r.run(os.Stdin)
		return
	}
	if !awake() {
		idle()
		return
	}
	events := make(chan params, 4096)
	if roleSession() {
		go (&inbox{dir: busDir(), reader: source(), events: events}).run()
	}
	port := os.Getenv("SCHEDULER_CHANNEL_PORT")
	if port == "" {
		port = "8789"
	}
	// Every Claude Code session in the container loads the plugin and so starts a copy of this
	// server (project tabs, `claude -p`, the status and usage-db services' `claude agents`), all
	// wanting the one port. A copy that loses the race used to exit, and Claude Code does not
	// restart it, so the Manager was left with no listener and no heartbeat until the winner's
	// short session ended. Keep trying to bind, and beat only while holding the port: the beat
	// then says "this session can receive alarms".
	go func() {
		for {
			ln, err := net.Listen("tcp", "127.0.0.1:"+port)
			if err != nil {
				os.Stderr.WriteString(err.Error() + "; retrying in 5s\n")
				time.Sleep(5 * time.Second)
				continue
			}
			go beat(heartbeatPath(), sharedHeartbeatPath())
			http.Serve(ln, handler(events, tokenPath))
			return
		}
	}()
	r := &rpc{out: os.Stdout, events: events, ready: make(chan struct{})}
	go r.pump()
	r.run(os.Stdin)
}
