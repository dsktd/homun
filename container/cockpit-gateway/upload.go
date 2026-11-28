package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// POST /upload?name=<file name>: the body is the file, raw. A phone attaches a file to a message
// by uploading it here; the reply names the saved path, which the message then links. The name
// is reduced to a safe basename, the size is capped and the device is authenticated as for /act.

const uploadMaxDefault = 25 << 20

var unsafeName = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

// safeName reduces NAME to a plain basename: no directories (of either slash), no leading dots,
// only [A-Za-z0-9._-], at most 100 bytes; "" when nothing is left.
func safeName(name string) string {
	name = name[strings.LastIndexAny(name, `/\`)+1:]
	name = strings.TrimLeft(unsafeName.ReplaceAllString(name, "_"), ".")
	if len(name) > 100 {
		name = name[len(name)-100:]
	}
	return name
}

func (s *Server) upload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	dev, ok := s.auth(w, r)
	if !ok {
		return
	}
	if dev.ReadOnly {
		http.Error(w, errDenied.Error(), http.StatusForbidden)
		return
	}
	name := safeName(r.URL.Query().Get("name"))
	if name == "" {
		http.Error(w, "upload: name must be a file name", http.StatusBadRequest)
		return
	}
	max := s.uploadMax
	if max <= 0 {
		max = uploadMaxDefault
	}
	if r.ContentLength > max {
		http.Error(w, fmt.Sprintf("upload: over the %d MB cap", max>>20), http.StatusRequestEntityTooLarge)
		return
	}
	path, size, err := s.saveUpload(dev.Name, name, http.MaxBytesReader(w, r.Body, max))
	if err != nil {
		var tooBig *http.MaxBytesError
		code := http.StatusInternalServerError
		if errors.As(err, &tooBig) {
			code = http.StatusRequestEntityTooLarge
		}
		log.Printf("upload: %s %s refused: %v", dev.Name, name, err)
		http.Error(w, "upload: "+err.Error(), code)
		return
	}
	log.Printf("upload: %s saved %s (%d bytes)", dev.Name, path, size)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"ok": true, "path": path, "size": size})
}

// saveUpload writes BODY to <uploads>/<device>/<timestamp>-<name>, mode 600; nothing stays on error.
func (s *Server) saveUpload(device, name string, body io.Reader) (string, int64, error) {
	dir := filepath.Join(s.uploads, safeName(device))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", 0, err
	}
	path := filepath.Join(dir, fmt.Sprintf("%d-%s", time.Now().Unix(), name))
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return "", 0, err
	}
	size, err := io.Copy(f, body)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(path)
		return "", 0, err
	}
	return path, size, nil
}
