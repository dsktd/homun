package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Live reload (opt-in on the phone): the gateway tells the stream when a cockpit .el file of
// the Homun source tree changes (name and sha256 only) and serves that one file at GET /reload.
// GET /reload with no file is the manifest (every name and sha256, and a version).
// The phone decides whether to fetch it; nothing else leaves the tree, never an arbitrary form.

var reloadName = regexp.MustCompile(`\A(widgetry/)?[a-z0-9-]+\.el\z`)

// reloadable is a name the phone runs: the files GET /client sends, never the host daemon's
// start-up (clientSkip), which would reconfigure the phone's Emacs as the desktop's.
func reloadable(name string) bool {
	base := filepath.Base(name)
	return reloadName.MatchString(name) && !clientSkip[base] &&
		(!strings.HasPrefix(name, "widgetry/") || strings.HasPrefix(base, "widgetry"))
}

type Reloader struct {
	dir  string
	last map[string]string // name -> sha256 at the previous scan; nil before the first
}

func (r *Reloader) names() []string {
	var out []string
	for _, pat := range []string{"*.el", "widgetry/*.el"} {
		hits, _ := filepath.Glob(filepath.Join(r.dir, pat))
		for _, h := range hits {
			rel, _ := filepath.Rel(r.dir, h)
			if reloadable(rel) {
				out = append(out, rel)
			}
		}
	}
	return out
}

func (r *Reloader) read(name string) ([]byte, string, bool) {
	if !reloadable(name) {
		return nil, "", false
	}
	body, err := os.ReadFile(filepath.Join(r.dir, name))
	if err != nil {
		return nil, "", false
	}
	sum := sha256.Sum256(body)
	return body, hex.EncodeToString(sum[:]), true
}

// Manifest is every cockpit file's sha256 and a short version (the hash of them all), so a phone
// that turns live reload on catches up with the changes it missed while it was off.
func (r *Reloader) Manifest() map[string]any {
	files := map[string]string{}
	all := sha256.New()
	for _, n := range r.names() { // sorted by the globs
		if _, sum, ok := r.read(n); ok {
			files[n] = sum
			all.Write([]byte(sum + " " + n + "\n"))
		}
	}
	return map[string]any{"version": hex.EncodeToString(all.Sum(nil))[:8], "files": files}
}

// Scan journals a `reload` record for every file whose hash changed since the last scan; the
// first scan only takes the baseline.
func (r *Reloader) Scan(j *Journal) {
	now := map[string]string{}
	for _, n := range r.names() {
		if _, sum, ok := r.read(n); ok {
			now[n] = sum
			if r.last != nil && r.last[n] != sum {
				data, _ := json.Marshal(map[string]string{"file": n, "sha256": sum})
				j.add("reload", n, data)
			}
		}
	}
	r.last = now
}

func (s *Server) reload(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.auth(w, r); !ok {
		return
	}
	if r.URL.Query().Get("file") == "" {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(s.reloader.Manifest())
		return
	}
	body, sum, ok := s.reloader.read(r.URL.Query().Get("file"))
	if !ok {
		http.Error(w, "not a cockpit Elisp file", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"file": r.URL.Query().Get("file"), "sha256": sum, "content": string(body)})
}
