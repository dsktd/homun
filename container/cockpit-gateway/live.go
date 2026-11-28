package main

import (
	"bytes"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// The live block: the reply a headless Manager is writing, folded from the text deltas of its
// broker's stream.jsonl and sent as one `live` record ({"text","state","at"}) at most every
// liveEvery, each superseding the last (Journal.put). The phone draws it at the transcript's
// end until the finished message arrives in the transcript source. A stream event the fold
// does not know is counted and logged once per kind; every other record is the transcript's.

const (
	liveEvery = 250 * time.Millisecond
	liveChars = 6000 // characters of the block sent: the phone shows its end
)

var liveHandled = map[string]bool{
	"content_block_start": true, "content_block_stop": true, "message_start": true,
	"message_delta": true, "message_stop": true, "ping": true,
	"content_block_delta/text_delta": true, "content_block_delta/thinking_delta": true,
	"content_block_delta/input_json_delta": true, "content_block_delta/signature_delta": true,
}

type Live struct {
	dir       string // the role's stream directory
	inode     uint64
	pos       int64
	started   bool
	text      string
	state     string // idle, streaming, done
	at        float64
	dirty     bool
	sent      time.Time
	Unhandled map[string]int
}

type liveRec struct {
	Type   string          `json:"type"`
	Sub    string          `json:"subtype"`
	Parent *string         `json:"parent_tool_use_id"`
	Event  json.RawMessage `json:"event"`
}

type liveEvent struct {
	Type  string `json:"type"`
	Block struct {
		Type string `json:"type"`
		Name string `json:"name"`
	} `json:"content_block"`
	Delta struct {
		Type     string `json:"type"`
		Text     string `json:"text"`
		Thinking string `json:"thinking"`
	} `json:"delta"`
}

// start is where the unfinished turn begins: the last end in the broker's turns file.
func (l *Live) start() int64 {
	body, err := os.ReadFile(filepath.Join(l.dir, "turns"))
	if err != nil {
		return 0
	}
	f := strings.Fields(string(body))
	if len(f) == 0 {
		return 0
	}
	n, _ := strconv.ParseInt(f[len(f)-1], 10, 64)
	return n
}

// Fold takes one stream line into the block.
func (l *Live) Fold(line []byte) {
	var r liveRec
	if json.Unmarshal(line, &r) != nil || r.Parent != nil {
		return
	}
	switch {
	case r.Type == "stream_event":
		var e liveEvent
		json.Unmarshal(r.Event, &e)
		kind := e.Type
		if e.Delta.Type != "" {
			kind += "/" + e.Delta.Type
		}
		if !liveHandled[kind] {
			if l.Unhandled == nil {
				l.Unhandled = map[string]int{}
			}
			if l.Unhandled[kind]++; l.Unhandled[kind] == 1 {
				log.Printf("cockpit-gateway: live: unhandled stream event %s", kind)
			}
			return
		}
		base := l.text
		if l.state != "streaming" {
			base = ""
		}
		switch e.Type {
		case "message_start":
			l.set("", "streaming")
		case "content_block_start":
			sep := ""
			if base != "" {
				sep = "\n"
			}
			switch e.Block.Type {
			case "tool_use":
				sep += "⚙ " + e.Block.Name + " "
			case "thinking":
				sep += "∴ "
			}
			l.set(base+sep, "streaming")
		case "content_block_delta":
			if more := e.Delta.Text + e.Delta.Thinking; more != "" {
				l.set(base+more, "streaming")
			}
		}
	case r.Type == "assistant":
		if l.state == "streaming" {
			l.set(l.text, "done")
		}
	case r.Type == "result" || (r.Type == "system" && r.Sub == "init"):
		l.set("", "idle")
	}
}

func (l *Live) set(text, state string) {
	if text != l.text || state != l.state {
		l.text, l.state, l.dirty = text, state, true
		l.at = float64(time.Now().UnixNano()) / 1e9
	}
}

// Scan folds what stream.jsonl gained; a new file or a shorter one starts the block again.
func (l *Live) Scan() {
	file := filepath.Join(l.dir, "stream.jsonl")
	st, err := os.Stat(file)
	if err != nil {
		return
	}
	var inode uint64
	if sys, ok := st.Sys().(*syscall.Stat_t); ok {
		inode = sys.Ino
	}
	if !l.started {
		l.started, l.inode, l.pos = true, inode, min(l.start(), st.Size())
	} else if inode != l.inode || st.Size() < l.pos {
		l.inode, l.pos = inode, 0
		l.set("", "idle")
	}
	if st.Size() == l.pos {
		return
	}
	fh, err := os.Open(file)
	if err != nil {
		return
	}
	defer fh.Close()
	buf := make([]byte, st.Size()-l.pos)
	n, _ := fh.ReadAt(buf, l.pos)
	end := bytes.LastIndexByte(buf[:n], '\n')
	if end < 0 {
		return
	}
	for _, line := range bytes.Split(buf[:end], []byte{'\n'}) {
		l.Fold(line)
	}
	l.pos += int64(end + 1)
}

// Emit puts the block into the journal when it changed and liveEvery has passed.
func (l *Live) Emit(j *Journal, now time.Time) {
	if !l.dirty || now.Sub(l.sent) < liveEvery {
		return
	}
	text := []rune(l.text)
	if len(text) > liveChars {
		text = text[len(text)-liveChars:]
	}
	data, _ := json.Marshal(map[string]any{"text": string(text), "state": l.state, "at": l.at})
	j.put("live", "manager", data)
	l.dirty, l.sent = false, now
}
