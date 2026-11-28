package main

// Workspaces under ~/claude and what the maintenance scan last saw in them.
// Read-only: the scan is services/maint's hygiene.jsonl, up to a day old.

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

var (
	root     = filepath.Join(os.Getenv("HOME"), "claude")
	hygiene  = filepath.Join(root, ".services", "maint", "hygiene.jsonl")
	notSpace = map[string]bool{"_tools": true, ".bare": true, ".services": true}
)

type Tree struct {
	Path   string
	Branch string
	Dirty  bool
	Ahead  int
	Behind int
}

// trees returns the scanned worktrees by workspace name, and the scan's time.
func trees() (map[string][]Tree, time.Time) {
	out := map[string][]Tree{}
	f, err := os.Open(hygiene)
	if err != nil {
		return out, time.Time{}
	}
	defer f.Close()
	st, _ := f.Stat()
	sc := bufio.NewScanner(f)
	sc.Buffer(nil, 1<<24)
	for sc.Scan() {
		var r struct{ Worktrees []Tree }
		if json.Unmarshal(sc.Bytes(), &r) != nil {
			continue
		}
		for _, t := range r.Worktrees {
			if dir := filepath.Dir(filepath.Clean(t.Path)); filepath.Dir(dir) == root {
				out[filepath.Base(dir)] = append(out[filepath.Base(dir)], t)
			}
		}
	}
	return out, st.ModTime()
}

// untracked lists the workspaces under root that no issue links to.
func untracked(all []Item) []string {
	linked := map[string]bool{}
	for _, i := range all {
		if i.Workspace != nil {
			linked[*i.Workspace] = true
		}
	}
	var names []string
	entries, _ := os.ReadDir(root)
	for _, e := range entries {
		n := e.Name()
		if !e.IsDir() || strings.HasPrefix(n, ".") || notSpace[n] || linked[n] {
			continue
		}
		subs, _ := os.ReadDir(filepath.Join(root, n))
		for _, s := range subs {
			if _, err := os.Stat(filepath.Join(root, n, s.Name(), ".git")); err == nil {
				names = append(names, n)
				break
			}
		}
	}
	sort.Strings(names)
	return names
}
