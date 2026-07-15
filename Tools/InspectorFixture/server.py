#!/usr/bin/env python3
"""Loopback-only, self-authored WebKit inspector integration fixture."""

from __future__ import annotations

import argparse
import json
import socket
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Final
from urllib.parse import urlsplit


CARD_COUNT: Final = 2_305
MUTATION_EVENT_COUNT: Final = 2_305


def _cards(count: int = CARD_COUNT) -> str:
    return "\n".join(
        f"""
        <article class="fixture-card" data-fixture-index="{index}">
          <img src="/assets/image.svg?card={index % 8}" alt="Fixture product {index}" loading="lazy" width="76" height="76">
          <div class="fixture-card-copy">
            <h2>Fixture product {index:04d}</h2>
            <p>Deterministic local row for DOM tree and viewport work.</p>
            <span class="fixture-price">¥{(index + 1) * 37:,}</span>
          </div>
        </article>
        """.strip()
        for index in range(count)
    )


def page_a() -> bytes:
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Inspector Fixture A</title>
  <link rel="stylesheet" href="/assets/site.css">
  <script src="/assets/site.js" defer></script>
</head>
<body data-fixture-page="a">
  <header class="fixture-toolbar">
    <div>
      <strong>Inspector Fixture A</strong>
      <span id="network-status" aria-live="polite">Network pending</span>
    </div>
    <nav aria-label="Fixture navigation">
      <a id="navigate-b" href="/b">Navigate to page B</a>
      <button id="mutation-burst" type="button">Emit {MUTATION_EVENT_COUNT} DOM mutations</button>
      <button id="replace-feed" type="button">Replace dynamic feed</button>
    </nav>
  </header>
  <main>
    <section class="fixture-diagnostics" aria-labelledby="diagnostic-heading">
      <h1 id="diagnostic-heading">Real WebKit integration targets</h1>
      <button id="picker-target" class="picker-target" type="button">
        Pick me and inspect computed styles
      </button>
      <fixture-shadow id="shadow-host"></fixture-shadow>
      <iframe id="fixture-frame" src="/frame" title="Same-origin fixture frame"></iframe>
      <img id="redirect-image" src="/redirect-image" alt="Redirected fixture image" width="160" height="90">
      <output id="burst-status">Mutation burst idle</output>
      <ol id="dynamic-feed"><li>Initial dynamic row</li></ol>
    </section>
    <section id="product-grid" class="fixture-grid" aria-label="Large deterministic DOM">
      {_cards()}
    </section>
  </main>
</body>
</html>
""".encode("utf-8")


def page_b() -> bytes:
    return """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Inspector Fixture B</title>
  <link rel="stylesheet" href="/assets/site.css">
  <script src="/assets/page-b.js" defer></script>
</head>
<body data-fixture-page="b" class="fixture-secondary-page">
  <main class="fixture-secondary">
    <p class="fixture-eyebrow">Committed navigation target</p>
    <h1>Inspector Fixture B</h1>
    <p id="detail-status">Detail JSON pending</p>
    <nav aria-label="Fixture return navigation">
      <button id="history-back" type="button">History back</button>
      <a id="navigate-a" href="/a">Navigate directly to page A</a>
    </nav>
    <section id="page-b-tree">
      <article><h2>Different document identity</h2><p>Page B keeps navigation resets observable.</p></article>
      <article><h2>Network history</h2><p>The prior page requests should remain inspectable.</p></article>
    </section>
  </main>
</body>
</html>
""".encode("utf-8")


def frame_page() -> bytes:
    rows = "".join(
        f'<li data-frame-row="{index}">Frame row {index}</li>' for index in range(64)
    )
    return f"""<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Fixture frame</title></head>
<body data-fixture-page="frame">
  <section id="frame-root">
    <h1>Same-origin frame document</h1>
    <ul>{rows}</ul>
  </section>
</body>
</html>
""".encode("utf-8")


SITE_CSS: Final = b"""
:root { color-scheme: light dark; font: 15px system-ui, sans-serif; }
* { box-sizing: border-box; }
body { margin: 0; background: Canvas; color: CanvasText; }
button, a { font: inherit; }
.fixture-toolbar {
  position: sticky; top: 0; z-index: 10; display: flex; gap: 12px;
  justify-content: space-between; align-items: center; padding: 12px 16px;
  border-bottom: 1px solid color-mix(in srgb, CanvasText 18%, transparent);
  background: color-mix(in srgb, Canvas 92%, transparent); backdrop-filter: blur(16px);
}
.fixture-toolbar nav, .fixture-secondary nav { display: flex; gap: 8px; flex-wrap: wrap; }
.fixture-toolbar button, .fixture-toolbar a, .fixture-secondary button, .fixture-secondary a {
  border: 1px solid #5066d8; border-radius: 999px; padding: 7px 12px;
  color: #3449b7; background: Canvas; text-decoration: none;
}
#network-status { margin-left: 8px; opacity: .65; }
.fixture-diagnostics { display: grid; gap: 12px; padding: 20px; }
.picker-target {
  position: relative; width: min(420px, 100%); padding: 22px 30px;
  border: 4px solid #2d57d8; border-radius: 18px; background: #dfe7ff;
  color: #13276c; font-weight: 700; box-shadow: 0 8px 30px #2d57d833;
}
.picker-target::before { content: "::before"; color: #ca3767; margin-right: 8px; }
.picker-target::after { content: "::after"; color: #137b58; margin-left: 8px; }
fixture-shadow { display: block; padding: 12px; border: 2px dashed #7d53c5; }
#fixture-frame { width: min(560px, 100%); height: 150px; border: 2px solid #b4781d; }
#redirect-image { width: 160px; height: 90px; object-fit: cover; }
.fixture-grid {
  display: grid; grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
  gap: 10px; padding: 20px;
}
.fixture-card { display: flex; min-height: 112px; gap: 12px; padding: 12px; border: 1px solid #8885; border-radius: 14px; }
.fixture-card img { width: 76px; height: 76px; border-radius: 10px; background: #e8edff; }
.fixture-card h2 { margin: 0; font-size: 15px; }
.fixture-card p { margin: 6px 0; font-size: 12px; opacity: .72; }
.fixture-price { color: #b9471c; font-variant-numeric: tabular-nums; }
.fixture-secondary { max-width: 760px; margin: 80px auto; padding: 32px; }
.fixture-eyebrow { color: #5066d8; text-transform: uppercase; letter-spacing: .12em; }
"""


SITE_JS: Final = f"""
const MUTATION_EVENT_COUNT = {MUTATION_EVENT_COUNT};

customElements.define("fixture-shadow", class extends HTMLElement {{
  connectedCallback() {{
    if (this.shadowRoot) return;
    const root = this.attachShadow({{ mode: "open" }});
    root.innerHTML = `
      <style>
        button {{ padding: 10px 14px; border: 2px solid #7d53c5; border-radius: 8px; }}
        button::before {{ content: "shadow "; color: #7d53c5; }}
      </style>
      <button id="shadow-picker-target" type="button">Open shadow root target</button>`;
  }}
}});

function setNetworkStatus(message) {{
  document.querySelector("#network-status").textContent = message;
}}

async function exerciseNetwork() {{
  const operations = [
    fetch("/api/data").then(response => response.json()),
    fetch("/redirect").then(response => response.json()),
    fetch("/failed").then(() => {{ throw new Error("failure endpoint unexpectedly replied"); }}),
  ];
  const results = await Promise.allSettled(operations);
  const fulfilled = results.filter(result => result.status === "fulfilled").length;
  const rejected = results.filter(result => result.status === "rejected").length;
  setNetworkStatus(`Network complete: ${{fulfilled}} success / ${{rejected}} failed`);
}}

function emitMutationBurst() {{
  const cards = document.querySelectorAll(".fixture-card");
  if (cards.length !== MUTATION_EVENT_COUNT) {{
    throw new Error(`Expected ${{MUTATION_EVENT_COUNT}} cards, found ${{cards.length}}`);
  }}
  cards.forEach((card, index) => card.setAttribute("data-fixture-revision", String(index + 1)));
  document.querySelector("#burst-status").textContent = `${{cards.length}} DOM mutations emitted`;
}}

function replaceDynamicFeed() {{
  const feed = document.querySelector("#dynamic-feed");
  const fragment = document.createDocumentFragment();
  for (let index = 0; index < 96; index += 1) {{
    const item = document.createElement("li");
    item.dataset.dynamicRow = String(index);
    item.textContent = `Dynamic row ${{index}}`;
    fragment.append(item);
  }}
  feed.replaceChildren(fragment);
}}

window.runInspectorMutationBurst = emitMutationBurst;
document.querySelector("#mutation-burst").addEventListener("click", emitMutationBurst);
document.querySelector("#replace-feed").addEventListener("click", replaceDynamicFeed);
exerciseNetwork();
""".encode("utf-8")


PAGE_B_JS: Final = b"""
document.querySelector("#history-back").addEventListener("click", () => history.back());
fetch("/api/detail")
  .then(response => response.json())
  .then(value => { document.querySelector("#detail-status").textContent = value.message; });
"""


IMAGE_SVG: Final = b"""<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180" viewBox="0 0 320 180">
<defs><linearGradient id="g"><stop stop-color="#dfe7ff"/><stop offset="1" stop-color="#9879dd"/></linearGradient></defs>
<rect width="320" height="180" rx="24" fill="url(#g)"/>
<path d="M48 132 112 68l42 42 34-34 84 56" fill="none" stroke="#263b99" stroke-width="12" stroke-linecap="round"/>
<circle cx="236" cy="48" r="20" fill="#eeae36"/>
</svg>"""


JSON_DATA: Final = json.dumps(
    {
        "fixture": "inspector-integration",
        "items": [
            {"id": "alpha", "available": True},
            {"id": "beta", "available": False},
        ],
    },
    separators=(",", ":"),
    sort_keys=True,
).encode("utf-8")


class InspectorFixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        path = urlsplit(self.path).path
        if path in ("/", "/a"):
            self._send(HTTPStatus.OK, "text/html; charset=utf-8", page_a())
        elif path == "/b":
            self._send(HTTPStatus.OK, "text/html; charset=utf-8", page_b())
        elif path == "/frame":
            self._send(HTTPStatus.OK, "text/html; charset=utf-8", frame_page())
        elif path == "/assets/site.css":
            self._send(HTTPStatus.OK, "text/css; charset=utf-8", SITE_CSS)
        elif path == "/assets/site.js":
            self._send(HTTPStatus.OK, "text/javascript; charset=utf-8", SITE_JS)
        elif path == "/assets/page-b.js":
            self._send(HTTPStatus.OK, "text/javascript; charset=utf-8", PAGE_B_JS)
        elif path == "/assets/image.svg":
            self._send(HTTPStatus.OK, "image/svg+xml", IMAGE_SVG)
        elif path == "/api/data":
            self._send(HTTPStatus.OK, "application/json", JSON_DATA)
        elif path == "/api/detail":
            self._send(
                HTTPStatus.OK,
                "application/json",
                b'{"message":"Page B detail JSON loaded"}',
            )
        elif path == "/redirect":
            self._redirect("/api/data")
        elif path == "/redirect-image":
            self._redirect("/assets/image.svg?redirected=1")
        elif path == "/failed":
            self._close_without_response()
        elif path == "/healthz":
            self._send(HTTPStatus.OK, "text/plain; charset=utf-8", b"ok\n")
        else:
            self._send(HTTPStatus.NOT_FOUND, "text/plain; charset=utf-8", b"not found\n")

    def _send(self, status: HTTPStatus, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Inspector-Fixture", "self-authored")
        self.end_headers()
        self.wfile.write(body)

    def _redirect(self, location: str) -> None:
        self.send_response(HTTPStatus.FOUND)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Inspector-Fixture", "self-authored")
        self.end_headers()

    def _close_without_response(self) -> None:
        self.close_connection = True
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.connection.close()

    def log_message(self, format: str, *args: object) -> None:
        print(f"[InspectorFixture] {self.address_string()} {format % args}")


def make_server(host: str, port: int) -> ThreadingHTTPServer:
    return ThreadingHTTPServer((host, port), InspectorFixtureHandler)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    arguments = parser.parse_args()

    server = make_server(arguments.host, arguments.port)
    print(f"Inspector fixture: http://{arguments.host}:{server.server_port}/a")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
