package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// The journal is every record the gateway has read from its sources, numbered in one sequence,
// with the newest ringSize of them kept in memory. A cursor is "<epoch>-<seq>": the epoch is
// the gateway's start, so a client whose cursor is from an earlier run, or older than the ring,
// is told to reset (draw from /snapshot) instead of silently missing records.

const (
	ringSize   = 5000
	recordMax  = 64 << 10 // larger lines go out as a stub
	backlogMax = 64 << 10 // bytes read from the end of a file the first time it is seen
)

type Record struct {
	Seq    int64           `json:"seq"`
	Kind   string          `json:"kind"`   // bus, approve, or a source kind from the sources file
	Source string          `json:"source"` // e.g. the bus recipient, the request file name
	Data   json.RawMessage `json:"data"`
}

type Journal struct {
	mu     sync.Mutex
	epoch  int64
	seq    int64
	ring   []Record
	wake   chan struct{}
	follow map[string]*fileCursor
	seen   map[string]bool // dir sources: files already emitted
}

type fileCursor struct {
	inode   uint64
	pos     int64
	partial bool // pos may be mid-line (a backlog start): skip to the next line
}

func NewJournal(epoch int64) *Journal {
	return &Journal{epoch: epoch, wake: make(chan struct{}), follow: map[string]*fileCursor{}, seen: map[string]bool{}}
}

func (j *Journal) Cursor() string {
	j.mu.Lock()
	defer j.mu.Unlock()
	return fmt.Sprintf("%d-%d", j.epoch, j.seq)
}

func (j *Journal) add(kind, source string, data []byte) {
	if len(data) > recordMax || !json.Valid(data) {
		data, _ = json.Marshal(map[string]any{"truncated": true, "bytes": len(data)})
	}
	j.mu.Lock()
	j.seq++
	j.ring = append(j.ring, Record{Seq: j.seq, Kind: kind, Source: source, Data: append(json.RawMessage(nil), data...)})
	if len(j.ring) > ringSize {
		j.ring = append([]Record(nil), j.ring[len(j.ring)-ringSize:]...)
	}
	close(j.wake)
	j.wake = make(chan struct{})
	j.mu.Unlock()
}

// put adds a record that supersedes the earlier ones of its kind and source: they leave the
// ring, so a record sent several times a second (the live block) does not push history out.
func (j *Journal) put(kind, source string, data []byte) {
	j.mu.Lock()
	kept := j.ring[:0]
	for _, r := range j.ring {
		if r.Kind != kind || r.Source != source {
			kept = append(kept, r)
		}
	}
	j.ring = kept
	j.mu.Unlock()
	j.add(kind, source, data)
}

// Since returns the records after CURSOR and a channel closed at the next record; reset says the
// cursor cannot be continued (another run, or older than the ring).
func (j *Journal) Since(cursor string) (recs []Record, reset bool, wake <-chan struct{}) {
	j.mu.Lock()
	defer j.mu.Unlock()
	wake = j.wake
	after := int64(-1)
	if epoch, seq, ok := parseCursor(cursor); ok && epoch == j.epoch && seq <= j.seq {
		after = seq
	}
	if after < 0 {
		return nil, cursor != "", wake
	}
	if len(j.ring) > 0 && after < j.ring[0].Seq-1 {
		return nil, true, wake
	}
	for _, r := range j.ring {
		if r.Seq > after {
			recs = append(recs, r)
		}
	}
	return recs, false, wake
}

// Tail returns up to N newest records whose JSON stays under MAXBYTES in all.
func (j *Journal) Tail(n, maxBytes int) []Record {
	j.mu.Lock()
	defer j.mu.Unlock()
	var out []Record
	size := 0
	for i := len(j.ring) - 1; i >= 0 && len(out) < n; i-- {
		size += len(j.ring[i].Data) + 64
		if size > maxBytes {
			break
		}
		out = append(out, j.ring[i])
	}
	for l, r := 0, len(out)-1; l < r; l, r = l+1, r-1 {
		out[l], out[r] = out[r], out[l]
	}
	return out
}

func parseCursor(c string) (epoch, seq int64, ok bool) {
	a, b, found := strings.Cut(c, "-")
	if !found {
		return 0, 0, false
	}
	e, err1 := strconv.ParseInt(a, 10, 64)
	s, err2 := strconv.ParseInt(b, 10, 64)
	return e, s, err1 == nil && err2 == nil
}

// A source is one glob: `lines` sources are JSONL files followed by a byte cursor (a shrink or a
// new inode starts again at 0), `files` sources are directories of JSON files, each emitted once.
type Source struct {
	Kind string
	Mode string // lines, files, or pinned: the one session file named by ~/.claude/manager-session
	Glob string // pinned: the project's transcript directory, whose newest session is followed with no pin
	Pin  string
}

// ParseSources reads `<kind> lines|files <glob>` lines; # comments and blank lines are skipped.
func ParseSources(text, home string) ([]Source, error) {
	var out []Source
	sc := bufio.NewScanner(strings.NewReader(text))
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Fields(line)
		if len(f) != 3 || (f[1] != "lines" && f[1] != "files" && f[1] != "pinned") {
			return nil, fmt.Errorf("sources line %d: want <kind> lines|files|pinned <glob>", n)
		}
		glob := strings.Replace(f[2], "~", home, 1)
		src := Source{Kind: f[0], Mode: f[1], Glob: glob}
		if src.Mode == "pinned" { // the project's transcripts: Claude Code names the directory after it
			src.Glob = filepath.Join(home, ".claude/projects", strings.ReplaceAll(glob, "/", "-"))
			src.Pin = filepath.Join(home, ".claude/manager-session")
		}
		out = append(out, src)
	}
	return out, nil
}

// Scan reads what is new in every source once.
func (j *Journal) Scan(sources []Source) {
	for _, s := range sources {
		files, _ := filepath.Glob(s.Glob)
		sort.Strings(files)
		if s.Mode == "pinned" {
			files = []string{s.session()}
		}
		for _, f := range files {
			if s.Mode == "files" {
				j.scanFile(s, f)
			} else {
				j.scanLines(s, f)
			}
		}
	}
}

// session is the transcript of the pinned session in the project directory, else its newest one.
func (s Source) session() string {
	if id, err := os.ReadFile(s.Pin); err == nil {
		f := filepath.Join(s.Glob, strings.TrimSpace(string(id))+".jsonl")
		if _, err := os.Stat(f); err == nil {
			return f
		}
	}
	var newest string
	var when time.Time
	all, _ := filepath.Glob(filepath.Join(s.Glob, "*.jsonl"))
	for _, f := range all {
		if st, err := os.Stat(f); err == nil && st.ModTime().After(when) {
			newest, when = f, st.ModTime()
		}
	}
	return newest
}

func sourceName(s Source, file string) string {
	if s.Mode == "pinned" {
		return strings.TrimSuffix(filepath.Base(file), ".jsonl")
	}
	// bus/<to>/inbox.jsonl: the recipient; a request file: its name
	if s.Mode == "lines" {
		return filepath.Base(filepath.Dir(file))
	}
	return filepath.Base(file)
}

func (j *Journal) scanLines(s Source, file string) {
	st, err := os.Stat(file)
	if err != nil {
		return
	}
	var inode uint64
	if sys, ok := st.Sys().(*syscall.Stat_t); ok {
		inode = sys.Ino
	}
	cur := j.follow[file]
	if cur == nil {
		pos := max(0, st.Size()-backlogMax)
		cur = &fileCursor{inode: inode, pos: pos, partial: pos > 0}
		j.follow[file] = cur
	}
	if inode != cur.inode || st.Size() < cur.pos {
		cur.inode, cur.pos, cur.partial = inode, 0, false
	}
	if st.Size() == cur.pos {
		return
	}
	fh, err := os.Open(file)
	if err != nil {
		return
	}
	defer fh.Close()
	buf := make([]byte, st.Size()-cur.pos)
	n, _ := fh.ReadAt(buf, cur.pos)
	buf = buf[:n]
	end := bytes.LastIndexByte(buf, '\n')
	if end < 0 {
		return
	}
	start := 0
	if cur.partial {
		start = bytes.IndexByte(buf, '\n') + 1
		cur.partial = false
	}
	if start > end {
		cur.pos += int64(end + 1)
		return
	}
	for _, line := range bytes.Split(buf[start:end], []byte{'\n'}) {
		if len(bytes.TrimSpace(line)) > 0 {
			j.add(s.Kind, sourceName(s, file), line)
		}
	}
	cur.pos += int64(end + 1)
}

func (j *Journal) scanFile(s Source, file string) {
	st, err := os.Stat(file)
	if err != nil || !st.Mode().IsRegular() || strings.HasPrefix(filepath.Base(file), ".") {
		return
	}
	key := fmt.Sprintf("%s\x00%d", file, st.ModTime().UnixNano())
	if j.seen[key] {
		return
	}
	body, err := os.ReadFile(file)
	if err != nil {
		return
	}
	j.seen[key] = true
	j.add(s.Kind, sourceName(s, file), bytes.TrimSpace(body))
}
