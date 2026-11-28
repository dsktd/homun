package main

import (
	"bytes"
	"encoding/json"
	"io"
	"math/big"
	"os"
	"path/filepath"
	"slices"
	"syscall"
	"time"
	"unicode/utf8"
)

const (
	maxBusLine = 4096
	keepIDs    = 256
	pollEvery  = 500 * time.Millisecond
)

// cursor is a reader's place in an inbox: the byte offset after the last line it handled, the
// file's inode (a rotated inbox starts again at 0) and the last ids it delivered, so a restart
// from 0 after a shrink or rotation repeats nothing.
type cursor struct {
	Off int64    `json:"off"`
	Ino uint64   `json:"ino"`
	IDs []string `json:"ids"`
}

func (c *cursor) seen(id string) bool { return slices.Contains(c.IDs, id) }

func (c *cursor) add(id string) {
	c.IDs = append(c.IDs, id)
	if len(c.IDs) > keepIDs {
		c.IDs = c.IDs[len(c.IDs)-keepIDs:]
	}
}

type inbox struct {
	dir    string // bus/<role>
	reader string // the cursor's name
	events chan<- params
}

func (b *inbox) cursorPath() string { return filepath.Join(b.dir, "cursors", b.reader) }

func (b *inbox) load() cursor {
	var c cursor
	if data, err := os.ReadFile(b.cursorPath()); err == nil {
		json.Unmarshal(data, &c)
	}
	return c
}

func (b *inbox) save(c cursor) {
	data, _ := json.Marshal(c)
	writeAtomic(b.cursorPath(), append(data, '\n'))
}

// busParams turns one inbox line into channel params, or nil when it is not a valid message.
func busParams(line []byte) (string, *params) {
	if len(line) == 0 || len(line) > maxBusLine || !utf8.Valid(line) {
		return "", nil
	}
	var m map[string]json.RawMessage
	if json.Unmarshal(line, &m) != nil {
		return "", nil
	}
	str := func(k string) string {
		var s string
		json.Unmarshal(m[k], &s)
		return s
	}
	id, alarm, msg := str("id"), str("alarm"), str("msg")
	if id == "" || alarm == "" || msg == "" {
		return "", nil
	}
	meta := map[string]string{"alarm": alarm, "id": id}
	if n, ok := new(big.Int).SetString(string(bytes.Trim(m["ts"], `"`)), 10); ok {
		meta["ts"] = n.String()
	}
	for _, k := range []string{"from", "via"} {
		if v := str(k); v != "" {
			meta[k] = v
		}
	}
	return id, &params{Content: msg, Meta: meta}
}

// deliver hands p to the session and waits until it is written out.
func deliver(events chan<- params, p *params) error {
	done := make(chan error, 1)
	p.ack = func(err error) { done <- err }
	events <- *p
	return <-done
}

// step reads what was appended since the cursor and delivers it, line by line, saving the
// cursor after each. It returns false when there was nothing to read.
func (b *inbox) step(c *cursor) bool {
	f, err := os.Open(filepath.Join(b.dir, "inbox.jsonl"))
	if err != nil {
		return false
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return false
	}
	var ino uint64
	if s, ok := st.Sys().(*syscall.Stat_t); ok {
		ino = s.Ino
	}
	if st.Size() < c.Off || (c.Ino != 0 && ino != c.Ino) {
		c.Off = 0 // shrunk or rotated: start over, the ids keep it from repeating
	}
	c.Ino = ino
	if st.Size() == c.Off {
		return false
	}
	buf := make([]byte, st.Size()-c.Off)
	n, _ := io.ReadFull(io.NewSectionReader(f, c.Off, int64(len(buf))), buf)
	buf = buf[:n]
	for {
		i := bytes.IndexByte(buf, '\n')
		if i < 0 {
			break // a line still being written
		}
		line := bytes.TrimSpace(buf[:i])
		buf = buf[i+1:]
		c.Off += int64(i + 1)
		if id, p := busParams(line); p != nil && !c.seen(id) {
			if deliver(b.events, p) != nil {
				c.Off -= int64(i + 1)
				return false
			}
			c.add(id)
		}
		b.save(*c)
	}
	return true
}

// run tails the inbox forever and keeps bus/<role>/reader-ok fresh.
func (b *inbox) run() {
	os.MkdirAll(filepath.Join(b.dir, "cursors"), 0o700)
	go beat(filepath.Join(b.dir, "reader-ok"))
	c := b.load()
	for {
		if !b.step(&c) {
			time.Sleep(pollEvery)
		}
	}
}
