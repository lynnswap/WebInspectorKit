#!/usr/bin/env python3
"""Loopback-only, self-authored WebKit inspector integration fixture."""

from __future__ import annotations

import argparse
import json
import re
import socket
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Final
from urllib.parse import parse_qs, urlsplit


CARD_COUNT: Final = 2_305
MUTATION_EVENT_COUNT: Final = 2_305
DEFAULT_NETWORK_REQUEST_COUNT: Final = 2_305
LARGE_NETWORK_REQUEST_COUNT: Final = 10_000
NETWORK_REQUEST_CONCURRENCY: Final = 16
MEDIA_SEGMENT: Final = (Path(__file__).parent / "assets" / "fixture.ts").read_bytes()
HLS_PLAYLIST: Final = b"""#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:1
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-INDEPENDENT-SEGMENTS
#EXTINF:1.000,
/media/fixture.ts
#EXT-X-ENDLIST
"""
SINGLE_BYTE_RANGE: Final = re.compile(r"bytes=(\d*)-(\d*)\Z")
FIXTURE_MARKER: Final = re.compile(r"[A-Za-z0-9._-]{1,64}\Z")


def _fixture_marker(query: str, name: str, default: str) -> str:
    values = parse_qs(query, keep_blank_values=True).get(name, [])
    if len(values) != 1 or FIXTURE_MARKER.fullmatch(values[0]) is None:
        return default
    return values[0]


def _network_burst_identity(
    query: str,
    *,
    requires_request: bool,
) -> tuple[str, str, int | None] | None:
    try:
        query_values = (
            parse_qs(query, keep_blank_values=True, strict_parsing=True)
            if query
            else {}
        )
    except ValueError:
        return None

    expected_names = {"run", "visit"}
    if requires_request:
        expected_names.add("request")
    if set(query_values) != expected_names:
        return None

    run_values = query_values.get("run", [])
    visit_values = query_values.get("visit", [])
    if (
        len(run_values) != 1
        or len(visit_values) != 1
        or FIXTURE_MARKER.fullmatch(run_values[0]) is None
        or FIXTURE_MARKER.fullmatch(visit_values[0]) is None
    ):
        return None

    if requires_request is False:
        return visit_values[0], run_values[0], None

    request_values = query_values.get("request", [])
    if len(request_values) != 1:
        return None
    try:
        request = int(request_values[0])
    except ValueError:
        return None
    if request < 0:
        return None
    return visit_values[0], run_values[0], request


def _parse_single_byte_range(value: str, length: int) -> tuple[int, int] | None:
    match = SINGLE_BYTE_RANGE.fullmatch(value)
    if match is None:
        return None

    first, last = match.groups()
    if first:
        start = int(first)
        if start >= length:
            return None
        end = min(int(last), length - 1) if last else length - 1
        if end < start:
            return None
        return start, end

    if not last:
        return None
    suffix_length = int(last)
    if suffix_length == 0:
        return None
    return max(length - suffix_length, 0), length - 1


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


def page_a(visit: str = "a1") -> bytes:
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Inspector Fixture A</title>
  <link rel="stylesheet" href="/assets/site.css">
  <script src="/assets/site.js" defer></script>
</head>
<body data-fixture-page="a" data-fixture-visit="{visit}">
  <header class="fixture-toolbar">
    <div>
      <strong>Inspector Fixture A ({visit})</strong>
      <span id="network-status" aria-live="polite">Network pending</span>
    </div>
    <nav aria-label="Fixture navigation">
      <a id="navigate-b" href="/b?visit=b1&amp;return=a2">Navigate to page B (b1)</a>
      <a id="target-blank" href="/b?visit=b1&amp;return=a2&amp;source=target-blank" target="_blank" rel="opener">Open page B in target blank</a>
      <button id="reload-page" type="button">Reload {visit}</button>
      <button id="history-back" type="button">History back</button>
      <button id="history-forward" type="button">History forward</button>
      <a id="failed-navigation" href="/navigation-failure?visit={visit}">Start failed top-level navigation</a>
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
      <section class="fixture-feature-controls" aria-label="Interactive inspector targets">
        <div class="fixture-control-group">
          <h2>JavaScript dialogs</h2>
          <button id="dialog-alert" type="button">Show alert</button>
          <button id="dialog-confirm" type="button">Show confirm</button>
          <button id="dialog-prompt" type="button">Show prompt</button>
          <output id="dialog-status" aria-live="polite">Dialogs idle</output>
        </div>
        <div class="fixture-control-group">
          <h2>Request and response bodies</h2>
          <button id="post-round-trip" type="button">Send local JSON POST</button>
          <output id="post-status" aria-live="polite">POST idle</output>
        </div>
        <div class="fixture-control-group">
          <h2>Large Network list</h2>
          <button id="network-burst" type="button">Send {DEFAULT_NETWORK_REQUEST_COUNT} local requests</button>
          <button id="network-burst-large" type="button">Send {LARGE_NETWORK_REQUEST_COUNT} local requests</button>
          <output id="network-burst-status" aria-live="polite">Network burst idle</output>
        </div>
        <div class="fixture-control-group">
          <h2>Local HLS movie</h2>
          <button id="load-movie-preview" type="button">Load local HLS movie</button>
          <output id="movie-status" aria-live="polite">Movie idle</output>
          <video id="fixture-movie" controls preload="none" playsinline width="160" height="90" aria-label="Finite local HLS fixture"></video>
        </div>
      </section>
      <fixture-shadow id="shadow-host"></fixture-shadow>
      <section class="fixture-control-group" aria-label="Subframe lifecycle">
        <h2>Subframe lifecycle</h2>
        <button id="subframe-navigate" type="button">Navigate subframe A → B</button>
        <button id="subframe-reload" type="button">Reload subframe</button>
        <button id="subframe-fail" type="button">Start failed subframe navigation</button>
        <button id="subframe-detach" type="button">Detach subframe</button>
        <button id="subframe-reinsert" type="button">Reinsert subframe</button>
      </section>
      <div id="frame-host">
        <iframe id="fixture-frame" src="/frame/a?visit={visit}" title="Same-origin fixture frame"></iframe>
      </div>
      <img id="redirect-image" src="/redirect-image?visit={visit}" alt="Redirected fixture image" width="160" height="90">
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


def page_b(visit: str = "b1", return_visit: str = "a2") -> bytes:
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Inspector Fixture B</title>
  <link rel="stylesheet" href="/assets/site.css">
  <script src="/assets/page-b.js" defer></script>
</head>
<body data-fixture-page="b" data-fixture-visit="{visit}" class="fixture-secondary-page">
  <main class="fixture-secondary">
    <p class="fixture-eyebrow">Committed navigation target</p>
    <h1>Inspector Fixture B ({visit})</h1>
    <p id="detail-status">Detail JSON pending</p>
    <nav aria-label="Fixture return navigation">
      <button id="history-back" type="button">History back</button>
      <button id="history-forward" type="button">History forward</button>
      <button id="reload-page" type="button">Reload {visit}</button>
      <a id="navigate-a" href="/a?visit={return_visit}">Navigate directly to page A ({return_visit})</a>
      <a id="failed-navigation" href="/navigation-failure?visit={visit}">Start failed top-level navigation</a>
    </nav>
    <section id="page-b-tree">
      <article><h2>Different document identity</h2><p>Page B keeps navigation resets observable.</p></article>
      <article><h2>Network history</h2><p>The prior page requests should remain inspectable.</p></article>
    </section>
  </main>
</body>
</html>
""".encode("utf-8")


def frame_page(page: str = "a", visit: str = "a1") -> bytes:
    rows = "".join(
        f'<li data-frame-row="{index}">Frame row {index}</li>' for index in range(64)
    )
    return f"""<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Fixture frame {page}</title></head>
<body data-fixture-page="frame-{page}" data-fixture-visit="{visit}">
  <section id="frame-root">
    <h1>Same-origin frame document {page} ({visit})</h1>
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
  --fixture-used-color: #13276c;
  --fixture-unused-color: #d52b72;
  --fixture-unused-spacing: 17px;
  position: relative; width: min(420px, 100%); padding: 22px 30px;
  border: 4px solid #2d57d8; border-radius: 18px; background: #dfe7ff;
  color: var(--fixture-used-color); font-weight: 700; box-shadow: 0 8px 30px #2d57d833;
}
.picker-target::before { content: "::before"; color: #ca3767; margin-right: 8px; }
.picker-target::after { content: "::after"; color: #137b58; margin-left: 8px; }
.fixture-feature-controls { display: grid; gap: 12px; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); }
.fixture-control-group { display: flex; align-items: flex-start; gap: 8px; flex-wrap: wrap; padding: 12px; border: 1px solid #8885; border-radius: 12px; }
.fixture-control-group h2 { flex-basis: 100%; margin: 0; font-size: 15px; }
.fixture-control-group output { flex-basis: 100%; font-size: 12px; opacity: .72; }
#fixture-movie { display: block; background: #182047; border-radius: 8px; }
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
const DEFAULT_NETWORK_REQUEST_COUNT = {DEFAULT_NETWORK_REQUEST_COUNT};
const LARGE_NETWORK_REQUEST_COUNT = {LARGE_NETWORK_REQUEST_COUNT};
const NETWORK_REQUEST_CONCURRENCY = {NETWORK_REQUEST_CONCURRENCY};
const fixtureVisit = document.body.dataset.fixtureVisit;

function fixtureURL(path, parameters = {{}}) {{
  const url = new URL(path, location.href);
  for (const [name, value] of Object.entries(parameters)) {{
    url.searchParams.set(name, String(value));
  }}
  return `${{url.pathname}}${{url.search}}`;
}}

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
    fetch(fixtureURL("/api/data", {{visit: fixtureVisit}})).then(response => response.json()),
    fetch(fixtureURL("/redirect", {{visit: fixtureVisit}})).then(response => response.json()),
    fetch(fixtureURL("/failed", {{visit: fixtureVisit}})).then(() => {{ throw new Error("failure endpoint unexpectedly replied"); }}),
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

function runAlertDialog() {{
  alert("Inspector fixture alert");
  document.querySelector("#dialog-status").textContent = "Alert dismissed";
}}

function runConfirmDialog() {{
  const accepted = confirm("Inspector fixture confirm?");
  document.querySelector("#dialog-status").textContent = accepted
    ? "Confirm accepted"
    : "Confirm declined";
}}

function runPromptDialog() {{
  const value = prompt("Inspector fixture prompt", "fixture default");
  document.querySelector("#dialog-status").textContent = value === null
    ? "Prompt cancelled"
    : `Prompt value: ${{value}}`;
}}

async function postRoundTrip() {{
  const status = document.querySelector("#post-status");
  status.textContent = "POST pending";
  const response = await fetch(fixtureURL("/api/echo", {{visit: fixtureVisit}}), {{
    method: "POST",
    headers: {{
      "Content-Type": "application/json",
      "X-Inspector-Fixture-Request": "post-round-trip",
    }},
    body: JSON.stringify({{
      fixture: "request-body",
      sequence: 1,
      items: ["alpha", "beta"],
    }}),
  }});
  if (!response.ok) {{
    throw new Error(`POST failed with HTTP ${{response.status}}`);
  }}
  const value = await response.json();
  status.textContent = `POST complete: ${{value.fixture}} received ${{value.received.fixture}}`;
}}

async function emitNetworkBurst(
  count = DEFAULT_NETWORK_REQUEST_COUNT,
  run = `burst-${{fixtureVisit}}-${{count}}`,
) {{
  if (!Number.isSafeInteger(count) || count <= 0) {{
    throw new TypeError("Network burst count must be a positive safe integer");
  }}
  const button = document.querySelector("#network-burst");
  const largeButton = document.querySelector("#network-burst-large");
  const status = document.querySelector("#network-burst-status");
  button.disabled = true;
  largeButton.disabled = true;
  status.textContent = `Network burst pending: 0 / ${{count}}`;
  let nextRequest = 0;
  let completed = 0;

  async function runWorker() {{
    while (nextRequest < count) {{
      const request = nextRequest;
      nextRequest += 1;
      const response = await fetch(fixtureURL("/api/burst", {{
        visit: fixtureVisit,
        run,
        request,
      }}), {{ cache: "no-store" }});
      if (!response.ok) {{
        throw new Error(`Network burst request ${{request}} failed with HTTP ${{response.status}}`);
      }}
      const value = await response.json();
      if (
        value.fixture !== "network-burst"
        || value.visit !== fixtureVisit
        || value.run !== run
        || value.request !== request
      ) {{
        throw new Error(`Network burst response ${{request}} did not preserve its identity`);
      }}
      completed += 1;
    }}
  }}

  try {{
    await Promise.all(Array.from(
      {{ length: NETWORK_REQUEST_CONCURRENCY }},
      () => runWorker(),
    ));
    status.textContent = `Network burst complete: ${{completed}} / ${{count}}`;
  }} catch (error) {{
    status.textContent = `Network burst failed after ${{completed}} requests: ${{error.message}}`;
    throw error;
  }} finally {{
    button.disabled = false;
    largeButton.disabled = false;
  }}
}}

const fixtureFrame = document.querySelector("#fixture-frame");
const frameHost = document.querySelector("#frame-host");

function requireConnectedFixtureFrame() {{
  if (!fixtureFrame.isConnected) {{
    throw new Error("Fixture frame must be reinserted before navigation");
  }}
  return fixtureFrame;
}}

function navigateSubframe() {{
  requireConnectedFixtureFrame().src = fixtureURL("/frame/b", {{visit: fixtureVisit}});
}}

function reloadSubframe() {{
  const frame = requireConnectedFixtureFrame();
  if (!frame.contentWindow) {{
    throw new Error("Fixture frame has no browsing context");
  }}
  frame.contentWindow.location.reload();
}}

function failSubframeNavigation() {{
  requireConnectedFixtureFrame().src = fixtureURL("/frame/failure", {{visit: fixtureVisit}});
}}

function detachSubframe() {{
  fixtureFrame.remove();
}}

function reinsertSubframe() {{
  if (fixtureFrame.isConnected) return;
  fixtureFrame.src = fixtureURL("/frame/a", {{visit: fixtureVisit, reinserted: 1}});
  frameHost.append(fixtureFrame);
}}

function loadMoviePreview() {{
  const video = document.querySelector("#fixture-movie");
  video.src = "/media/fixture.m3u8";
  video.load();
  document.querySelector("#movie-status").textContent = "Local HLS requested";
}}

window.runInspectorMutationBurst = emitMutationBurst;
window.runInspectorNetworkBurst = emitNetworkBurst;
document.querySelector("#mutation-burst").addEventListener("click", emitMutationBurst);
document.querySelector("#replace-feed").addEventListener("click", replaceDynamicFeed);
document.querySelector("#dialog-alert").addEventListener("click", runAlertDialog);
document.querySelector("#dialog-confirm").addEventListener("click", runConfirmDialog);
document.querySelector("#dialog-prompt").addEventListener("click", runPromptDialog);
document.querySelector("#post-round-trip").addEventListener("click", postRoundTrip);
document.querySelector("#network-burst").addEventListener("click", () => {{
  emitNetworkBurst(DEFAULT_NETWORK_REQUEST_COUNT, `burst-${{fixtureVisit}}-2305`);
}});
document.querySelector("#network-burst-large").addEventListener("click", () => {{
  emitNetworkBurst(LARGE_NETWORK_REQUEST_COUNT, `burst-${{fixtureVisit}}-10000`);
}});
document.querySelector("#load-movie-preview").addEventListener("click", loadMoviePreview);
document.querySelector("#reload-page").addEventListener("click", () => location.reload());
document.querySelector("#history-back").addEventListener("click", () => history.back());
document.querySelector("#history-forward").addEventListener("click", () => history.forward());
document.querySelector("#subframe-navigate").addEventListener("click", navigateSubframe);
document.querySelector("#subframe-reload").addEventListener("click", reloadSubframe);
document.querySelector("#subframe-fail").addEventListener("click", failSubframeNavigation);
document.querySelector("#subframe-detach").addEventListener("click", detachSubframe);
document.querySelector("#subframe-reinsert").addEventListener("click", reinsertSubframe);
document.querySelector("#fixture-movie").addEventListener("loadedmetadata", () => {{
  document.querySelector("#movie-status").textContent = "Local HLS metadata loaded";
}});
exerciseNetwork();
""".encode("utf-8")


PAGE_B_JS: Final = b"""
const fixtureVisit = document.body.dataset.fixtureVisit;
document.querySelector("#history-back").addEventListener("click", () => history.back());
document.querySelector("#history-forward").addEventListener("click", () => history.forward());
document.querySelector("#reload-page").addEventListener("click", () => location.reload());
fetch(`/api/detail?visit=${encodeURIComponent(fixtureVisit)}`)
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


class NetworkBurstLedger:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._request_counts: dict[tuple[str, str], dict[int, int]] = {}

    def record(self, visit: str, run: str, request: int) -> None:
        with self._lock:
            counts = self._request_counts.setdefault((visit, run), {})
            counts[request] = counts.get(request, 0) + 1

    def snapshot(self, visit: str, run: str) -> dict[str, object]:
        with self._lock:
            counts = dict(self._request_counts.get((visit, run), {}))

        contiguous_request_count = 0
        while contiguous_request_count in counts:
            contiguous_request_count += 1
        received_count = sum(counts.values())
        return {
            "contiguousRequestCount": contiguous_request_count,
            "duplicateCount": received_count - len(counts),
            "maximumRequest": max(counts) if counts else None,
            "minimumRequest": min(counts) if counts else None,
            "receivedCount": received_count,
            "run": run,
            "uniqueRequestCount": len(counts),
            "visit": visit,
        }


class InspectorFixtureServer(ThreadingHTTPServer):
    def __init__(self, server_address: tuple[str, int]) -> None:
        super().__init__(server_address, InspectorFixtureHandler)
        self.network_burst_ledger = NetworkBurstLedger()


class InspectorFixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        request_url = urlsplit(self.path)
        path = request_url.path
        if path in ("/", "/a"):
            visit = _fixture_marker(request_url.query, "visit", "a1")
            self._send(HTTPStatus.OK, "text/html; charset=utf-8", page_a(visit))
        elif path == "/b":
            visit = _fixture_marker(request_url.query, "visit", "b1")
            return_visit = _fixture_marker(request_url.query, "return", "a2")
            self._send(
                HTTPStatus.OK,
                "text/html; charset=utf-8",
                page_b(visit, return_visit),
            )
        elif path in ("/frame", "/frame/a", "/frame/b"):
            visit = _fixture_marker(request_url.query, "visit", "a1")
            frame_page_name = "b" if path == "/frame/b" else "a"
            self._send(
                HTTPStatus.OK,
                "text/html; charset=utf-8",
                frame_page(frame_page_name, visit),
            )
        elif path in ("/navigation-failure", "/frame/failure"):
            self._close_without_response()
        elif path == "/assets/site.css":
            self._send(HTTPStatus.OK, "text/css; charset=utf-8", SITE_CSS)
        elif path == "/assets/site.js":
            self._send(HTTPStatus.OK, "text/javascript; charset=utf-8", SITE_JS)
        elif path == "/assets/page-b.js":
            self._send(HTTPStatus.OK, "text/javascript; charset=utf-8", PAGE_B_JS)
        elif path == "/assets/image.svg":
            self._send(HTTPStatus.OK, "image/svg+xml", IMAGE_SVG)
        elif path == "/media/fixture.m3u8":
            self._send(HTTPStatus.OK, "application/vnd.apple.mpegurl", HLS_PLAYLIST)
        elif path == "/media/fixture.ts":
            self._send_media_segment()
        elif path == "/api/data":
            self._send(HTTPStatus.OK, "application/json", JSON_DATA)
        elif path == "/api/detail":
            self._send(
                HTTPStatus.OK,
                "application/json",
                b'{"message":"Page B detail JSON loaded"}',
            )
        elif path == "/api/burst":
            self._send_network_burst(request_url.query)
        elif path == "/metrics/network-burst":
            self._send_network_burst_metrics(request_url.query)
        elif path == "/redirect":
            visit = _fixture_marker(request_url.query, "visit", "a1")
            self._redirect(f"/api/data?visit={visit}")
        elif path == "/redirect-image":
            visit = _fixture_marker(request_url.query, "visit", "a1")
            self._redirect(f"/assets/image.svg?redirected=1&visit={visit}")
        elif path == "/failed":
            self._close_without_response()
        elif path == "/healthz":
            self._send(HTTPStatus.OK, "text/plain; charset=utf-8", b"ok\n")
        else:
            self._send(HTTPStatus.NOT_FOUND, "text/plain; charset=utf-8", b"not found\n")

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        body = self._read_request_body()
        if body is None:
            return

        path = urlsplit(self.path).path
        if path != "/api/echo":
            self._send(HTTPStatus.NOT_FOUND, "text/plain; charset=utf-8", b"not found\n")
            return

        try:
            request_value = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._send(HTTPStatus.BAD_REQUEST, "text/plain; charset=utf-8", b"invalid json\n")
            return

        response = json.dumps(
            {
                "fixture": "response-body",
                "received": request_value,
            },
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        self._send(HTTPStatus.OK, "application/json", response)

    def _read_request_body(self) -> bytes | None:
        content_length = self.headers.get("Content-Length")
        if content_length is None:
            self._send(
                HTTPStatus.LENGTH_REQUIRED,
                "text/plain; charset=utf-8",
                b"content length required\n",
            )
            return None

        try:
            length = int(content_length)
        except ValueError:
            length = -1
        if length < 0:
            self._send(
                HTTPStatus.BAD_REQUEST,
                "text/plain; charset=utf-8",
                b"invalid content length\n",
            )
            return None
        return self.rfile.read(length)

    def _send_media_segment(self) -> None:
        range_value = self.headers.get("Range")
        headers = {"Accept-Ranges": "bytes"}
        if range_value is None:
            self._send(HTTPStatus.OK, "video/mp2t", MEDIA_SEGMENT, headers=headers)
            return

        selected_range = _parse_single_byte_range(range_value, len(MEDIA_SEGMENT))
        if selected_range is None:
            headers["Content-Range"] = f"bytes */{len(MEDIA_SEGMENT)}"
            self._send(
                HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE,
                "video/mp2t",
                b"",
                headers=headers,
            )
            return

        start, end = selected_range
        headers["Content-Range"] = f"bytes {start}-{end}/{len(MEDIA_SEGMENT)}"
        self._send(
            HTTPStatus.PARTIAL_CONTENT,
            "video/mp2t",
            MEDIA_SEGMENT[start : end + 1],
            headers=headers,
        )

    def _send_network_burst(self, query: str) -> None:
        identity = _network_burst_identity(query, requires_request=True)
        if identity is None:
            self._send(
                HTTPStatus.BAD_REQUEST,
                "text/plain; charset=utf-8",
                b"one visit, run, and request identity required\n",
            )
            return
        visit, run, request = identity
        if request is None:
            raise AssertionError("A validated burst request must carry its identity.")
        server = self.server
        if not isinstance(server, InspectorFixtureServer):
            raise AssertionError("InspectorFixtureHandler requires InspectorFixtureServer.")
        server.network_burst_ledger.record(visit, run, request)
        response = json.dumps(
            {
                "fixture": "network-burst",
                "request": request,
                "run": run,
                "visit": visit,
            },
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        self._send(
            HTTPStatus.OK,
            "application/json",
            response,
            headers={
                "X-Inspector-Fixture-Request": str(request),
                "X-Inspector-Fixture-Run": run,
                "X-Inspector-Fixture-Visit": visit,
            },
        )

    def _send_network_burst_metrics(self, query: str) -> None:
        identity = _network_burst_identity(query, requires_request=False)
        if identity is None:
            self._send(
                HTTPStatus.BAD_REQUEST,
                "text/plain; charset=utf-8",
                b"one visit and run identity required\n",
            )
            return
        visit, run, request = identity
        if request is not None:
            raise AssertionError("A burst metrics identity must not carry a request.")
        server = self.server
        if not isinstance(server, InspectorFixtureServer):
            raise AssertionError("InspectorFixtureHandler requires InspectorFixtureServer.")
        response = json.dumps(
            server.network_burst_ledger.snapshot(visit, run),
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        self._send(HTTPStatus.OK, "application/json", response)

    def _send(
        self,
        status: HTTPStatus,
        content_type: str,
        body: bytes,
        *,
        headers: dict[str, str] | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Inspector-Fixture", "self-authored")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
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
        if urlsplit(getattr(self, "path", "")).path == "/api/burst":
            return
        print(f"[InspectorFixture] {self.address_string()} {format % args}")


def make_server(host: str, port: int) -> InspectorFixtureServer:
    return InspectorFixtureServer((host, port))


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
