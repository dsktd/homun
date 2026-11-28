package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

// An action is one typed request from a device: never raw eval. Each kind checks the device's
// permissions; ids already acted on answer with their first result, so a client that resends
// after a lost reply does nothing twice.

type Action struct {
	ID   string            `json:"id"`   // the client's, unique per action
	TS   int64             `json:"ts"`   // when the user acted (queued actions keep it)
	Kind string            `json:"kind"` // compose, alarm, approve, api, telemetry
	Args map[string]string `json:"args"`
	Argv []string          `json:"argv"` // api only: the homun-api entry and its key value words
}

type Result struct {
	OK    bool   `json:"ok"`
	Reply string `json:"reply,omitempty"`
	Error string `json:"error,omitempty"`
	Again bool   `json:"again,omitempty"` // this id was acted on before; the first result
}

var (
	roleName   = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,31}$`)
	actionID   = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)
	approveID  = regexp.MustCompile(`^[A-Za-z0-9._-]{1,128}$`)
	errDenied  = errors.New("not allowed for this device")
	actionsMax = 1000
)

// apiAllowed: the homun-api entries a device may call, by "object verb". Everything that only
// draws in the cockpit runs in the remote Emacs itself; these reach state on the host.
var apiAllowed = map[string]bool{
	"ask reply":  true,
	"doctor get": true, // Run doctor on the phone's Status tab: runs the checks, changes nothing
	"state get":  true,
	// The phone's task detail: read a tracker entry and set its state (the entry itself limits
	// the state to next, done or drop)
	"tracker show":  true,
	"tracker state": true,
}

type Actor struct {
	bus      string // ~/claude/.services/bus
	approve  string // ~/claude/.services/approve
	spool    string // ~/claude/.services/host/requests/cockpit: the host service's cockpit-only requests
	widgets  string // ~/claude/.homun/state/widgets: the answers to transcript widgets
	emacs    []string
	logFile  string
	now      func() time.Time
	mu       sync.Mutex
	done     map[string]Result
	order    []string
	sendHook func(dev Device, to, alarm, msg string) error
	devlog   *DevLog
}

func (a *Actor) Do(dev Device, act Action) Result {
	if !actionID.MatchString(act.ID) {
		return Result{Error: "action id must be [A-Za-z0-9._-], 1 to 64"}
	}
	key := dev.Name + "/" + act.ID
	a.mu.Lock()
	if r, ok := a.done[key]; ok {
		a.mu.Unlock()
		r.Again = true
		return r
	}
	a.mu.Unlock()
	reply, err := a.run(dev, act)
	r := Result{OK: err == nil, Reply: reply}
	if err != nil {
		r.Error = err.Error()
	}
	a.mu.Lock()
	a.done[key] = r
	a.order = append(a.order, key)
	if len(a.order) > actionsMax {
		delete(a.done, a.order[0])
		a.order = a.order[1:]
	}
	a.mu.Unlock()
	a.log(dev, act, r)
	return r
}

func (a *Actor) run(dev Device, act Action) (string, error) {
	if act.Kind == "telemetry" && a.devlog != nil {
		// the device's own errors and status: allowed even read-only
		return "", a.devlog.Record(dev.Name, act.Args)
	}
	if dev.ReadOnly {
		return "", errDenied
	}
	switch act.Kind {
	case "compose":
		return a.compose(dev, act.Args["role"], act.Args["text"], act.Args["secret"] == "true")
	case "alarm":
		return "", a.alarm(dev, act.Args["to"], act.Args["alarm"], act.Args["msg"])
	case "approve":
		if !dev.Approve {
			return "", errDenied
		}
		return "", a.answer(dev, act.Args["id"], act.Args["answer"], act.Args["reason"])
	case "api":
		return a.api(act.Argv)
	case "recreate":
		if !dev.Approve {
			return "", errDenied
		}
		return "", a.recreate(act.ID)
	}
	return "", fmt.Errorf("unknown action kind %q: compose, alarm, approve, recreate, api, telemetry", act.Kind)
}

// compose queues the user's words for ROLE in the device's own directory, so the role's reader
// delivers them as source user with device=<name>. A secret-widget value needs the device's
// secrets permission.
func (a *Actor) compose(dev Device, role, text string, secret bool) (string, error) {
	if !roleName.MatchString(role) || role == "user" {
		return "", errors.New("compose: role must name a role")
	}
	if strings.TrimSpace(text) == "" || len(text) > 64<<10 {
		return "", errors.New("compose: text must be 1 byte to 64 KiB")
	}
	if secret && !dev.Secrets {
		return "", errDenied
	}
	if err := widgetClaim(a.widgets, text); errors.Is(err, errAnswered) {
		return "already answered", nil // another device answered this widget first: send nothing
	} else if err != nil {
		return "", err
	}
	name := fmt.Sprintf("%d", a.now().UnixNano())
	if fifo := a.headlessStream(role); fifo != "" {
		return name, a.streamTurn(fifo, dev.Name, text)
	}
	dir := filepath.Join(a.bus, role, "user", dev.Name)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return name, writeAtomic(filepath.Join(dir, name), []byte(text))
}

// headlessStream is the stream FIFO of ROLE when it runs headless: its claude reads no bus, only
// that FIFO. "" for any other role.
func (a *Actor) headlessStream(role string) string {
	base := filepath.Join(filepath.Dir(a.bus), role)
	mode, err := os.ReadFile(filepath.Join(base, "session-mode"))
	if err != nil || strings.TrimSpace(string(mode)) != "headless" {
		return ""
	}
	fifo := filepath.Join(base, "stream", "in")
	if fi, err := os.Stat(fifo); err != nil || fi.Mode()&os.ModeNamedPipe == 0 {
		return ""
	}
	return fifo
}

// streamTurn writes the user's words to FIFO as one stream-json user turn, marked as the user
// channel marks them. Without a reading broker the open fails at once.
func (a *Actor) streamTurn(fifo, device, text string) error {
	body, _ := json.Marshal(map[string]any{"type": "user", "message": map[string]any{
		"role": "user", "content": []map[string]string{{"type": "text", "text": fmt.Sprintf(
			"<channel source=\"user\" device=%q ts=%q>%s</channel>", device, a.now().Format(time.RFC3339), text)}}}})
	f, err := os.OpenFile(fifo, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return errors.New("compose: the stream is not reading")
	}
	defer f.Close()
	syscall.SetNonblock(int(f.Fd()), false)
	_, err = f.Write(append(body, '\n'))
	return err
}

func (a *Actor) alarm(dev Device, to, alarm, msg string) error {
	if !roleName.MatchString(to) {
		return errors.New("alarm: bad recipient")
	}
	if alarm == "" || len(alarm) > 64 || msg == "" {
		return errors.New("alarm: alarm and msg are needed")
	}
	return a.sendHook(dev, to, alarm, msg)
}

func (a *Actor) answer(dev Device, id, answer, reason string) error {
	if !approveID.MatchString(id) || (answer != "allow" && answer != "deny") {
		return errors.New("approve: id and answer allow|deny are needed")
	}
	file := answer
	if answer == "deny" && reason != "" {
		if len(reason) > 1000 {
			return errors.New("approve: reason over 1000 bytes")
		}
		b, _ := json.Marshal(map[string]string{"behavior": "deny", "message": reason})
		file = string(b)
	}
	if _, err := os.Stat(filepath.Join(a.approve, "requests", id+".json")); err != nil {
		return errors.New("approve: no such pending request")
	}
	dir := filepath.Join(a.approve, "answers")
	os.MkdirAll(dir, 0o700)
	if err := writeAtomic(filepath.Join(dir, id), []byte(file)); err != nil {
		return err
	}
	return a.journal(id, answer, dev.Name)
}

// journal appends the one line of an answer, the same file and shape the cockpit writes.
func (a *Actor) journal(id, answer, via string) error {
	line, _ := json.Marshal(map[string]any{"time": a.now().UTC().Format(time.RFC3339), "id": id, "answer": answer, "via": via})
	f, err := os.OpenFile(filepath.Join(a.approve, "journal.jsonl"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(append(line, '\n'))
	return err
}

// recreate files the one request the desktop's Recreate button files: a non-forced recreate in
// the cockpit's part of the host service's spool. No spool (the service never ran) is an error.
func (a *Actor) recreate(id string) error {
	if fi, err := os.Stat(a.spool); err != nil || !fi.IsDir() {
		return errors.New("recreate: the host service has no cockpit spool")
	}
	rid := fmt.Sprintf("cockpit-%d", a.now().Unix())
	body, _ := json.Marshal(map[string]any{"id": rid, "kind": "recreate", "from": "cockpit",
		"ts": a.now().Unix(), "args": map[string]bool{"force": false}})
	return writeAtomic(filepath.Join(a.spool, rid+".json"), body)
}

func (a *Actor) api(argv []string) (string, error) {
	if len(argv) < 2 || !apiAllowed[argv[0]+" "+argv[1]] {
		return "", errDenied
	}
	for _, w := range argv {
		if strings.ContainsRune(w, 0) {
			return "", errors.New("api: bad word")
		}
	}
	out, err := exec.Command(a.emacs[0], append(a.emacs[1:], argv...)...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("api: %s", strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

func (a *Actor) log(dev Device, act Action, r Result) {
	entry, _ := json.Marshal(map[string]any{
		"time": a.now().UTC().Format(time.RFC3339), "device": dev.Name, "id": act.ID,
		"kind": act.Kind, "acted": act.TS, "ok": r.OK, "error": r.Error,
	})
	if f, err := os.OpenFile(a.logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
		f.Write(append(entry, '\n'))
		f.Close()
	}
}

// busSend returns a sender that appends to the given bus through homun-msg, as from user via
// the device.
func busSend(bus string) func(dev Device, to, alarm, msg string) error {
	return func(dev Device, to, alarm, msg string) error {
		return homunMsg(bus, []string{"HOMUN_ROLE=user", "HOMUN_VIA=" + dev.Name}, to, alarm, msg)
	}
}

// homunMsg runs homun-msg send against exactly the given bus (HOMUN_BUS), never the ambient one.
func homunMsg(bus string, env []string, to, alarm, msg string) error {
	cmd := exec.Command("homun-msg", "send", to, alarm, msg)
	cmd.Env = append(os.Environ(), append(env, "HOMUN_BUS="+bus)...)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("homun-msg: %s", strings.TrimSpace(string(out)))
	}
	return nil
}
