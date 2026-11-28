package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"syscall"
)

// GET /download?name=<file>: serves one regular file of the downloads directory, read-only, to an
// authenticated device. Only a plain basename is accepted and a symlink is never followed, so
// nothing outside the directory can be reached; the size is capped and every download is logged.

const downloadMaxDefault = 200 << 20

func (s *Server) download(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	dev, ok := s.auth(w, r)
	if !ok {
		return
	}
	name := r.URL.Query().Get("name")
	if name == "" || name != filepath.Base(name) || name[0] == '.' || safeName(name) != name {
		http.Error(w, "download: name must be a plain file name", http.StatusBadRequest)
		return
	}
	path := filepath.Join(s.downloads, name)
	fi, err := os.Lstat(path)
	if err != nil || !fi.Mode().IsRegular() {
		log.Printf("download: %s asked for %s: not found", dev.Name, name)
		http.Error(w, "download: no such file", http.StatusNotFound)
		return
	}
	max := s.downloadMax
	if max <= 0 {
		max = downloadMaxDefault
	}
	if fi.Size() > max {
		log.Printf("download: %s asked for %s: %d bytes is over the cap", dev.Name, name, fi.Size())
		http.Error(w, fmt.Sprintf("download: over the %d MB cap", max>>20), http.StatusRequestEntityTooLarge)
		return
	}
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		http.Error(w, "download: "+err.Error(), http.StatusNotFound)
		return
	}
	defer f.Close()
	log.Printf("download: %s fetched %s (%d bytes)", dev.Name, name, fi.Size())
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", name))
	http.ServeContent(w, r, name, fi.ModTime(), f)
}
