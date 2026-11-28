package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// writeMsg is a tiny stand-in for homun-msg send: one JSON line appended to the inbox.
func writeMsg(t *testing.T, dir, id, msg string) {
	t.Helper()
	os.MkdirAll(dir, 0o700)
	line, _ := json.Marshal(map[string]any{"id": id, "ts": 1700000000, "from": "test", "to": "x1", "alarm": "ping", "msg": msg})
	f, err := os.OpenFile(filepath.Join(dir, "inbox.jsonl"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	f.Write(append(line, '\n'))
	f.Close()
}

// drain acknowledges events as the pump would and collects their ids.
func drain(events chan params, got *[]string, mu *sync.Mutex) {
	for p := range events {
		mu.Lock()
		*got = append(*got, p.Meta["id"]+"="+p.Content)
		mu.Unlock()
		if p.ack != nil {
			p.ack(nil)
		}
	}
}

func TestInboxResumeAndShrink(t *testing.T) {
	dir := t.TempDir()
	events := make(chan params)
	var got []string
	var mu sync.Mutex
	go drain(events, &got, &mu)
	writeMsg(t, dir, "a", "one")
	writeMsg(t, dir, "b", "two")
	os.MkdirAll(filepath.Join(dir, "cursors"), 0o700)
	b := &inbox{dir: dir, reader: "x1", events: events}
	c := b.load()
	b.step(&c)
	// a half-written line is left for later
	f, _ := os.OpenFile(filepath.Join(dir, "inbox.jsonl"), os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(`{"id":"c","alarm":"ping",`)
	f.Close()
	b.step(&c)
	// a restart reads the saved cursor and repeats nothing
	b2 := &inbox{dir: dir, reader: "x1", events: events}
	c2 := b2.load()
	f, _ = os.OpenFile(filepath.Join(dir, "inbox.jsonl"), os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(`"msg":"three"}` + "\n")
	f.Close()
	b2.step(&c2)
	// rotation: the new file is shorter and starts with an old line
	os.Remove(filepath.Join(dir, "inbox.jsonl"))
	writeMsg(t, dir, "c", "three")
	writeMsg(t, dir, "d", "four")
	b2.step(&c2)
	mu.Lock()
	defer mu.Unlock()
	if strings.Join(got, ",") != "a=one,b=two,c=three,d=four" {
		t.Fatalf("got %v", got)
	}
}

func TestBusParams(t *testing.T) {
	_, p := busParams([]byte(`{"id":"1","ts":"17","from":"sch","to":"m","alarm":"a","msg":"hi","via":"phone"}`))
	if p == nil || p.Meta["ts"] != "17" || p.Meta["via"] != "phone" || p.Meta["from"] != "sch" {
		t.Fatalf("got %+v", p)
	}
	if _, p := busParams([]byte(`{"id":"1","alarm":"a"}`)); p != nil {
		t.Fatal("no msg must be refused")
	}
	if _, p := busParams([]byte(`{"id":"1","alarm":"a","msg":"` + strings.Repeat("x", 5000) + `"}`)); p != nil {
		t.Fatal("over 4 KiB must be refused")
	}
}

// newBox makes a user box in a temp dir with one device dir per name; the box is read-only,
// as in the container.
func newBox(t *testing.T, devs ...string) *userBox {
	root := t.TempDir()
	u := &userBox{dir: filepath.Join(root, "user"), state: filepath.Join(root, "user-state")}
	for _, d := range devs {
		os.MkdirAll(filepath.Join(u.dir, d), 0o700)
	}
	return u
}

func TestUserClaimedOnce(t *testing.T) {
	u := newBox(t, "host")
	dev := filepath.Join(u.dir, "host")
	var names []string
	for i := 0; i < 50; i++ {
		n := fmt.Sprintf("%d", time.Now().UnixNano()+int64(i))
		names = append(names, n)
		os.WriteFile(filepath.Join(dev, n), []byte("msg "+n), 0o600)
	}
	os.Chmod(dev, 0o500)
	t.Cleanup(func() { os.Chmod(dev, 0o700) })
	events := make(chan params)
	var got []string
	var mu sync.Mutex
	go func() {
		for p := range events {
			mu.Lock()
			got = append(got, p.Content)
			mu.Unlock()
			if p.Meta["device"] != "host" {
				t.Error("device missing")
			}
			p.ack(nil)
		}
	}()
	u.events, u.idle = events, func() bool { return true }
	// a hook claiming the same messages mid-turn, by O_EXCL on the same sending markers
	hook := 0
	done := make(chan bool)
	go func() {
		os.MkdirAll(filepath.Join(u.state, "host", "sending"), 0o700)
		for _, n := range names {
			f, err := os.OpenFile(u.marker("host", "sending", n), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
			if err == nil {
				f.Close()
				os.MkdirAll(filepath.Join(u.state, "host", "claimed"), 0o700)
				os.Rename(u.marker("host", "sending", n), u.marker("host", "claimed", n))
				hook++
			}
		}
		done <- true
	}()
	for _, m := range u.waiting() {
		if _, err := u.send(m); err != nil {
			t.Fatal(err)
		}
	}
	<-done
	for _, m := range u.waiting() {
		u.send(m)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(got)+hook != 50 {
		t.Fatalf("sent %d + hook %d != 50", len(got), hook)
	}
	if left, _ := os.ReadDir(filepath.Join(u.state, "host", "sending")); len(left) != 0 {
		t.Fatal("sending/ not emptied")
	}
	if left, _ := os.ReadDir(dev); len(left) != 50 {
		t.Fatal("the read-only box must stay as the cockpit wrote it")
	}
	if len(u.waiting()) != 0 {
		t.Fatal("a claimed message must not be pending again")
	}
}

func TestUserDedupeByMarker(t *testing.T) {
	u := newBox(t, "host")
	os.WriteFile(filepath.Join(u.dir, "host", "1700000000000000000"), []byte("hi"), 0o600)
	os.WriteFile(filepath.Join(u.dir, "host", "1700000000000000001"), []byte("hi"), 0o600)
	os.WriteFile(filepath.Join(u.dir, "host", "1700000000000000002"), []byte("hi"), 0o600)
	for kind, id := range map[string]string{"claimed": "1700000000000000000", "failed": "1700000000000000001"} {
		os.MkdirAll(filepath.Join(u.state, "host", kind), 0o700)
		os.WriteFile(u.marker("host", kind, id), nil, 0o600)
	}
	if w := u.waiting(); len(w) != 1 || w[0].name != "1700000000000000002" {
		t.Fatalf("only the unmarked message is pending, got %v", w)
	}
	// a claimed marker made after waiting() wins: the late sending marker is dropped
	m := pending{"host", "1700000000000000002"}
	os.MkdirAll(filepath.Join(u.state, "host", "claimed"), 0o700)
	os.WriteFile(u.marker("host", "claimed", m.name), nil, 0o600)
	if ok, err := u.claim(m); ok || err != nil {
		t.Fatalf("claim of a claimed message: %v %v", ok, err)
	}
	if _, err := os.Stat(u.marker("host", "sending", m.name)); err == nil {
		t.Fatal("stray sending marker")
	}
}

func TestUserClaimErrorIsLoud(t *testing.T) {
	u := newBox(t, "host")
	os.WriteFile(filepath.Join(u.dir, "host", "1700000000000000000"), []byte("hi"), 0o600)
	// a state dir that cannot be written (a file in its place, as EROFS would refuse it)
	os.WriteFile(u.state, nil, 0o400)
	var alarms []string
	u.alarm = func(m string) { alarms = append(alarms, m) }
	m := u.waiting()[0]
	ok, err := u.send(m)
	if ok || err == nil {
		t.Fatal("an unwritable state dir must be an error, not \"taken by another reader\"")
	}
	u.broke(m, err)
	u.broke(m, err)
	if len(alarms) != 1 || !strings.Contains(alarms[0], "cannot be claimed") {
		t.Fatalf("want one claim alarm, got %q", alarms)
	}
}

func TestUserFailedMarksAndPauses(t *testing.T) {
	u := newBox(t, "host")
	os.WriteFile(filepath.Join(u.dir, "host", "1700000000000000000"), []byte(""), 0o600)
	u.events = make(chan params)
	if ok, err := u.send(u.waiting()[0]); !ok || err != nil {
		t.Fatal(ok, err)
	}
	if _, err := os.Stat(u.marker("host", "failed", "1700000000000000000")); err != nil {
		t.Fatal("no failed marker for an empty message")
	}
	if !u.paused("host") {
		t.Fatal("a failure must pause the device")
	}
}

func TestUserRecoverLeftovers(t *testing.T) {
	u := newBox(t, "host")
	os.MkdirAll(filepath.Join(u.state, "host", "sending"), 0o700)
	os.WriteFile(u.marker("host", "sending", "1700000000000000000"), nil, 0o600)
	u.recover()
	if _, err := os.Stat(u.marker("host", "failed", "1700000000000000000")); err != nil {
		t.Fatal("a sending leftover must turn failed")
	}
}

func TestUserPausedHolds(t *testing.T) {
	u := newBox(t, "phone")
	os.WriteFile(filepath.Join(u.dir, "phone", "1700000000000000000"), []byte("hi"), 0o600)
	os.MkdirAll(filepath.Join(u.state, "phone"), 0o700)
	pause := filepath.Join(u.state, "phone", "paused")
	os.WriteFile(pause, nil, 0o600)
	if len(u.waiting()) != 0 {
		t.Fatal("a paused device must hold")
	}
	old := time.Now().Add(-time.Hour)
	os.Chtimes(pause, old, old)
	if len(u.waiting()) != 1 {
		t.Fatal("a stale pause must not hold")
	}
}

func TestOldPostStillArrives(t *testing.T) {
	tok := filepath.Join(t.TempDir(), "tok")
	os.WriteFile(tok, []byte("secret\n"), 0o600)
	events := make(chan params, 1)
	srv := httptest.NewServer(handler(events, func() string { return tok }))
	defer srv.Close()
	req, _ := http.NewRequest("POST", srv.URL+"/", strings.NewReader(`{"alarm":"a","msg":"m"}`))
	req.Header.Set("X-Channel-Token", "secret")
	res, err := http.DefaultClient.Do(req)
	if err != nil || res.StatusCode != 204 {
		t.Fatalf("%v %v", err, res)
	}
	if p := <-events; p.Content != "m" {
		t.Fatalf("got %+v", p)
	}
}

func TestAwake(t *testing.T) {
	t.Setenv("CHANNEL_SERVER", "mechanic")
	t.Setenv("CHANNEL_SOURCE", "")
	if awake() {
		t.Fatal("mechanic must sleep in a scheduler session")
	}
	t.Setenv("CHANNEL_SOURCE", "mechanic")
	if !awake() || source() != "mechanic" {
		t.Fatal("mechanic must wake in its own session")
	}
}

func TestUserStallAlarmsOnce(t *testing.T) {
	u := newBox(t, "host")
	os.MkdirAll(u.state, 0o700)
	f := filepath.Join(u.dir, "host", "1700000000000000000")
	os.WriteFile(f, []byte("hi"), 0o600)
	var alarms []string
	u.idle, u.alarm = func() bool { return false }, func(m string) { alarms = append(alarms, m) }
	u.watch(time.Now())
	if len(alarms) != 0 {
		t.Fatal("a fresh message must not alarm")
	}
	later := time.Now().Add(2 * stallAfter)
	u.watch(later)
	u.watch(later)
	if len(alarms) != 1 || !strings.Contains(alarms[0], "busy") {
		t.Fatalf("want one busy alarm, got %q", alarms)
	}
	if _, err := os.Stat(filepath.Join(u.state, "stalled")); err != nil {
		t.Fatal("stalled marker missing")
	}
	os.Remove(f)
	u.watch(later)
	if _, err := os.Stat(filepath.Join(u.state, "stalled")); err == nil {
		t.Fatal("stalled marker must clear")
	}
}

func TestPumpDropsRepeatedID(t *testing.T) {
	var out bytes.Buffer
	ev := make(chan params, 4)
	r := &rpc{out: &out, events: ev, ready: make(chan struct{})}
	close(r.ready)
	go r.pump()
	for _, id := range []string{"a", "a", "", "", "b"} {
		meta := map[string]string{"alarm": "x"}
		if id != "" {
			meta["id"] = id
		}
		if err := deliver(ev, &params{Content: "m", Meta: meta}); err != nil {
			t.Fatal(err)
		}
	}
	if n := strings.Count(out.String(), "\n"); n != 4 {
		t.Fatalf("want 4 notifications (a, two without id, b), got %d: %s", n, out.String())
	}
}
