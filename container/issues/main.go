// claude-issues: a read-only web view of the org-mode tracker. Data comes from
// the `tracker` CLI ($TRACKER_FILE); the snapshot is rebuilt when the file's
// mtime changes. Serves on 127.0.0.1:$PORT, relative links only (it sits
// behind the proxy at /issues/).
package main

import (
	"embed"
	"encoding/json"
	"fmt"
	"html/template"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed web
var web embed.FS

type Item struct {
	ID        int      `json:"id"`
	State     string   `json:"state"`
	Priority  string   `json:"priority"`
	Title     string   `json:"title"`
	Repo      string   `json:"repo"`
	Parent    *int     `json:"parent"`
	Tags      []string `json:"tags"`
	Owner     *string  `json:"owner"`
	Workspace *string  `json:"workspace"`
	Milestone *string  `json:"milestone"`
	Created   string   `json:"created"`
	Closed    *string  `json:"closed"`
}

func (i Item) Initial() string {
	if i.Owner == nil || *i.Owner == "" {
		return ""
	}
	return strings.ToUpper((*i.Owner)[:1])
}

type Note struct{ Time, Text string }

type Detail struct {
	Item
	Body     string
	Notes    []Note
	Children []Item
	Trees    []Tree
	ScanTime string
	BodyHTML template.HTML `json:"-"`
}

var (
	file  = os.Getenv("TRACKER_FILE")
	mu    sync.Mutex
	items []Item
	mtime time.Time
	tpl   = template.Must(template.ParseFS(web, "web/*.html"))
)

func tracker(args ...string) ([]byte, error) {
	out, err := exec.Command("tracker", args...).Output()
	if err != nil {
		return nil, fmt.Errorf("tracker %s: %w", strings.Join(args, " "), err)
	}
	return out, nil
}

// snapshot returns the items, reloading them when the file changed.
func snapshot() ([]Item, time.Time, error) {
	mu.Lock()
	defer mu.Unlock()
	st, err := os.Stat(file)
	if err != nil {
		return nil, time.Time{}, err
	}
	if !st.ModTime().Equal(mtime) {
		out, err := tracker("list", "state", "all")
		if err != nil {
			return nil, time.Time{}, err
		}
		var l []Item
		if err := json.Unmarshal(out, &l); err != nil {
			return nil, time.Time{}, err
		}
		items, mtime = l, st.ModTime()
	}
	return items, mtime, nil
}

var states = []string{"TODO", "NEXT", "DOING", "WAIT", "DONE"}

type Column struct {
	State string
	Items []Item
}
type Lane struct {
	Name    string
	Columns []Column
}

func orDash(p *string) string {
	if p == nil || *p == "" {
		return "none"
	}
	return *p
}

func laneKey(by string, i Item) string {
	switch by {
	case "repo":
		return i.Repo
	case "owner":
		return orDash(i.Owner)
	case "milestone":
		return orDash(i.Milestone)
	}
	return ""
}

// closedRecently: DONE items closed within the last 7 days.
func closedRecently(i Item) bool {
	if i.Closed == nil {
		return false
	}
	t, err := time.ParseInLocation("[2006-01-02 Mon 15:04]", *i.Closed, time.Local)
	return err == nil && time.Since(t) < 7*24*time.Hour
}

func board(all []Item, by, repo string) []Lane {
	idx := map[string]int{}
	var lanes []Lane
	for _, i := range all {
		if (repo != "" && i.Repo != repo) || (i.State == "DONE" && !closedRecently(i)) {
			continue
		}
		col := -1
		for n, s := range states {
			if s == i.State {
				col = n
			}
		}
		if col < 0 {
			continue // DROP
		}
		k := laneKey(by, i)
		n, ok := idx[k]
		if !ok {
			n = len(lanes)
			idx[k] = n
			l := Lane{Name: k}
			for _, s := range states {
				l.Columns = append(l.Columns, Column{State: s})
			}
			lanes = append(lanes, l)
		}
		lanes[n].Columns[col].Items = append(lanes[n].Columns[col].Items, i)
	}
	sort.SliceStable(lanes, func(a, b int) bool { return lanes[a].Name < lanes[b].Name })
	if len(lanes) == 0 {
		lanes = []Lane{{}}
		for _, s := range states {
			lanes[0].Columns = append(lanes[0].Columns, Column{State: s})
		}
	}
	return lanes
}

func page(w http.ResponseWriter, name string, data map[string]any) {
	_, mt, _ := snapshot()
	data["Nav"] = name
	data["AsOf"] = mt.Format("2006-01-02 15:04:05")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := tpl.ExecuteTemplate(w, name+".html", data); err != nil {
		log.Print(err)
	}
}

func handle(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'self'; script-src 'self'; base-uri 'none'")
	p := strings.Trim(r.URL.Path, "/")
	all, _, err := snapshot()
	if err != nil {
		log.Print(err)
		http.Error(w, "tracker unavailable", http.StatusBadGateway)
		return
	}
	switch p {
	case "":
		by := r.URL.Query().Get("by")
		if by != "repo" && by != "owner" && by != "milestone" {
			by = ""
		}
		repo := r.URL.Query().Get("repo")
		repos := map[string]bool{}
		for _, i := range all {
			repos[i.Repo] = true
		}
		var names []string
		for n := range repos {
			names = append(names, n)
		}
		sort.Strings(names)
		page(w, "board", map[string]any{"Untracked": untracked(all), "Lanes": board(all, by, repo), "By": by, "Repo": repo, "Repos": names, "Bys": []string{"repo", "owner", "milestone"}})
		return
	case "activity":
		ev, last, err := history(file, 30)
		if err != nil {
			log.Print(err)
			http.Error(w, "history unavailable", http.StatusBadGateway)
			return
		}
		page(w, "activity", map[string]any{"Days": groupDays(ev), "Stale": staleDoing(all, last, time.Now())})
		return
	}
	raw := strings.HasSuffix(p, ".json")
	id, err := strconv.Atoi(strings.TrimSuffix(p, ".json"))
	found := false
	for _, i := range all {
		found = found || i.ID == id
	}
	if err != nil || !found {
		http.NotFound(w, r)
		return
	}
	out, err := tracker("show", strconv.Itoa(id))
	if err != nil {
		log.Print(err)
		http.Error(w, "tracker unavailable", http.StatusBadGateway)
		return
	}
	if raw {
		w.Header().Set("Content-Type", "application/json")
		w.Write(out)
		return
	}
	var d Detail
	if err := json.Unmarshal(out, &d); err != nil {
		log.Print(err)
		http.Error(w, "tracker unavailable", http.StatusBadGateway)
		return
	}
	d.BodyHTML = renderOrg(d.Body)
	if d.Workspace != nil {
		all, at := trees()
		d.Trees = all[*d.Workspace]
		if !at.IsZero() {
			d.ScanTime = at.Format("2006-01-02 15:04")
		}
	}
	page(w, "detail", map[string]any{"D": d})
}

func main() {
	if file == "" {
		log.Fatal("TRACKER_FILE is not set")
	}
	port := os.Getenv("PORT")
	if port == "" {
		port = "8426"
	}
	static, _ := fs.Sub(web, "web")
	files := http.FileServerFS(static)
	http.Handle("/style.css", files)
	http.Handle("/board.js", files)
	http.HandleFunc("/", handle)
	log.Fatal(http.ListenAndServe("127.0.0.1:"+port, nil))
}
