package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Device telemetry (remote management): homun-remote sends what goes wrong on the device as
// telemetry actions, and the gateway keeps it per device in devices/<name>/:
//
//	log.jsonl    errors, warnings, the tail of *Messages*, the startup log; capped at logMax
//	status.json  the device's last answer from its fixed status allow-list
//	seen         when the device last made an authenticated request (its mtime)
//	conn.json    the streams it has open now, and since when
//	sigs         error signatures already alarmed on, one per line
//	push/        commands for the device (check, upgrade), sent once over its stream
//
// A new error signature raises one device-error alarm to the manager. The cockpit's MCP
// tools (remote logs, remote status, remote check, remote upgrade) read and write these files.

const (
	logMax     = 1 << 20 // bytes of log.jsonl before its older half is dropped
	entryMax   = 16 << 10
	telemTypes = "error warning messages startup status upgrade"
)

type DevLog struct {
	dir   string // the devices directory
	now   func() time.Time
	alarm func(device, sig, text string) error
	mu    sync.Mutex
	conns map[string]int
}

func (d *DevLog) path(name string, parts ...string) string {
	return filepath.Join(append([]string{d.dir, name}, parts...)...)
}

func (d *DevLog) mkdir(name string) error { return os.MkdirAll(d.path(name), 0o700) }

// Seen marks that NAME made an authenticated request, at most every ten seconds.
func (d *DevLog) Seen(name string) {
	p := d.path(name, "seen")
	if st, err := os.Stat(p); err == nil && d.now().Sub(st.ModTime()) < 10*time.Second {
		return
	}
	if d.mkdir(name) == nil {
		os.WriteFile(p, []byte(d.now().UTC().Format(time.RFC3339)+"\n"), 0o600)
		os.Chtimes(p, d.now(), d.now())
	}
}

// Conn counts NAME's open streams up (DELTA 1) or down (-1) and writes conn.json.
func (d *DevLog) Conn(name string, delta int) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.conns == nil {
		d.conns = map[string]int{}
	}
	d.conns[name] += delta
	if d.mkdir(name) == nil {
		body, _ := json.Marshal(map[string]any{"streams": d.conns[name], "time": d.now().UTC().Format(time.RFC3339)})
		writeAtomic(d.path(name, "conn.json"), body)
	}
}

// Record files one telemetry entry from device NAME: ARGS type, text, and sig for an error.
func (d *DevLog) Record(name string, args map[string]string) error {
	typ, text := args["type"], args["text"]
	if !strings.Contains(" "+telemTypes+" ", " "+typ+" ") {
		return fmt.Errorf("telemetry: type must be one of %s", telemTypes)
	}
	if text == "" {
		return errors.New("telemetry: text is needed")
	}
	if len(text) > entryMax {
		text = text[:entryMax] + "\n[truncated]"
	}
	if err := d.mkdir(name); err != nil {
		return err
	}
	if typ == "status" {
		if !json.Valid([]byte(text)) {
			return errors.New("telemetry: a status is JSON")
		}
		return writeAtomic(d.path(name, "status.json"), []byte(text))
	}
	sig := args["sig"]
	if typ == "error" && sig == "" {
		sum := sha256.Sum256([]byte(strings.SplitN(text, "\n", 2)[0]))
		sig = hex.EncodeToString(sum[:8])
	}
	entry := map[string]any{"time": d.now().UTC().Format(time.RFC3339), "type": typ, "text": text}
	if sig != "" {
		entry["sig"] = sig
	}
	if n := args["count"]; n != "" {
		entry["count"] = n
	}
	body, _ := json.Marshal(entry)
	if err := d.append(name, append(body, '\n')); err != nil {
		return err
	}
	if typ == "error" && d.newSig(name, sig) && d.alarm != nil {
		return d.alarm(name, sig, strings.SplitN(text, "\n", 2)[0])
	}
	return nil
}

func (d *DevLog) append(name string, line []byte) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	p := d.path(name, "log.jsonl")
	if st, err := os.Stat(p); err == nil && st.Size()+int64(len(line)) > logMax {
		old, _ := os.ReadFile(p)
		keep := old[len(old)/2:]
		if i := strings.IndexByte(string(keep), '\n'); i >= 0 {
			keep = keep[i+1:]
		}
		if err := writeAtomic(p, keep); err != nil {
			return err
		}
	}
	f, err := os.OpenFile(p, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(line)
	return err
}

// newSig reports whether SIG is new for NAME, and remembers it.
func (d *DevLog) newSig(name, sig string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	p := d.path(name, "sigs")
	old, _ := os.ReadFile(p)
	for _, s := range strings.Split(string(old), "\n") {
		if s == sig {
			return false
		}
	}
	f, err := os.OpenFile(p, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return true
	}
	defer f.Close()
	f.WriteString(sig + "\n")
	return true
}

// Pending takes NAME's queued commands (push/*.json), oldest first, removing them.
func (d *DevLog) Pending(name string) []json.RawMessage {
	files, _ := filepath.Glob(d.path(name, "push", "*.json"))
	sort.Strings(files)
	var out []json.RawMessage
	for _, f := range files {
		body, err := os.ReadFile(f)
		os.Remove(f)
		if err == nil && json.Valid(body) {
			out = append(out, body)
		}
	}
	return out
}

// alarmManager returns the alarm that tells the manager, on the given bus, about a new error
// signature of a device, from the gateway itself: never as the user's words.
func alarmManager(bus string) func(device, sig, first string) error {
	return func(device, sig, first string) error {
		return homunMsg(bus, []string{"HOMUN_ROLE=cockpit-gateway"}, "manager", "device-error",
			fmt.Sprintf("%s: %s (sig %s; remote_logs %s)", device, first, sig, device))
	}
}
