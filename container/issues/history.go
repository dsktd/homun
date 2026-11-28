package main

// Activity timeline: events derived from the git history of the tracker file.
// Each commit's version of the file is parsed into a small per-issue summary
// and consecutive summaries are compared. No model calls; same history, same
// events.

import (
	"bufio"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	headRe  = regexp.MustCompile(`^\*+ (TODO|NEXT|DOING|WAIT|DONE|DROP) (?:\[#[A-Z]\] )?(.*?)(?:\s+:[\w@:]+:)?\s*$`)
	idLine  = regexp.MustCompile(`^\s*:ID:\s+(\d+)\s*$`)
	noteRe  = regexp.MustCompile(`^\s*- Note taken on (\[[^\]]+\])`)
	tsLayou = "[2006-01-02 Mon 15:04]"
)

// Snap is one issue as seen in one version of the file.
type Snap struct {
	State, Title string
	Notes        map[string]string // timestamp -> first text line
}

// parseSnaps summarises an org file by issue id.
func parseSnaps(src string) map[int]*Snap {
	out := map[int]*Snap{}
	var cur *Snap
	var pending *Snap
	var note string
	sc := bufio.NewScanner(strings.NewReader(src))
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		l := sc.Text()
		if m := headRe.FindStringSubmatch(l); m != nil {
			pending, cur, note = &Snap{State: m[1], Title: m[2], Notes: map[string]string{}}, nil, ""
			continue
		}
		if pending == nil {
			continue
		}
		if m := idLine.FindStringSubmatch(l); m != nil && cur == nil {
			id, _ := strconv.Atoi(m[1])
			cur = pending
			out[id] = cur
			continue
		}
		if m := noteRe.FindStringSubmatch(l); m != nil {
			note = m[1]
			pending.Notes[note] = ""
		} else if note != "" {
			pending.Notes[note] = strings.TrimSpace(l)
			note = ""
		}
	}
	return out
}

type Event struct {
	When  time.Time
	ID    int
	Title string
	What  string // "created", "TODO -> DOING", "note added", ...
	Text  string // note text, when a note was added
	Kind  string // created, state, note
}

// diffSnaps lists what changed between two versions of the file.
func diffSnaps(old, cur map[int]*Snap, at time.Time) []Event {
	var ev []Event
	ids := make([]int, 0, len(cur))
	for id := range cur {
		ids = append(ids, id)
	}
	sort.Ints(ids)
	for _, id := range ids {
		c := cur[id]
		o, ok := old[id]
		e := Event{When: at, ID: id, Title: c.Title}
		if !ok {
			e.Kind, e.What = "created", "created as "+c.State
			ev = append(ev, e)
			continue
		}
		if o.State != c.State {
			x := e
			x.Kind, x.What = "state", o.State+" -> "+c.State
			ev = append(ev, x)
		}
		var ts []string
		for t := range c.Notes {
			if _, had := o.Notes[t]; !had {
				ts = append(ts, t)
			}
		}
		sort.Strings(ts)
		for _, t := range ts {
			x := e
			x.Kind, x.What, x.Text = "note", "note added", clip(c.Notes[t], 140)
			ev = append(ev, x)
		}
	}
	return ev
}

type commit struct {
	hash string
	at   time.Time
}

var (
	histMu    sync.Mutex
	snapCache = map[string]map[int]*Snap{}
)

func git(dir string, args ...string) (string, error) {
	out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).Output()
	return string(out), err
}

// history returns events, newest first, and the last change time per issue.
func history(path string, days int) ([]Event, map[int]time.Time, error) {
	dir := path[:strings.LastIndex(path, "/")+1]
	if dir == "" {
		dir = "."
	}
	out, err := git(dir, "log", "--reverse", "--format=%H %aI", "--", path)
	if err != nil {
		return nil, nil, err
	}
	var cs []commit
	for _, l := range strings.Split(strings.TrimSpace(out), "\n") {
		h, d, ok := strings.Cut(l, " ")
		if t, err := time.Parse(time.RFC3339, d); ok && err == nil {
			cs = append(cs, commit{h, t})
		}
	}
	histMu.Lock()
	defer histMu.Unlock()
	var ev []Event
	last := map[int]time.Time{}
	var prev map[int]*Snap
	cutoff := time.Now().AddDate(0, 0, -days)
	for n, c := range cs {
		s, ok := snapCache[c.hash]
		if !ok {
			src, err := git(dir, "show", c.hash+":./"+path[strings.LastIndex(path, "/")+1:])
			if err != nil {
				return nil, nil, err
			}
			s = parseSnaps(src)
			snapCache[c.hash] = s
		}
		if n > 0 {
			for _, e := range diffSnaps(prev, s, c.at) {
				last[e.ID] = e.When
				if e.When.After(cutoff) {
					ev = append(ev, e)
				}
			}
		}
		prev = s
	}
	sort.SliceStable(ev, func(a, b int) bool { return ev[a].When.After(ev[b].When) })
	return ev, last, nil
}

type Day struct {
	Date   string
	Events []Event
}

func groupDays(ev []Event) []Day {
	var days []Day
	for _, e := range ev {
		d := e.When.In(time.Local).Format("2006-01-02 Mon")
		if len(days) == 0 || days[len(days)-1].Date != d {
			days = append(days, Day{Date: d})
		}
		days[len(days)-1].Events = append(days[len(days)-1].Events, e)
	}
	return days
}

type Stale struct {
	Item Item
	Days int
}

// staleDoing: DOING items with no change for 7+ days, oldest first.
func staleDoing(all []Item, last map[int]time.Time, now time.Time) []Stale {
	var out []Stale
	for _, i := range all {
		if i.State != "DOING" {
			continue
		}
		t, ok := last[i.ID]
		if !ok {
			t, _ = time.ParseInLocation(tsLayou, i.Created, time.Local)
		}
		if d := int(now.Sub(t).Hours() / 24); d >= 7 && !t.IsZero() {
			out = append(out, Stale{i, d})
		}
	}
	sort.SliceStable(out, func(a, b int) bool { return out[a].Days > out[b].Days })
	return out
}

func clip(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n]) + "..."
	}
	return s
}
