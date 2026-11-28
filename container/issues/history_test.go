package main

import (
	"testing"
	"time"
)

const v1 = `#+TODO: TODO NEXT DOING | DONE
* ctx
** TODO [#B] First thing :tag:
   :PROPERTIES:
   :ID:       1
   :END:
   :LOGBOOK:
   - Note taken on [2026-11-01 Sun 10:00] \\
     hello
   :END:
** DOING [#C] Second
   :PROPERTIES:
   :ID:       2
   :END:
`

const v2 = `* ctx
** DOING [#B] First thing :tag:
   :PROPERTIES:
   :ID:       1
   :END:
   :LOGBOOK:
   - Note taken on [2026-11-02 Mon 09:00] \\
     second note
   - Note taken on [2026-11-01 Sun 10:00] \\
     hello
   :END:
** DOING [#C] Second
   :PROPERTIES:
   :ID:       2
   :END:
** TODO New one
   :PROPERTIES:
   :ID:       3
   :END:
`

func TestParseSnaps(t *testing.T) {
	s := parseSnaps(v1)
	if len(s) != 2 || s[1].State != "TODO" || s[1].Title != "First thing" {
		t.Fatalf("bad parse: %+v", s[1])
	}
	if s[1].Notes["[2026-11-01 Sun 10:00]"] != "hello" {
		t.Fatalf("note: %+v", s[1].Notes)
	}
}

func TestDiffSnaps(t *testing.T) {
	at := time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)
	ev := diffSnaps(parseSnaps(v1), parseSnaps(v2), at)
	var got []string
	for _, e := range ev {
		got = append(got, e.Kind+":"+e.What)
	}
	want := []string{"state:TODO -> DOING", "note:note added", "created:created as TODO"}
	if len(got) != len(want) {
		t.Fatalf("got %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v want %v", got, want)
		}
	}
	if ev[1].Text != "second note" {
		t.Fatal(ev[1].Text)
	}
	if len(diffSnaps(parseSnaps(v2), parseSnaps(v2), at)) != 0 {
		t.Fatal("no-op diff should be empty")
	}
}

func TestStaleDoing(t *testing.T) {
	now := time.Date(2026, 11, 10, 0, 0, 0, 0, time.UTC)
	all := []Item{{ID: 1, State: "DOING"}, {ID: 2, State: "DOING"}, {ID: 3, State: "TODO"}}
	last := map[int]time.Time{1: now.AddDate(0, 0, -8), 2: now.AddDate(0, 0, -2), 3: now.AddDate(0, 0, -30)}
	s := staleDoing(all, last, now)
	if len(s) != 1 || s[0].Item.ID != 1 || s[0].Days != 8 {
		t.Fatalf("%+v", s)
	}
}

func TestGroupDays(t *testing.T) {
	a := time.Date(2026, 11, 2, 12, 0, 0, 0, time.Local)
	d := groupDays([]Event{{When: a}, {When: a.Add(-time.Hour)}, {When: a.AddDate(0, 0, -1)}})
	if len(d) != 2 || len(d[0].Events) != 2 {
		t.Fatalf("%+v", d)
	}
}
