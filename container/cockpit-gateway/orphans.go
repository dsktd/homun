package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// CloseOrphans emits a closed record for the approval queue scene when none of its requests is
// pending any more, once per version of the scene file. The desktop's own close reaches the
// phone only while its Emacs draws; requests answered in the terminal or expired meanwhile
// would otherwise leave the cards open.
func (j *Journal) CloseOrphans(stage, approve string, now time.Time) {
	scene := filepath.Join(stage, "approve.json")
	info, err := os.Stat(scene)
	if err != nil {
		return
	}
	key := fmt.Sprintf("orphan\x00%d", info.ModTime().UnixNano())
	if j.seen[key] || anyPending(filepath.Join(approve, "requests"), now) {
		return
	}
	j.seen[key] = true
	id, _ := json.Marshal(map[string]any{"id": "approve", "version": info.ModTime().UnixNano()})
	j.add("closed", "approve.json", id)
}

func anyPending(dir string, now time.Time) bool {
	files, _ := filepath.Glob(filepath.Join(dir, "*.json"))
	for _, f := range files {
		if requestPending(f, now) {
			return true
		}
	}
	return false
}

func requestPending(file string, now time.Time) bool {
	body, err := os.ReadFile(file)
	if err != nil {
		return false
	}
	var r struct{ Since, Timeout float64 }
	if json.Unmarshal(body, &r) != nil || r.Since == 0 {
		return true
	}
	if r.Timeout == 0 {
		r.Timeout = 60
	}
	return float64(now.Unix())-r.Since <= r.Timeout
}
