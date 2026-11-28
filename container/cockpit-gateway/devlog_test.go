package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestTelemetryLogsAndAlarmsOncePerSignature(t *testing.T) {
	s, key, _ := setup(t)
	var alarms []string
	s.devlog = &DevLog{dir: s.devices.dir, now: time.Now, alarm: func(d, sig, text string) error {
		alarms = append(alarms, d+" "+text)
		return nil
	}}
	s.actor.devlog = s.devlog
	for i, body := range []string{
		`{"id":"a1","kind":"telemetry","args":{"type":"error","text":"void-function foo\nbt","sig":"s1"}}`,
		`{"id":"a2","kind":"telemetry","args":{"type":"error","text":"void-function foo\nbt","sig":"s1"}}`,
		`{"id":"a3","kind":"telemetry","args":{"type":"warning","text":"w"}}`,
		`{"id":"a4","kind":"telemetry","args":{"type":"status","text":"{\"emacs\":\"31.1\"}"}}`,
	} {
		if rec := do(t, s, key, "POST", "/act", body); rec.Code != 200 || !strings.Contains(rec.Body.String(), `"ok":true`) {
			t.Fatalf("entry %d: %d %s", i, rec.Code, rec.Body.String())
		}
	}
	if len(alarms) != 1 || alarms[0] != "phone void-function foo" {
		t.Fatalf("one alarm per signature: %v", alarms)
	}
	log, _ := os.ReadFile(filepath.Join(s.devices.dir, "phone", "log.jsonl"))
	if strings.Count(string(log), "\n") != 3 {
		t.Fatalf("three log lines: %s", log)
	}
	if _, err := os.Stat(filepath.Join(s.devices.dir, "phone", "status.json")); err != nil {
		t.Fatal("the status is kept")
	}
	if rec := do(t, s, key, "POST", "/act", `{"id":"a5","kind":"telemetry","args":{"type":"eval","text":"x"}}`); strings.Contains(rec.Body.String(), `"ok":true`) {
		t.Fatal("unknown types are refused")
	}
}

func TestPendingCommandsOnce(t *testing.T) {
	d := &DevLog{dir: t.TempDir(), now: time.Now}
	os.MkdirAll(d.path("phone", "push"), 0o700)
	os.WriteFile(d.path("phone", "push", "1.json"), []byte(`{"cmd":"check","id":"1"}`), 0o600)
	if got := d.Pending("phone"); len(got) != 1 || len(d.Pending("phone")) != 0 {
		t.Fatalf("a command goes out once: %v", got)
	}
}
