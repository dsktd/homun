"""Gallery of the images published with claude-view.

    serve.py [port]

Binds 127.0.0.1 only. GET / is the page, newest first, with the images themselves as thumbnails;
GET /images/<file> serves one. Links are relative, so the page also works behind the proxy at /view/.
Environment: CLAUDE_VIEW_DIR (default ~/claude/.services/view).
"""

import json
import mimetypes
import os
import sys
import time
from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8425
ROOT = os.environ.get("CLAUDE_VIEW_DIR") or os.path.expanduser("~/claude/.services/view")
IMAGES = os.path.join(ROOT, "images")

CSS = """
:root{--bg:#fafafa;--fg:#1c1c1e;--mut:#6b6b70;--card:#fff;--line:#d9d9de}
@media(prefers-color-scheme:dark){:root{--bg:#161618;--fg:#e6e6ea;--mut:#9a9aa2;--card:#1f1f23;--line:#38383e}}
body{margin:0;padding:16px;background:var(--bg);color:var(--fg);font:15px/1.45 system-ui,sans-serif}
h1{font-size:1.3rem}.mut{color:var(--mut)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:12px}
figure{margin:0;background:var(--card);border:1px solid var(--line);border-radius:8px;padding:8px}
img{width:100%;height:200px;object-fit:contain}figcaption{padding-top:6px}
"""


def entries():
    """Newest first; index lines whose file is gone are skipped."""
    try:
        with open(os.path.join(ROOT, "index.jsonl")) as f:
            rows = [json.loads(line) for line in f if line.strip()]
    except OSError:
        return []
    return [r for r in reversed(rows) if os.path.isfile(os.path.join(IMAGES, r["file"]))]


def page():
    figs = "".join(
        f'<figure><a href="images/{quote(e["file"])}"><img src="images/{quote(e["file"])}" loading="lazy" alt=""></a>'
        f'<figcaption>{escape(e["title"] or e["file"])}<br><span class="mut">'
        f'{time.strftime("%Y-%m-%d %H:%M", time.localtime(e["ts"]))}</span></figcaption></figure>'
        for e in entries()
    )
    body = f'<div class="grid">{figs}</div>' if figs else '<p class="mut">No images yet.</p>'
    return (
        '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
        f"<title>Images</title><style>{CSS}</style><h1>Images</h1>{body}"
    )


class Handler(BaseHTTPRequestHandler):
    def reply(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def end_headers(self):
        # Every response, send_error included
        self.send_header("X-Content-Type-Options", "nosniff")
        super().end_headers()

    def do_GET(self):
        route = self.path.split("?")[0]
        if route == "/":
            self.reply(page().encode(), "text/html; charset=utf-8")
        elif route.startswith("/images/"):
            name = unquote(route[len("/images/") :])
            path = os.path.join(IMAGES, name)
            if os.path.basename(name) != name or not os.path.isfile(path):
                self.send_error(404)
                return
            with open(path, "rb") as f:
                self.reply(f.read(), mimetypes.guess_type(name)[0] or "application/octet-stream")
        else:
            self.send_error(404)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
