package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// The remote cockpit's client files (design 3.6b): the cockpit's Elisp as this container ships
// it, widgetry flat beside it, plus the ELPA packages it requires (copied from the Nix store),
// so a phone needs nothing but url.el and the pinned CA to fetch it all.
//
//	GET /client          all the files, each framed by a "<sha256> <name> <length>" line
//
// The phone's bootstrap block (homun-init.el) writes the ones that differ from its cache.

// The cockpit's files a remote cockpit has no use for: the host daemon's start-up and glue
var clientSkip = map[string]bool{"init.el": true, "cockpit.el": true, "homun-elc.el": true, "claude-pair.el": true, "homun-init.el": true}

// ELPA packages the cockpit's Elisp requires (magit-section's own requirements included); markdown-mode gives the transcript its markdown faces
var clientDeps = []string{"magit-section", "markdown-mode", "consult", "timeout", "compat", "cond-let", "llama"}

type Client struct {
	src   string   // the cockpit's Elisp directory
	ca    string   // the proxy's root certificate
	fonts []string // font files the phone installs (HOMUN_FONTS), served by base name
}

// files maps each client file's name to its path.
func (c Client) files() map[string]string {
	out := map[string]string{}
	for _, pat := range []string{"*.el", "widgetry/widgetry*.el"} {
		hits, _ := filepath.Glob(filepath.Join(c.src, pat))
		for _, f := range hits {
			if b := filepath.Base(f); !clientSkip[b] && !strings.HasPrefix(b, ".") {
				out[b] = f
			}
		}
	}
	for _, name := range clientDeps {
		dirs, _ := filepath.Glob("/nix/store/*/share/emacs/site-lisp/elpa/" + name + "-[0-9]*")
		if len(dirs) == 0 {
			continue
		}
		sort.Slice(dirs, func(i, j int) bool { return filepath.Base(dirs[i]) < filepath.Base(dirs[j]) })
		hits, _ := filepath.Glob(filepath.Join(dirs[len(dirs)-1], "*.el"))
		for _, f := range hits {
			if b := filepath.Base(f); !strings.HasSuffix(b, "-autoloads.el") && !strings.HasSuffix(b, "-pkg.el") {
				out[b] = f
			}
		}
	}
	return out
}

// fontFiles maps the base name of each listed font that exists to its path.
func (c Client) fontFiles() map[string]string {
	out := map[string]string{}
	for _, f := range c.fonts {
		if _, err := os.Stat(f); err == nil {
			out[filepath.Base(f)] = f
		}
	}
	return out
}

// ServeFonts answers GET /fonts: the desktop cockpit's font files, framed like /client.
func (c Client) ServeFonts(w http.ResponseWriter, r *http.Request) {
	files := c.fontFiles()
	if len(files) == 0 {
		http.Error(w, "no fonts listed (HOMUN_FONTS)", http.StatusNotFound)
		return
	}
	c.frame(w, files)
}

// Serve answers GET /client: every file as "<sha256> <name> <length>\n<bytes>\n", in name order. One
// request, because a phone pays a whole TLS handshake for each.
func (c Client) Serve(w http.ResponseWriter, r *http.Request) {
	files := c.files()
	if len(files) == 0 {
		http.Error(w, "no Elisp in "+c.src, http.StatusServiceUnavailable)
		return
	}
	c.frame(w, files)
}

func (c Client) frame(w http.ResponseWriter, files map[string]string) {
	names := make([]string, 0, len(files))
	for n := range files {
		names = append(names, n)
	}
	sort.Strings(names)
	var buf bytes.Buffer
	for _, n := range names {
		body, err := os.ReadFile(files[n])
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		sum := sha256.Sum256(body)
		fmt.Fprintf(&buf, "%s %s %d\n%s\n", hex.EncodeToString(sum[:]), n, len(body), body)
	}
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(buf.Bytes())
}

func (c Client) serveCA(w http.ResponseWriter, r *http.Request) {
	body, err := os.ReadFile(c.ca)
	if err != nil {
		http.Error(w, "no root certificate yet: the proxy copies it on its next config", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/x-pem-file")
	w.Write(body)
}
