# Inspector Integration Fixture

This loopback-only site exercises WebInspectorKit through a real `WKWebView` and
the installed WebKit protocol implementation. It complements the deterministic
raw-wire tests; it does not replace them.

Every HTML, CSS, JavaScript, JSON, SVG, and media byte is authored for this
repository. The fixture has no third-party requests and does not copy assets or
markup from the production pages used during manual investigation.

## Run with Monocly

```sh
DEVICE_UDID=<booted-simulator-udid> Scripts/run-monocly-fixture.sh
```

If `DEVICE_UDID` is omitted, the script prefers a booted `SIMULATOR_NAME`
(`iPhone 17` by default), otherwise uses another booted simulator or boots an
available device with that name. It builds and installs Monocly, opens the
inspector in an ephemeral browser session, and keeps the fixture server alive
until interrupted with Control-C. Existing saved browser sessions are neither
read nor overwritten by this diagnostic launch.

The server can also run independently:

```sh
python3 Tools/InspectorFixture/server.py --port 8765
```

Set `FIXTURE_PORT`, `DERIVED_DATA_PATH`, or `SIMULATOR_NAME` to override the
launcher defaults.

## Manual verification matrix

| Contract | Fixture action |
| --- | --- |
| Large DOM and scrolling | Expand `body` / `product-grid`; page A contains 2,305 self-authored card subtrees. |
| Event delivery beyond the former implicit limit | With the inspector attached, tap **Emit 2305 DOM mutations** and confirm the attachment stays ready and the final card attributes appear. |
| Insert/remove projection | Tap **Replace dynamic feed** and inspect the 96 replacement rows. |
| Picker, styles, pseudo-elements, CSS variables | Pick **Pick me and inspect computed styles**; it has border, padding, shadow, `::before` / `::after`, one used custom property, and two unused custom properties for the reveal control. |
| Shadow DOM | Expand `fixture-shadow` and its open shadow root. |
| Frame routing | Expand the same-origin `fixture-frame` document and inspect a frame row. |
| JavaScript dialogs | Tap **Show alert**, **Show confirm**, and **Show prompt**; complete each UIKit dialog and confirm the status output records the result. |
| `target=_blank` routing | Tap **Open page B in target blank** and confirm Monocly loads page B in the current browser view. |
| POST request and response bodies | Tap **Send local JSON POST**, select `/api/echo` in Network, and inspect both **Request** and **Response** preview roles. |
| Network list and previews | Page A issues JSON, redirect, SVG image, and intentionally disconnected requests. Inspect headers, JSON body, image preview, redirect chain, and failure state. |
| Movie/HLS preview | Tap **Load local HLS movie**, select `/media/fixture.m3u8` in Network, and confirm the finite local movie renders in Preview. |
| Navigation generations | Navigate A → B, then use **History back** or Monocly back. DOM changes while Network history remains available. |
| Idle behavior | After the one-shot requests settle, do nothing and sample the main thread. The fixture has no interval, animation loop, or periodic mutation. |

The value `2,305` is only deterministic test input chosen to cross the removed
2,048 buffering threshold. It is not a product limit and is never read by
WebInspectorKit.

## Regression test

```sh
python3 Tools/InspectorFixture/test_server.py
```

The test boots the server on an ephemeral port and verifies the route shapes,
stress markers, dialog and navigation targets, used/unused CSS variables,
distinct POST request/response bodies, finite local HLS media, local-only
assets, redirect, JSON/image responses, and the connection-level failed
request.
