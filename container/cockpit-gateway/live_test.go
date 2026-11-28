package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func delta(text string) string {
	return `{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"` + text + `"}}}`
}

func TestLiveFold(t *testing.T) {
	l := &Live{}
	for _, line := range []string{
		`{"type":"stream_event","event":{"type":"message_start"}}`,
		`{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}`,
		delta("Hel"), delta("lo"),
		`{"type":"stream_event","parent_tool_use_id":"x","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"sub"}}}`,
		`{"type":"stream_event","event":{"type":"brand_new"}}`,
	} {
		l.Fold([]byte(line))
	}
	if l.text != "Hello" || l.state != "streaming" {
		t.Fatalf("got %q %s", l.text, l.state)
	}
	if l.Unhandled["brand_new"] != 1 {
		t.Fatalf("unknown event not counted: %v", l.Unhandled)
	}
	l.Fold([]byte(`{"type":"assistant","message":{}}`))
	if l.state != "done" || l.text != "Hello" {
		t.Fatalf("assistant: %q %s", l.text, l.state)
	}
	l.Fold([]byte(delta("next")))
	if l.text != "next" {
		t.Fatalf("a new block after done starts empty: %q", l.text)
	}
	l.Fold([]byte(`{"type":"result","subtype":"error_during_execution"}`))
	if l.state != "idle" || l.text != "" {
		t.Fatalf("result: %q %s", l.text, l.state)
	}
}

func TestLiveScanEmit(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "stream.jsonl")
	old := `{"type":"stream_event","event":{"type":"message_start"}}` + "\n" + delta("old") + "\n" + `{"type":"result"}` + "\n"
	os.WriteFile(file, []byte(old), 0o644)
	os.WriteFile(filepath.Join(dir, "turns"), []byte(itoa(len(old))+"\n"), 0o644)
	// the unfinished turn: begun before the gateway started
	f, _ := os.OpenFile(file, os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(delta("A") + "\n")
	l := &Live{dir: dir}
	j := NewJournal(1)
	now := time.Now()
	l.Scan()
	l.Emit(j, now)
	f.WriteString(delta("B") + "\n" + delta("C") + "\n")
	l.Scan()
	l.Emit(j, now.Add(10*time.Millisecond)) // coalesced: too soon
	l.Scan()
	l.Emit(j, now.Add(liveEvery))
	f.Close()
	var live []Record
	for _, r := range j.Tail(100, 1<<20) {
		if r.Kind == "live" {
			live = append(live, r)
		}
	}
	if len(live) != 1 {
		t.Fatalf("want one superseding live record, got %d", len(live))
	}
	var data struct{ Text, State string }
	json.Unmarshal(live[0].Data, &data)
	if data.Text != "ABC" || data.State != "streaming" {
		t.Fatalf("got %+v", data)
	}
	if j.seq != 2 {
		t.Fatalf("two emits expected, seq %d", j.seq)
	}
	// a rotated stream starts again and drops the block
	os.WriteFile(file, []byte(""), 0o644)
	l.Scan()
	if l.state != "idle" {
		t.Fatalf("rotation: %s", l.state)
	}
}

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }
