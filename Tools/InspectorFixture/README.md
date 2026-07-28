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

The launcher passes the fixture URL through the single process environment key
`MONOCLY_INSPECTOR_FIXTURE_URL`. Its presence selects one atomic diagnostic
configuration: the exact loopback fixture URL, automatic inspector presentation,
and ephemeral session persistence. A normal Monocly launch leaves the key unset
and uses the standard Google start page, persistent session storage, and no
automatic inspector presentation.

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

Set `FIXTURE_PORT`, `DERIVED_DATA_PATH`, `SIMULATOR_NAME`, or
`FIXTURE_INITIAL_PATH` to override the launcher defaults. The initial path
defaults to `/a?visit=a1` and must remain a loopback-relative path.

## Manual verification matrix

| Contract | Fixture action | Verification boundary |
| --- | --- | --- |
| Large DOM and scrolling | Expand `body` / `product-grid`; page A contains 2,305 self-authored card subtrees. | sim-use / manual: scroll and expand while sampling responsiveness. |
| Event delivery beyond the former implicit limit | With the inspector attached, tap **Emit 2305 DOM mutations** and confirm the attachment stays ready and the final card attributes appear. | sim-use / manual. |
| Insert/remove projection | Tap **Replace dynamic feed** and inspect the 96 replacement rows. | sim-use / manual. |
| Picker, styles, pseudo-elements, CSS variables | Pick **Pick me and inspect computed styles**; it has border, padding, shadow, `::before` / `::after`, one used custom property, and two unused custom properties for the reveal control. | sim-use / manual: confirm the DOM row becomes selected and the highlight remains after picker mode exits. |
| Shadow DOM | Expand `fixture-shadow` and its open shadow root. | sim-use / manual. |
| Committed navigation generations | Start at A (`a1`), tap **Navigate to page B (b1)**, then **Navigate directly to page A (a2)**. The `data-fixture-visit` marker distinguishes all three committed documents. | sim-use / manual: DOM must show `a1 → b1 → a2` without an attachment failure. |
| Reload and back-forward | On B tap **Reload b1**, **History back**, and **History forward**. Monocly's own back/forward controls exercise the same history as the fixture buttons. | sim-use / manual: each committed document must replace the DOM generation. |
| Failed top-level provisional navigation | Tap **Start failed top-level navigation**. `/navigation-failure` closes before an HTTP response, so the current committed document must remain selected. | sim-use / manual: attachment, DOM, and the current Network generation remain usable. |
| Subframe lifecycle | Use **Navigate subframe A → B**, **Reload subframe**, **Start failed subframe navigation**, **Detach subframe**, and **Reinsert subframe**. | sim-use / manual: only the child frame changes; no action may reset the top-level generation or Network session. |
| Frame routing | Expand `fixture-frame` and inspect a frame row before and after the subframe actions. | sim-use / manual. |
| JavaScript dialogs | Tap **Show alert**, **Show confirm**, and **Show prompt**; complete each UIKit dialog and confirm the status output records the result. | sim-use / manual. |
| `target=_blank` routing | Tap **Open page B in target blank** and confirm Monocly loads page B in the current browser view. | sim-use / manual. |
| POST request and response bodies | Tap **Send local JSON POST**, select `/api/echo` in Network, and inspect both **Request** and **Response** preview roles. | sim-use / manual. |
| Large Network list throughput | Run **Send 2305 local requests**, then **Send 10000 local requests**. Every URL carries `visit`, `run`, and `request` identities. | sim-use / manual: confirm the final list contains every request in logical request order, stays responsive, and preserves selection. Query `/metrics/network-burst?visit=<visit>&run=<run>` to distinguish fixture delivery from inspector ingestion/rendering. |
| Network list and previews | Page A issues visit-marked JSON, redirect, SVG image, and intentionally disconnected requests. Inspect headers, JSON body, image preview, redirect chain, and failure state. | sim-use / manual. |
| Movie/HLS preview | Tap **Load local HLS movie**, select `/media/fixture.m3u8` in Network, and confirm the finite local movie renders in Preview. Select its `/media/fixture.ts` request and confirm the 206 response has `Content-Range` / `Accept-Ranges` headers and plays from the original URL without fetching a response body into WebInspectorKit. | sim-use / manual. |
| Idle behavior | After the one-shot requests settle, do nothing and sample the main thread. The fixture has no interval, animation loop, or periodic mutation. | Instruments or an equivalent process-level sample; the server regression test only proves that the authored JavaScript contains no periodic API. |

### Network navigation retention

Run the same `a1 → b1 → a2`, reload, and back-forward sequence twice:

1. With **Preserve Log** off (the default), a committed top-level main-resource
   change clears the prior visit's Network rows. After the `b1` commit, `a1`
   request markers must be absent. Reload and back-forward each begin another
   current Network session. Failed provisional and subframe navigation must not
   clear the current top-level rows.
2. With **Preserve Log** on, the same committed navigations retain the prior
   `a1` / `b1` rows and append the new visit's rows. Failed provisional and
   subframe navigation still must not create a top-level session boundary.

These assertions require sim-use or equivalent UI automation because the
fixture cannot read or mutate an inspector preference and cannot inspect the
Network list. The server regression test verifies only the authored stimuli and
their wire identities.

The values `2,305` and `10,000` are deterministic fixture inputs. They are not
product limits and are never read by WebInspectorKit. The burst endpoint accepts
any non-negative request identity; only the authored buttons choose these two
workloads. The loopback server records every received `(visit, run, request)`
identity and exposes total, unique, duplicate, minimum, maximum, and contiguous
counts through `/metrics/network-burst`; the ledger is diagnostic input evidence,
not a product-side request limit or source of Network state.

## Regression test

```sh
python3 Tools/InspectorFixture/test_server.py
```

The test boots the server on an ephemeral port and verifies the visit-marked
committed-navigation payloads, reload/back/forward controls, connection-level
top-level and subframe failures, subframe lifecycle controls, parameterized
large Network request identities without a 2,305/10,000 server cap, dialog and
picker targets, burst-ledger conservation metrics, used/unused CSS variables,
distinct POST request/response
bodies, finite local HLS media with byte-range responses, local-only assets,
redirects, JSON/image responses, and one-shot JavaScript without periodic
timers. It does not claim to verify inspector UI state; the matrix above marks
those sim-use-only assertions explicitly.
