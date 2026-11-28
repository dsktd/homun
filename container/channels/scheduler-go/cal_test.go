package main

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestCalWho(t *testing.T) {
	t.Setenv("HOME", t.TempDir()) // no local-only identity
	agent := filepath.Join(t.TempDir(), "agent.json")
	os.WriteFile(agent, []byte(`{"name":"Example","emoji":"🗂️"}`), 0o600)
	t.Setenv("CLAUDE_AGENT_FILE", agent)
	roles := filepath.Join(t.TempDir(), "roles.json")
	os.WriteFile(roles, []byte(`{"manager":{"name":"Example","emoji":"🗂️"}}`), 0o600)
	t.Setenv("ROLES_FILE", roles)
	t.Setenv("CLAUDE_ROLE", "")
	ln, err := net.Listen("unix", filepath.Join(t.TempDir(), "s"))
	if err != nil {
		t.Fatal(err)
	}
	events := make(chan params, 1)
	go func() {
		c, _ := ln.Accept()
		calServe(c, t.TempDir(), events)
	}()
	a, err := net.Dial("unix", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	a.Write([]byte("WHO\n"))
	a.(*net.UnixConn).CloseWrite()
	var who map[string]string
	if err := json.NewDecoder(a).Decode(&who); err != nil {
		t.Fatal(err)
	}
	if who["role"] != "manager" || who["name"] != "Example" || who["emoji"] != "🗂️" {
		t.Fatalf("got %v", who)
	}
	if len(events) != 0 {
		t.Fatal("WHO must not become a message")
	}
}

func TestCalEventMeta(t *testing.T) {
	p, bad := calEvent([]byte(`{"meta":{"origin":"stage","node":"go","BAD":"x"},"text":"hi"}`))
	if p == nil || p.Content != "hi" || p.Meta["origin"] != "stage" || p.Meta["node"] != "go" || p.Meta["BAD"] != "" {
		t.Fatalf("got %v %q", p, bad)
	}
}
