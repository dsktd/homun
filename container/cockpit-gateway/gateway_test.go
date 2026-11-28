package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"testing"
	"time"
)

func setup(t *testing.T) (*Server, string, string) {
	t.Helper()
	home := t.TempDir()
	bus := filepath.Join(home, "claude/.services/bus")
	os.MkdirAll(filepath.Join(bus, "user"), 0o700)
	os.MkdirAll(filepath.Join(home, "claude/.services/approve/requests"), 0o700)
	here := filepath.Join(home, "gw")
	srcs, err := ParseSources(defaultSources, home)
	if err != nil {
		t.Fatal(err)
	}
	devs := Devices{dir: filepath.Join(here, "devices")}
	key := "k3y"
	os.MkdirAll(devs.dir, 0o700)
	os.WriteFile(devs.path("phone"), []byte(`{"name":"phone","sha256":"`+hashKey(key)+`"}`), 0o600)
	j := NewJournal(42)
	pairs := Pairings{dir: filepath.Join(here, "pair"), devices: devs, now: time.Now}
	s := &Server{devices: devs, pairs: pairs, journal: j, beat: time.Hour, client: Client{src: "../emacs", ca: filepath.Join(home, "ca.crt")}, actor: &Actor{
		bus: bus, approve: filepath.Join(home, "claude/.services/approve"), emacs: []string{"false"},
		logFile: filepath.Join(here, "actions.jsonl"), now: time.Now, done: map[string]Result{},
		sendHook: func(Device, string, string, string) error { return nil },
	}}
	inbox := filepath.Join(bus, "user", "inbox.jsonl")
	os.WriteFile(inbox, []byte(`{"id":"1","alarm":"a","msg":"one"}`+"\n"), 0o600)
	j.Scan(srcs)
	return s, key, home
}

func do(t *testing.T, s *Server, key, method, path, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if key != "" {
		req.Header.Set("X-Homun-Key", key)
	}
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	return rec
}

func TestKeyRefusedAtOnce(t *testing.T) {
	s, key, _ := setup(t)
	if do(t, s, "nope", "GET", "/snapshot", "").Code != 401 {
		t.Fatal("a wrong key must be refused")
	}
	if rec := do(t, s, key, "GET", "/snapshot", ""); rec.Code != 200 {
		t.Fatal("the key must work")
	}
	os.Remove(s.devices.path("phone"))
	if do(t, s, key, "GET", "/snapshot", "").Code != 401 {
		t.Fatal("a deleted device must be refused at once")
	}
}

func TestCursorResumesAndResets(t *testing.T) {
	s, _, home := setup(t)
	recs, reset, _ := s.journal.Since("42-0")
	if reset || len(recs) != 1 || recs[0].Source != "user" {
		t.Fatalf("since 0: %v %v", recs, reset)
	}
	f, _ := os.OpenFile(filepath.Join(home, "claude/.services/bus/user/inbox.jsonl"), os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(`{"id":"2","msg":"two"}` + "\n" + `{"id":"3","msg":"par`)
	f.Close()
	srcs, _ := ParseSources(defaultSources, home)
	s.journal.Scan(srcs)
	recs, _, _ = s.journal.Since("42-1")
	if len(recs) != 1 || !strings.Contains(string(recs[0].Data), "two") {
		t.Fatalf("a partial line must wait: %v", recs)
	}
	if _, reset, _ := s.journal.Since("41-1"); !reset {
		t.Fatal("a cursor of another run must reset")
	}
}

func TestStreamSendsRecords(t *testing.T) {
	s, key, _ := setup(t)
	srv := httptest.NewServer(s.Handler())
	defer srv.Close()
	req, _ := http.NewRequest("GET", srv.URL+"/stream?since=42-0", nil)
	req.Header.Set("X-Homun-Key", key)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	sc := bufio.NewScanner(resp.Body)
	var got []string
	for sc.Scan() && len(got) < 3 {
		if sc.Text() != "" {
			got = append(got, sc.Text())
		}
	}
	if got[0] != "id: 42-1" || got[1] != "event: bus" || !strings.Contains(got[2], `"one"`) {
		t.Fatalf("stream: %q", got)
	}
}

func TestComposeOnceAndPermissions(t *testing.T) {
	s, key, home := setup(t)
	act := `{"id":"c1","ts":1,"kind":"compose","args":{"role":"manager","text":"hi"}}`
	var r1, r2 Result
	json.Unmarshal(do(t, s, key, "POST", "/act", act).Body.Bytes(), &r1)
	json.Unmarshal(do(t, s, key, "POST", "/act", act).Body.Bytes(), &r2)
	files, _ := os.ReadDir(filepath.Join(home, "claude/.services/bus/manager/user/phone"))
	if !r1.OK || !r2.Again || len(files) != 1 {
		t.Fatalf("compose once: %+v %+v %d files", r1, r2, len(files))
	}
	secret := `{"id":"c2","kind":"compose","args":{"role":"manager","text":"pw","secret":"true"}}`
	if do(t, s, key, "POST", "/act", secret).Code != 403 {
		t.Fatal("a secret needs the secrets permission")
	}
	if do(t, s, key, "POST", "/act", `{"id":"a1","kind":"approve","args":{"id":"x","answer":"allow"}}`).Code != 403 {
		t.Fatal("approve needs the approve permission")
	}
	if do(t, s, key, "POST", "/act", `{"id":"e1","kind":"api","argv":["load","file","x"]}`).Code != 403 {
		t.Fatal("api outside the allow-list must be refused")
	}
}

func TestApiAllowsTrackerShowAndStateOnly(t *testing.T) {
	s, key, _ := setup(t)
	s.actor.emacs = []string{"true"}
	for id, argv := range map[string]string{
		"t1": `["tracker","show","id","7"]`,
		"t2": `["tracker","state","id","7","state","done"]`,
	} {
		body := `{"id":"` + id + `","kind":"api","argv":` + argv + `}`
		if c := do(t, s, key, "POST", "/act", body).Code; c != 200 {
			t.Fatalf("%s: status %d", argv, c)
		}
	}
	for id, argv := range map[string]string{
		"n1": `["tracker","add","title","x"]`,
		"n2": `["tracker","note","id","7","text","x"]`,
	} {
		body := `{"id":"` + id + `","kind":"api","argv":` + argv + `}`
		if c := do(t, s, key, "POST", "/act", body).Code; c != 403 {
			t.Fatalf("%s must be refused, status %d", argv, c)
		}
	}
}

func TestRecreateFilesOnlyTheCockpitRequest(t *testing.T) {
	s, _, home := setup(t)
	spool := filepath.Join(home, "claude/.services/host/requests/cockpit")
	s.actor.spool = spool
	plain := Device{Name: "phone"}
	if r := s.actor.Do(plain, Action{ID: "r1", Kind: "recreate"}); r.OK {
		t.Fatal("recreate needs the approve permission")
	}
	dev := Device{Name: "phone", Approve: true}
	if r := s.actor.Do(dev, Action{ID: "r2", Kind: "recreate"}); r.OK {
		t.Fatal("no spool must fail")
	}
	os.MkdirAll(spool, 0o700)
	if r := s.actor.Do(dev, Action{ID: "r3", Kind: "recreate", Args: map[string]string{"force": "true"}}); !r.OK {
		t.Fatalf("recreate: %+v", r)
	}
	files, _ := os.ReadDir(spool)
	if len(files) != 1 {
		t.Fatalf("one request file, got %d", len(files))
	}
	b, _ := os.ReadFile(filepath.Join(spool, files[0].Name()))
	var req struct {
		Kind string
		From string
		Args map[string]bool
	}
	json.Unmarshal(b, &req)
	if req.Kind != "recreate" || req.From != "cockpit" || req.Args["force"] {
		t.Fatalf("request: %s", b)
	}
}

func TestApproveAnswersOnceAndJournals(t *testing.T) {
	s, key, home := setup(t)
	dev := Device{Name: "phone", Approve: true}
	approve := filepath.Join(home, "claude/.services/approve")
	if err := s.actor.answer(dev, "1-1", "allow", ""); err == nil {
		t.Fatal("no request, no answer")
	}
	os.WriteFile(filepath.Join(approve, "requests", "1-1.json"), []byte(`{"id":"1-1"}`), 0o600)
	if err := s.actor.answer(dev, "1-1", "allow", ""); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(filepath.Join(approve, "answers", "1-1"))
	line, _ := os.ReadFile(filepath.Join(approve, "journal.jsonl"))
	if string(got) != "allow" || strings.Count(string(line), "\n") != 1 || !strings.Contains(string(line), `"via":"phone"`) {
		t.Fatalf("answer %q journal %q", got, line)
	}
	_ = key
}

func TestDenyCarriesTheReason(t *testing.T) {
	s, _, home := setup(t)
	dev := Device{Name: "phone", Approve: true}
	approve := filepath.Join(home, "claude/.services/approve")
	os.WriteFile(filepath.Join(approve, "requests", "1-2.json"), []byte(`{"id":"1-2"}`), 0o600)
	if err := s.actor.answer(dev, "1-2", "deny", `not "main"`); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(filepath.Join(approve, "answers", "1-2"))
	if string(got) != `{"behavior":"deny","message":"not \"main\""}` {
		t.Fatalf("answer %s", got)
	}
}

// Every scene the homund store keeps reaches the phone, not only approvals.
func TestScenesAndClosesAreRecords(t *testing.T) {
	_, _, home := setup(t)
	stage := filepath.Join(home, "claude/.homun/state/stage")
	os.MkdirAll(filepath.Join(stage, "closed"), 0o700)
	os.WriteFile(filepath.Join(stage, "approve-1-1.json"), []byte(`{"id":"approve-1-1"}`), 0o600)
	os.WriteFile(filepath.Join(stage, "other.json"), []byte(`{"id":"other"}`), 0o600)
	os.WriteFile(filepath.Join(stage, "closed", "approve-0-0.json"), []byte(`{"id":"approve-0-0"}`), 0o600)
	srcs, _ := ParseSources(defaultSources, home)
	j := NewJournal(1)
	j.Scan(srcs)
	var kinds []string
	for _, r := range j.Tail(10, 1<<20) {
		kinds = append(kinds, r.Kind+":"+r.Source)
	}
	if strings.Join(kinds, " ") != "bus:user scene:approve-1-1.json scene:other.json closed:approve-0-0.json" {
		t.Fatalf("records %v", kinds)
	}
}

func TestPinnedTranscript(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, ".claude/projects", strings.ReplaceAll(filepath.Join(home, "claude"), "/", "-"))
	os.MkdirAll(dir, 0o700)
	os.WriteFile(filepath.Join(dir, "old.jsonl"), []byte(`{"n":1}`+"\n"), 0o600)
	os.WriteFile(filepath.Join(dir, "pin.jsonl"), []byte(`{"n":2}`+"\n"), 0o600)
	os.WriteFile(filepath.Join(home, ".claude/manager-session"), []byte("pin\n"), 0o600)
	srcs, err := ParseSources("transcript pinned "+filepath.Join(home, "claude"), home)
	if err != nil {
		t.Fatal(err)
	}
	j := NewJournal(1)
	j.Scan(srcs)
	f, _ := os.OpenFile(filepath.Join(dir, "pin.jsonl"), os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(`{"n":3}` + "\n")
	f.Close()
	j.Scan(srcs)
	recs := j.Tail(10, 1<<20)
	if len(recs) != 2 || recs[1].Source != "pin" || string(recs[1].Data) != `{"n":3}` {
		t.Fatalf("records %+v", recs)
	}
}

func TestReloadAnnouncesChangesAndServesOnlyCockpitFiles(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "a.el"), []byte("(a)"), 0o600)
	r := &Reloader{dir: dir}
	j := NewJournal(1)
	r.Scan(j) // the baseline: nothing announced
	r.Scan(j)
	os.WriteFile(filepath.Join(dir, "a.el"), []byte("(a2)"), 0o600)
	r.Scan(j)
	recs := j.Tail(10, 1<<20)
	if len(recs) != 1 || recs[0].Kind != "reload" || recs[0].Source != "a.el" {
		t.Fatalf("records %+v", recs)
	}
	if _, _, ok := r.read("../../etc/passwd"); ok {
		t.Fatal("path outside the tree served")
	}
	if _, _, ok := r.read("a.txt"); ok {
		t.Fatal("non-el served")
	}
	if body, _, ok := r.read("a.el"); !ok || string(body) != "(a2)" {
		t.Fatal("el not served")
	}
}

func TestReloadManifestListsEveryFileAndAVersion(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "a.el"), []byte("(a)"), 0o600)
	r := &Reloader{dir: dir}
	m := r.Manifest()
	files := m["files"].(map[string]string)
	if _, sum, _ := r.read("a.el"); len(files) != 1 || files["a.el"] != sum {
		t.Fatalf("manifest %+v", m)
	}
	s, key, _ := setup(t)
	s.reloader = r
	if w := do(t, s, key, "GET", "/reload", ""); w.Code != 200 || !strings.Contains(w.Body.String(), `"a.el":"`+files["a.el"]) {
		t.Fatalf("GET /reload %d %s", w.Code, w.Body)
	}
	v := m["version"].(string)
	os.WriteFile(filepath.Join(dir, "a.el"), []byte("(a2)"), 0o600)
	if len(v) != 8 || r.Manifest()["version"] == v {
		t.Fatalf("version %q did not change", v)
	}
}

func TestClientFiles(t *testing.T) {
	s, key, _ := setup(t)
	if do(t, s, "", "GET", "/client", "").Code != 401 || do(t, s, "nope", "GET", "/client", "").Code != 401 {
		t.Fatal("the client files need a key")
	}
	body := do(t, s, key, "GET", "/client", "").Body.String()
	want, _ := os.ReadFile("../emacs/claude-remote.el")
	sum := sha256.Sum256(want)
	head := hex.EncodeToString(sum[:]) + fmt.Sprintf(" claude-remote.el %d\n", len(want))
	if !strings.Contains(body, head+string(want)+"\n") || !strings.Contains(body, " widgetry-core.el ") ||
		regexp.MustCompile(`(?m)^[0-9a-f]{64} (init|homun-init|cockpit)\.el \d+$`).MatchString(body) {
		t.Fatal("the bundle holds the client's files, framed, and not the host's")
	}
}

func TestFontsServedFramedAndAuthed(t *testing.T) {
	s, key, home := setup(t)
	f := filepath.Join(home, "Mono.ttf")
	os.WriteFile(f, []byte("fontbytes"), 0o600)
	s.client.fonts = []string{f, filepath.Join(home, "missing.ttf")}
	if do(t, s, "", "GET", "/fonts", "").Code != 401 {
		t.Fatal("fonts need a device key")
	}
	rec := do(t, s, key, "GET", "/fonts", "")
	sum := sha256.Sum256([]byte("fontbytes"))
	want := hex.EncodeToString(sum[:]) + " Mono.ttf 9\nfontbytes\n"
	if rec.Code != 200 || rec.Body.String() != want {
		t.Fatalf("got %d %q", rec.Code, rec.Body.String())
	}
	s.client.fonts = nil
	if do(t, s, key, "GET", "/fonts", "").Code != 404 {
		t.Fatal("no list, no fonts")
	}
}

func TestComposeHeadlessGoesToStream(t *testing.T) {
	s, key, home := setup(t)
	base := filepath.Join(home, "claude/.services/mechanic")
	os.MkdirAll(filepath.Join(base, "stream"), 0o700)
	os.WriteFile(filepath.Join(base, "session-mode"), []byte("headless\n"), 0o600)
	fifo := filepath.Join(base, "stream", "in")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	act := `{"id":"h1","kind":"compose","args":{"role":"mechanic","text":"to bolt"}}`
	if r := do(t, s, key, "POST", "/act", act); !strings.Contains(r.Body.String(), "not reading") {
		t.Fatalf("no reader must fail: %s", r.Body.String())
	}
	got := make(chan string, 1)
	go func() {
		f, _ := os.Open(fifo)
		b, _ := io.ReadAll(f)
		got <- string(b)
	}()
	time.Sleep(100 * time.Millisecond)
	act = `{"id":"h2","kind":"compose","args":{"role":"mechanic","text":"to bolt"}}`
	do(t, s, key, "POST", "/act", act)
	var turn struct {
		Message struct{ Content []struct{ Text string } }
	}
	if err := json.Unmarshal([]byte(<-got), &turn); err != nil || len(turn.Message.Content) != 1 {
		t.Fatalf("stream turn: %v %+v", err, turn)
	}
	if text := turn.Message.Content[0].Text; !strings.Contains(text, `source="user" device="phone"`) || !strings.HasSuffix(text, "to bolt</channel>") {
		t.Fatalf("stream turn: %q", text)
	}
	if _, err := os.Stat(filepath.Join(base, "../bus/mechanic/user/phone")); err == nil {
		t.Fatal("a headless role's words must not sit in the bus")
	}
}

func TestOrphanSceneIsClosed(t *testing.T) {
	_, _, home := setup(t)
	stage := filepath.Join(home, "claude/.homun/state/stage")
	approve := filepath.Join(home, "claude/.services/approve")
	os.MkdirAll(stage, 0o700)
	os.MkdirAll(filepath.Join(approve, "requests"), 0o700)
	os.WriteFile(filepath.Join(stage, "approve.json"), []byte(`{"id":"approve"}`), 0o600)
	os.WriteFile(filepath.Join(approve, "requests", "2-2.json"), []byte(`{"since":1000,"timeout":60}`), 0o600)
	j := NewJournal(1)
	j.CloseOrphans(stage, approve, time.Unix(1030, 0))
	if got := j.Tail(10, 1<<20); len(got) != 0 {
		t.Fatalf("closed while a request is pending: %v", got)
	}
	j.CloseOrphans(stage, approve, time.Unix(1100, 0))
	j.CloseOrphans(stage, approve, time.Unix(1100, 0))
	if got := j.Tail(10, 1<<20); len(got) != 1 || got[0].Source != "approve.json" || got[0].Kind != "closed" {
		t.Fatalf("expired queue not closed once: %v", got)
	}
}

func TestGlanceFileIsStreamedOncePerChange(t *testing.T) {
	home := t.TempDir()
	srcs, err := ParseSources(defaultSources, home)
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(home, "claude/.homun/state/phone")
	os.MkdirAll(dir, 0o700)
	file := filepath.Join(dir, "glance.json")
	os.WriteFile(file, []byte(`{"tasks":[]}`), 0o600)
	j := NewJournal(1)
	j.Scan(srcs)
	j.Scan(srcs)
	n := 0
	for _, r := range j.ring {
		if r.Kind == "glance" {
			n++
		}
	}
	if n != 1 {
		t.Fatalf("glance records = %d, want 1", n)
	}
}

func TestRolesAreTheBusDirectories(t *testing.T) {
	s, _, _ := setup(t)
	os.MkdirAll(filepath.Join(s.actor.bus, "mechanic"), 0o700)
	os.WriteFile(filepath.Join(s.actor.bus, "stray.txt"), nil, 0o600)
	if got := strings.Join(s.roles(), " "); got != "mechanic user" {
		t.Fatalf("roles %q", got)
	}
}

// The manifest is the phone's file set: the host daemon's start-up (init.el, cockpit.el) is
// never offered, or turning live reload on would evaluate the desktop's config on the phone.
func TestReloadManifestIsTheClientSet(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "widgetry"), 0o700)
	for _, n := range []string{"a.el", "init.el", "cockpit.el", "homun-init.el", "widgetry/widgetry-x.el", "widgetry/bench.el"} {
		os.WriteFile(filepath.Join(dir, n), []byte("()"), 0o600)
	}
	files := (&Reloader{dir: dir}).Manifest()["files"].(map[string]string)
	if len(files) != 2 || files["a.el"] == "" || files["widgetry/widgetry-x.el"] == "" {
		t.Fatalf("manifest %v", files)
	}
	if _, _, ok := (&Reloader{dir: dir}).read("init.el"); ok {
		t.Fatal("init.el served")
	}
}

func TestWidgetAnswerIsSharedAndSentOnce(t *testing.T) {
	s, key, home := setup(t)
	dir := filepath.Join(home, "claude/.homun/state/widgets")
	s.actor.widgets = dir
	text := "[clicked later on u1] homun:click/later?state=done"
	act := func(id string) Result {
		var r Result
		body := `{"id":"` + id + `","kind":"compose","args":{"role":"manager","text":` + fmt.Sprintf("%q", text) + `}}`
		json.Unmarshal(do(t, s, key, "POST", "/act", body).Body.Bytes(), &r)
		return r
	}
	act("w1")
	r := act("w2") // another action, same widget: the second answer is not sent
	files, _ := os.ReadDir(filepath.Join(home, "claude/.services/bus/manager/user/phone"))
	if !r.OK || len(files) != 1 {
		t.Fatalf("one answer sent: %+v, %d files", r, len(files))
	}
	// a desktop answer is a file in the store: a late joiner's snapshot carries both
	os.MkdirAll(filepath.Join(dir, "u2"), 0o700)
	os.WriteFile(filepath.Join(dir, "u2", "vol"), []byte("[set vol=0.7 on u2] homun:meter?id=vol&value=0.7&state=done"), 0o600)
	s.journal.ScanWidgets(dir)
	var snap struct {
		Widgets []Record `json:"widgets"`
	}
	json.Unmarshal(do(t, s, key, "GET", "/snapshot", "").Body.Bytes(), &snap)
	if len(snap.Widgets) != 2 || !strings.Contains(string(snap.Widgets[0].Data), "state=done") {
		t.Fatalf("snapshot widgets: %+v", snap.Widgets)
	}
}

func TestSnapshotCarriesRoleNames(t *testing.T) {
	s, key, home := setup(t)
	reg := filepath.Join(home, "roles.json")
	os.WriteFile(reg, []byte(`{"alpha":{"name":"Placeholder"},"beta":{}}`), 0o600)
	t.Setenv("ROLES_FILE", reg)
	var snap struct{ Names map[string]string }
	json.Unmarshal(do(t, s, key, "GET", "/snapshot", "").Body.Bytes(), &snap)
	if snap.Names["alpha"] != "Placeholder" || snap.Names["beta"] != "" {
		t.Fatalf("names = %v", snap.Names)
	}
}
