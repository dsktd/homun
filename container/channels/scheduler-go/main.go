// Channel server of the scheduler, built into the image as /usr/local/bin/scheduler-channel.
//
// Claude Code starts it over stdio (MCP, newline-delimited JSON-RPC) as the channel `scheduler`.
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
	"unicode/utf8"
)

const maxBody = 16384

const instructions = `Scheduler alarms arrive as <channel source="scheduler" alarm="..." ts="...">message</channel>. ` +
	`They are one-way: read the message, act on it as the Manager's scheduler instructions say, ` +
	`no reply is expected.`

type params struct {
	Content string            `json:"content"`
	Meta    map[string]string `json:"meta"`
}

func tokenPath() string {
	if p := os.Getenv("SCHEDULER_CHANNEL_TOKEN"); p != "" {
		return p
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "claude/.services/scheduler/channel-token")
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

func (r *rpc) send(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.out.Write(append(b, '\n'))
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
	for p := range r.events {
		r.send(message{JSONRPC: "2.0", Method: "notifications/claude/channel", Params: p})
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
			"serverInfo":      map[string]any{"name": "scheduler", "version": "0.1.0"},
			"instructions":    instructions,
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

func main() {
	port := os.Getenv("SCHEDULER_CHANNEL_PORT")
	if port == "" {
		port = "8789"
	}
	ln, err := net.Listen("tcp", "127.0.0.1:"+port)
	if err != nil {
		os.Stderr.WriteString(err.Error() + "\n")
		os.Exit(1)
	}
	events := make(chan params, 4096)
	go http.Serve(ln, handler(events, tokenPath))
	r := &rpc{out: os.Stdout, events: events, ready: make(chan struct{})}
	go r.pump()
	r.run(os.Stdin)
}
