package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"sort"
)

// Widget state is shared by every device: the text of the first answer to a transcript widget
// is kept in <dir>/<message uuid>/<widget id>, written by the gateway for a phone's answer and by
// the desktop cockpit for its own. The gateway journals each file once as a `widget` record
// ({"uuid","id","text"}), so a phone sees a click made elsewhere live, and the snapshot carries
// them all for a phone that joins later. A second answer to the same widget is not sent.

const widgetsMax = 300 // newest files journaled at start

var (
	widgetReply = regexp.MustCompile(`^\[(?:clicked|set) ([A-Za-z0-9_.-]{1,64})(?:=[^\]\n]*)? on ([A-Za-z0-9_-]{1,64})\]`)
	errAnswered = errors.New("already answered")
)

// widgetKey is the uuid and id a widget reply names, or empty strings.
func widgetKey(text string) (uuid, id string) {
	if m := widgetReply.FindStringSubmatch(text); m != nil {
		return m[2], m[1]
	}
	return "", ""
}

// widgetClaim writes TEXT as the answer of its widget; errAnswered when one is already kept.
func widgetClaim(dir, text string) error {
	uuid, id := widgetKey(text)
	if dir == "" || uuid == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Join(dir, uuid), 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Join(dir, uuid, id), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if errors.Is(err, os.ErrExist) {
		return errAnswered
	}
	if err != nil {
		return err
	}
	_, err = f.WriteString(text)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// ScanWidgets journals the widget files not yet seen.
func (j *Journal) ScanWidgets(dir string) {
	files, _ := filepath.Glob(filepath.Join(dir, "*", "*"))
	type item struct {
		path string
		mod  int64
	}
	var items []item
	for _, p := range files {
		j.mu.Lock()
		seen := j.seen["widget:"+p]
		j.mu.Unlock()
		if info, err := os.Stat(p); err == nil && !seen && info.Mode().IsRegular() {
			items = append(items, item{p, info.ModTime().UnixNano()})
		}
	}
	sort.Slice(items, func(a, b int) bool { return items[a].mod < items[b].mod })
	if len(items) > widgetsMax {
		items = items[len(items)-widgetsMax:]
	}
	for _, it := range items {
		body, err := os.ReadFile(it.path)
		if err != nil {
			continue
		}
		uuid, id := filepath.Base(filepath.Dir(it.path)), filepath.Base(it.path)
		data, _ := json.Marshal(map[string]string{"uuid": uuid, "id": id, "text": string(body)})
		j.mu.Lock()
		j.seen["widget:"+it.path] = true
		j.mu.Unlock()
		j.put("widget", uuid+"/"+id, data)
	}
}

// Widgets returns every widget record in the ring, for the snapshot.
func (j *Journal) Widgets() []Record {
	j.mu.Lock()
	defer j.mu.Unlock()
	out := []Record{}
	for _, r := range j.ring {
		if r.Kind == "widget" {
			out = append(out, r)
		}
	}
	return out
}
