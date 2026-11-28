package main

import (
	"html/template"
	"log"
	"net/http"
	"strings"
	"time"
)

// The pairing page, GET /p/<id>: what the desktop's QR code opens on the phone. No key is
// asked: it is served only for a live, unused pairing, with the init.el text the desktop left
// for it, so the phone copies the line instead of anyone typing it. A miss costs a second.

var pageTmpl = template.Must(template.New("p").Parse(`<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Pair {{.Name}}</title>
<style>
body{font:18px system-ui,sans-serif;margin:16px;background:#fff;color:#111}
@media (prefers-color-scheme:dark){body{background:#111;color:#eee}textarea{background:#222;color:#eee}}
button{display:block;width:100%;font-size:24px;padding:20px;margin:16px 0;border:0;border-radius:10px;background:#2f6fb0;color:#fff}
textarea{width:100%;height:7em;font:12px monospace}
ol{padding-left:1.2em}li{margin:.4em 0}
</style></head><body>
<h1>Pair {{.Name}}</h1>
<button id="copy">Copy for Emacs</button>
<ol><li>Open Emacs, long-press in <b>*scratch*</b>, Paste.</li>
<li>Menu <b>Lisp-Interaction → Evaluate and Print</b>. It pairs, fetches the cockpit and adds its start to init.el.</li></ol>
<textarea id="line" readonly>{{.Line}}</textarea>
<p>One use, ten minutes.</p>
<script>
document.getElementById('copy').onclick=async function(){
 var t=document.getElementById('line'),b=this;
 try{await navigator.clipboard.writeText(t.value)}catch(e){t.focus();t.select();document.execCommand('copy')}
 b.textContent='Copied';
};
</script></body></html>`))

func (s *Server) page(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/p/")
	line, ok := s.pairs.Line(id)
	if !ok {
		time.Sleep(time.Second)
		http.Error(w, "this pairing code is used or expired: press Pair phone again", http.StatusNotFound)
		return
	}
	pr, _ := s.pairs.read(s.pairs.path(id))
	log.Printf("cockpit-gateway: pairing page for %s", pr.Name)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'")
	pageTmpl.Execute(w, map[string]string{"Name": pr.Name, "Line": line})
}
