// The `cal` channel: The user's Emacs writes Markdown messages to a unix socket and they arrive in the
// Manager's session as <channel source="cal">. Nothing else may write to this socket: it lives in
// a 0700 directory, and only the server of the Manager's own Claude Code (not a `claude -p` or any
// other session) listens on it.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

var metaKey = regexp.MustCompile(`^[a-z_]{1,16}$`)

const maxCalMessage = 64 * 1024

func calDir() string {
	if p := os.Getenv("CAL_CHANNEL_DIR"); p != "" {
		return p
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "claude/.services/cal")
}

// parentPID returns the parent of pid, or 0.
func parentPID(pid int) int {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return 0
	}
	s := string(b)
	f := strings.Fields(s[strings.LastIndex(s, ")")+1:])
	if len(f) < 2 {
		return 0
	}
	n, _ := strconv.Atoi(f[1])
	return n
}

// calAllowed is the role check: start.sh sets CAL_CHANNEL only for the Manager, and the Claude
// Code that spawned this server must itself be a direct child of that start.sh
// (CLAUDE_ROLE_PID), so a `claude -p` started from a shell inside the session does not qualify.
func calAllowed() bool {
	if os.Getenv("CAL_CHANNEL") != "1" {
		return false
	}
	return roleSession()
}

// isCompactRelay says whether pid runs /opt/homun/compact-relay or `homund session relay`.
func isCompactRelay(pid int) bool {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/cmdline")
	if err != nil {
		return false
	}
	args := strings.Split(string(b), "\x00")
	for i, a := range args {
		if i > 3 {
			break
		}
		if a == "/opt/homun/compact-relay" {
			return true
		}
		if i == 0 && filepath.Base(a) == "homund" && len(args) > 2 && args[1] == "session" && args[2] == "relay" {
			return true
		}
	}
	return false
}

// calEvent validates a message and returns the notification params, or an error text.
func calEvent(msg []byte) (*params, string) {
	if len(msg) > maxCalMessage {
		return nil, "message is larger than 64 KB"
	}
	if !utf8.Valid(msg) {
		return nil, "message is not valid UTF-8"
	}
	text := strings.TrimSpace(string(msg))
	meta := map[string]string{"ts": strconv.FormatInt(time.Now().Unix(), 10)}
	if strings.HasPrefix(text, `{"meta":`) {
		var env struct {
			Meta map[string]string `json:"meta"`
			Text string            `json:"text"`
		}
		if json.Unmarshal([]byte(text), &env) == nil {
			text = strings.TrimSpace(env.Text)
			for k, v := range env.Meta {
				if metaKey.MatchString(k) && k != "ts" && k != "device" && len(v) <= 200 {
					meta[k] = v
				}
			}
		}
	}
	if text == "" {
		return nil, "message is empty"
	}
	return &params{Content: text, Meta: meta}, ""
}

// audit is the log entry of a message: its size, hash and first line, never all of it.
func audit(msg []byte) map[string]any {
	sum := sha256.Sum256(msg)
	first, _, _ := strings.Cut(strings.TrimSpace(string(msg)), "\n")
	if len(first) > 200 {
		first = strings.ToValidUTF8(first[:200], "")
	}
	return map[string]any{
		"time": time.Now().UTC().Format(time.RFC3339), "size": len(msg),
		"sha256": hex.EncodeToString(sum[:]), "first": first,
	}
}

func calAudit(dir string, msg []byte) {
	line, _ := json.Marshal(audit(msg))
	if f, err := os.OpenFile(filepath.Join(dir, "log.jsonl"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
		f.Write(append(line, '\n'))
		f.Close()
	}
}

// calWho is this listener's identity: the role the wrapper set for the session this server
// runs in, named from roles.json, plus the Claude Code session id when it is in the environment.
func calWho() map[string]string {
	role := os.Getenv("CLAUDE_ROLE")
	if role == "" {
		role = "manager"
	}
	who := map[string]string{"role": role, "name": role}
	if b, err := os.ReadFile(rolesFile()); err == nil {
		var roles map[string]struct{ Name, Emoji string }
		if json.Unmarshal(b, &roles) == nil {
			if r, ok := roles[role]; ok {
				who["name"], who["emoji"] = r.Name, r.Emoji
			}
		}
	}
	if role == "manager" {
		// The Manager's name and emoji are the agent identity (agent.json), not the registry's.
		for _, f := range []string{os.Getenv("CLAUDE_AGENT_FILE"), "/run/claude-agent.json", filepath.Join(os.Getenv("HOME"), "claude/.services/identities/agent.json"), "/opt/homun/agent.json"} {
			b, err := os.ReadFile(f)
			if f == "" || err != nil {
				continue
			}
			var a struct{ Name, Emoji string }
			if json.Unmarshal(b, &a) == nil && a.Name != "" {
				who["name"] = a.Name
				if a.Emoji != "" {
					who["emoji"] = a.Emoji
				}
				break
			}
		}
	}
	for _, k := range []string{"CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID"} {
		if v := os.Getenv(k); v != "" {
			who["session"] = v
			break
		}
	}
	return who
}

// rolesFile is the roles registry to read: ROLES_FILE, else the merged copy start-up writes to
// /dev/shm (identities included; a session started by podman exec has no ROLES_FILE), else the
// image's read-only /opt copy.
func rolesFile() string {
	for _, p := range []string{os.Getenv("ROLES_FILE"), "/dev/shm/homun/roles.json"} {
		if p == "" {
			continue
		}
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return "/opt/homun/roles.json"
}

// calServe handles one client: the message is everything it sends before closing its write side.
func calServe(c net.Conn, dir string, events chan<- params) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(10 * time.Second))
	msg, err := io.ReadAll(io.LimitReader(c, maxCalMessage+1))
	if err != nil {
		fmt.Fprintf(c, "error: %v\n", err)
		return
	}
	if string(msg) == "WHO\n" {
		json.NewEncoder(c).Encode(calWho())
		return
	}
	p, bad := calEvent(msg)
	if p == nil {
		fmt.Fprintf(c, "error: %s\n", bad)
		return
	}
	calAudit(dir, msg)
	events <- *p
	io.WriteString(c, "ok\n")
}

// calListen binds the socket (waiting while a live holder has it) and serves it forever.
func calListen(events chan<- params) {
	dir := calDir()
	sock := filepath.Join(dir, "sock")
	for {
		if os.MkdirAll(dir, 0o700) == nil {
			os.Chmod(dir, 0o700)
		}
		if c, err := net.DialTimeout("unix", sock, time.Second); err == nil {
			c.Close()
			time.Sleep(5 * time.Second)
			continue
		}
		os.Remove(sock)
		ln, err := net.Listen("unix", sock)
		if err != nil {
			os.Stderr.WriteString(err.Error() + "; retrying in 5s\n")
			time.Sleep(5 * time.Second)
			continue
		}
		os.Chmod(sock, 0o600)
		os.WriteFile(filepath.Join(dir, "who"), []byte("1\n"), 0o600) // marks a listener that answers WHO
		for {
			c, err := ln.Accept()
			if err != nil {
				break
			}
			go calServe(c, dir, events)
		}
	}
}
