package main

import (
	"os"
	"path/filepath"
	"testing"
)

// A gateway's alarms land only on the bus it was given, whatever HOME and HOMUN_BUS say.
func TestAlarmsStayOnConfiguredBus(t *testing.T) {
	live := t.TempDir()
	t.Setenv("HOME", live)
	t.Setenv("HOMUN_BUS", filepath.Join(live, "claude/.services/bus"))
	bin := t.TempDir()
	if err := os.Symlink(mustAbs(t, "../homun-msg"), filepath.Join(bin, "homun-msg")); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))

	bus := filepath.Join(t.TempDir(), "bus")
	if err := alarmManager(bus)("phone", "sig", "boom"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(bus, "manager", "inbox.jsonl")); err != nil {
		t.Fatalf("alarm not on the configured bus: %v", err)
	}
	if _, err := os.Stat(filepath.Join(live, "claude")); err == nil {
		t.Fatal("alarm reached the live bus")
	}
}

func mustAbs(t *testing.T, p string) string {
	a, err := filepath.Abs(p)
	if err != nil {
		t.Fatal(err)
	}
	return a
}
