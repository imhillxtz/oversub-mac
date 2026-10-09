"""Máy chủ cục bộ để dựng bộ hình Ove: phục vụ thư mục Tools (mở /Ove/export.html), nhận ảnh PNG và ove.json mà trang
xuất gửi về qua POST /save?name=..., lưu vào Tools/out. Dùng: python3 Tools/Ove/serve.py 8731"""
import http.server
import os
import sys
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "out")


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        name = os.path.basename(urllib.parse.parse_qs(u.query).get("name", ["out.png"])[0])
        if u.path != "/save" or not (name.endswith(".png") or name.endswith(".json")):
            self.send_error(404)
            return
        n = int(self.headers.get("Content-Length", "0"))
        os.makedirs(OUT, exist_ok=True)
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(self.rfile.read(n))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
