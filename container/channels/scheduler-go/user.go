package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"time"
)

// The `user` channel: the user's words, written by the cockpit as bus/<role>/user/<device>/<ns>
// files (the nanosecond timestamp is the name). That box is read-only to every role, its own
// included, so a role cannot forge the user's words; what this reader did with a message is kept
// beside it in bus/<role>/user-state/<device>/, writable by the role alone: an empty marker
// named after the message in sending/, claimed/ or failed/. A message is pending while it has no
// marker. This server claims one by creating its sending/ marker with O_EXCL while the session is
// idle, and cal-queue-hook.sh claims the same way at the next tool step of a turn; once it is out
// the marker moves to claimed/. One that cannot be written out gets a failed/ marker and writes
// user-state/<device>/paused, which holds the device's queue (here and in the hook) until the
// cockpit retries or drops it; a pause older than 30 minutes is stale. The cockpit, the box's
// only writer, prunes claimed messages from the box, then their markers. user-state/log.jsonl
// and user-state/stalled are this reader's log and stall note.

var (
	deviceName = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)
	msgName    = regexp.MustCompile(`^[0-9]{10,}$`)
)

const (
	stalePause = 30 * time.Minute
	stallAfter = 60 * time.Second
)

type userBox struct {
	dir     string // bus/<role>/user, read-only
	state   string // bus/<role>/user-state, the role's own
	events  chan<- params
	idle    func() bool
	alarm   func(msg string) // nil: none (tests)
	stalled string           // the message the last stall alarm was for
	broken  string           // the last claim error alarmed on
}

func (u *userBox) log(entry map[string]any) {
	entry["time"] = time.Now().UTC().Format(time.RFC3339)
	line, _ := json.Marshal(entry)
	if f, err := os.OpenFile(filepath.Join(u.state, "log.jsonl"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
		f.Write(append(line, '\n'))
		f.Close()
	} else {
		fmt.Fprintf(os.Stderr, "user: cannot log %s: %v\n", line, err)
	}
}

// marker is the path of message id's marker of kind (sending, claimed, failed) for dev.
func (u *userBox) marker(dev, kind, id string) string {
	return filepath.Join(u.state, dev, kind, id)
}

// marked says whether message id of dev has any marker, so is no longer pending.
func (u *userBox) marked(dev, id string) bool {
	for _, kind := range []string{"sending", "claimed", "failed"} {
		if _, err := os.Lstat(u.marker(dev, kind, id)); err == nil {
			return true
		}
	}
	return false
}

// paused says whether a device's queue is held; a stale pause is dropped and noted.
func (u *userBox) paused(dev string) bool {
	p := filepath.Join(u.state, dev, "paused")
	st, err := os.Stat(p)
	if err != nil {
		return false
	}
	if time.Since(st.ModTime()) < stalePause {
		return true
	}
	os.Remove(p)
	u.log(map[string]any{"device": dev, "note": "stale pause ignored"})
	return false
}

type pending struct{ dev, name string }

// waiting lists the unmarked messages of every device that is not paused, oldest first.
func (u *userBox) waiting() []pending {
	var out []pending
	devs, _ := os.ReadDir(u.dir)
	for _, d := range devs {
		if !d.IsDir() || !deviceName.MatchString(d.Name()) || u.paused(d.Name()) {
			continue
		}
		files, _ := os.ReadDir(filepath.Join(u.dir, d.Name()))
		for _, f := range files {
			if f.Type().IsRegular() && msgName.MatchString(f.Name()) && !u.marked(d.Name(), f.Name()) {
				out = append(out, pending{d.Name(), f.Name()})
			}
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].name < out[j].name })
	return out
}

// move turns m's marker from kind into kind to.
func (u *userBox) move(m pending, from, to string) error {
	if err := os.MkdirAll(filepath.Dir(u.marker(m.dev, to, m.name)), 0o700); err != nil {
		return err
	}
	return os.Rename(u.marker(m.dev, from, m.name), u.marker(m.dev, to, m.name))
}

func (u *userBox) fail(m pending, why string) {
	if err := u.move(m, "sending", "failed"); err != nil {
		why += "; and no failed marker: " + err.Error()
	}
	os.WriteFile(filepath.Join(u.state, m.dev, "paused"), []byte(m.name+"\n"), 0o600)
	u.log(map[string]any{"device": m.dev, "id": m.name, "error": why})
}

// claim creates m's sending marker: false when another reader holds it already, an error
// for anything else (a read-only or missing state dir): never a silent skip.
func (u *userBox) claim(m pending) (bool, error) {
	if err := os.MkdirAll(filepath.Dir(u.marker(m.dev, "sending", m.name)), 0o700); err != nil {
		return false, err
	}
	f, err := os.OpenFile(u.marker(m.dev, "sending", m.name), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if errors.Is(err, fs.ErrExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	f.Close()
	if u.other(m) {
		os.Remove(u.marker(m.dev, "sending", m.name))
		return false, nil
	}
	return true, nil
}

// other says whether m has a claimed or failed marker besides the sending one just made (a
// reader that finished between waiting() and claim()).
func (u *userBox) other(m pending) bool {
	for _, kind := range []string{"claimed", "failed"} {
		if _, err := os.Lstat(u.marker(m.dev, kind, m.name)); err == nil {
			return true
		}
	}
	return false
}

// send claims and delivers one message; false when another reader took it first, an error
// when it could not be claimed at all.
func (u *userBox) send(m pending) (bool, error) {
	ok, err := u.claim(m)
	if !ok || err != nil {
		return false, err
	}
	text, err := os.ReadFile(filepath.Join(u.dir, m.dev, m.name))
	if err != nil {
		u.fail(m, err.Error())
		return true, nil
	}
	p, bad := calEvent(text)
	if p == nil {
		u.fail(m, bad)
		return true, nil
	}
	p.Meta["ts"] = m.name[:10]
	p.Meta["device"] = m.dev
	if err := deliver(u.events, p); err != nil {
		u.fail(m, err.Error())
		return true, nil
	}
	entry := audit(text)
	entry["device"], entry["id"] = m.dev, m.name
	if err := u.move(m, "sending", "claimed"); err != nil {
		entry["error"] = "delivered, but no claimed marker: " + err.Error()
	}
	u.log(entry)
	return true, nil
}

// broke fails loud on a claim error: one log line and one alarm per distinct error.
func (u *userBox) broke(m pending, err error) {
	msg := fmt.Sprintf("user message %s/%s cannot be claimed: %v", m.dev, m.name, err)
	fmt.Fprintln(os.Stderr, msg)
	if u.broken == msg {
		return
	}
	u.broken = msg
	u.log(map[string]any{"device": m.dev, "id": m.name, "error": msg})
	if u.alarm != nil {
		u.alarm(msg)
	}
}

// recover turns what a dead copy left in sending/ into failed/ markers (it may or may not
// have arrived), without a pause: the cockpit shows it and offers a retry.
func (u *userBox) recover() {
	devs, _ := os.ReadDir(u.state)
	for _, d := range devs {
		left, _ := filepath.Glob(filepath.Join(u.state, d.Name(), "sending", "*"))
		for _, f := range left {
			m := pending{d.Name(), filepath.Base(f)}
			why := "left in sending by a stopped reader"
			if err := u.move(m, "sending", "failed"); err != nil {
				why += "; and no failed marker: " + err.Error()
			}
			u.log(map[string]any{"device": m.dev, "id": m.name, "error": why})
		}
	}
}

// watch fails loud when the oldest pending message of a device that is not paused has waited
// over stallAfter: one alarm and one log line per stuck message, and user-state/stalled says
// which one and why while it lasts. The why names the idle source, because a `busy` that never
// clears holds the queue without any other sign.
func (u *userBox) watch(now time.Time) {
	mark := filepath.Join(u.state, "stalled")
	w := u.waiting()
	if len(w) == 0 {
		u.stalled = ""
		os.Remove(mark)
		return
	}
	m := w[0]
	st, err := os.Stat(filepath.Join(u.dir, m.dev, m.name))
	if err != nil || now.Sub(st.ModTime()) < stallAfter || u.stalled == m.name {
		return
	}
	u.stalled = m.name
	why := "the session reads idle but nothing claimed it"
	if !u.idle() {
		why = "the session reads busy (busy/status)"
	}
	msg := fmt.Sprintf("user message %s/%s unclaimed for %ds: %s", m.dev, m.name, int(now.Sub(st.ModTime()).Seconds()), why)
	os.WriteFile(mark, []byte(msg+"\n"), 0o600)
	u.log(map[string]any{"device": m.dev, "id": m.name, "error": msg})
	if u.alarm != nil {
		u.alarm(msg)
	}
}

// stallAlarm sends a stall to the role's own inbox, which the session's wake source reads
// whatever busy/status says.
func stallAlarm(msg string) {
	exec.Command("homun-msg", "send", busRole(), "user-stalled", msg).Run()
}

func (u *userBox) run() {
	if err := os.MkdirAll(u.state, 0o700); err != nil {
		fmt.Fprintf(os.Stderr, "user: no state dir %s: %v\n", u.state, err)
	}
	u.recover()
	for {
		u.watch(time.Now())
		sent := false
		if u.idle() {
			for _, m := range u.waiting() {
				ok, err := u.send(m)
				if err != nil {
					u.broke(m, err)
					break // the next ones would fail the same way
				}
				if ok {
					u.broken = ""
					sent = true
					break // one at a time: look again, the session may be busy now
				}
			}
		}
		if !sent {
			time.Sleep(pollEvery)
		}
	}
}

// sessionIdle reads the primary's busy status (busy-status.sh); other roles have none, and
// their channel events simply wait in Claude Code until the turn ends.
func sessionIdle() bool {
	if !primaryRole() {
		return true
	}
	home, _ := os.UserHomeDir()
	b, err := os.ReadFile(filepath.Join(home, "claude/.services/busy/status"))
	if err != nil {
		return true
	}
	var s struct{ State string }
	return json.Unmarshal(b, &s) != nil || s.State != "busy"
}
