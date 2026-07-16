#!/usr/bin/env python3

from __future__ import annotations

import http.client
import json
import re
import socket
import threading
import unittest
import urllib.error
import urllib.request

import server as fixture


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


class InspectorFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = fixture.make_server("127.0.0.1", 0)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def read(self, path: str) -> tuple[int, dict[str, str], bytes]:
        with urllib.request.urlopen(self.base_url + path, timeout=2) as response:
            return response.status, dict(response.headers.items()), response.read()

    def read_with_headers(
        self,
        path: str,
        headers: dict[str, str],
    ) -> tuple[int, dict[str, str], bytes]:
        request = urllib.request.Request(self.base_url + path, headers=headers)
        with urllib.request.urlopen(request, timeout=2) as response:
            return response.status, dict(response.headers.items()), response.read()

    def post_json(
        self,
        path: str,
        value: object,
    ) -> tuple[int, dict[str, str], bytes]:
        request = urllib.request.Request(
            self.base_url + path,
            data=json.dumps(value, separators=(",", ":")).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "X-Inspector-Fixture-Request": "test-round-trip",
            },
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=2) as response:
            return response.status, dict(response.headers.items()), response.read()

    def test_page_a_contains_the_integrated_protocol_stressors(self) -> None:
        status, headers, body = self.read("/a?visit=a1")
        text = body.decode("utf-8")

        self.assertEqual(status, 200)
        self.assertEqual(headers["X-Inspector-Fixture"], "self-authored")
        self.assertIn('data-fixture-page="a" data-fixture-visit="a1"', text)
        self.assertEqual(text.count('class="fixture-card"'), fixture.CARD_COUNT)
        self.assertGreater(fixture.CARD_COUNT, 2_048)
        self.assertIn('id="mutation-burst"', text)
        self.assertIn('id="picker-target"', text)
        self.assertIn('<fixture-shadow id="shadow-host">', text)
        self.assertIn('id="fixture-frame" src="/frame/a?visit=a1"', text)
        self.assertIn('id="navigate-b" href="/b?visit=b1&amp;return=a2"', text)
        self.assertIn(
            'id="target-blank" href="/b?visit=b1&amp;return=a2&amp;source=target-blank" target="_blank"',
            text,
        )
        self.assertIn('id="reload-page"', text)
        self.assertIn('id="history-back"', text)
        self.assertIn('id="history-forward"', text)
        self.assertIn('id="failed-navigation" href="/navigation-failure?visit=a1"', text)
        for control in (
            "subframe-navigate",
            "subframe-reload",
            "subframe-fail",
            "subframe-detach",
            "subframe-reinsert",
        ):
            self.assertIn(f'id="{control}"', text)
        self.assertIn('id="dialog-alert"', text)
        self.assertIn('id="dialog-confirm"', text)
        self.assertIn('id="dialog-prompt"', text)
        self.assertIn('id="post-round-trip"', text)
        self.assertIn('id="network-burst"', text)
        self.assertIn('id="network-burst-large"', text)
        self.assertIn('id="network-burst-status"', text)
        self.assertIn('id="load-movie-preview"', text)
        self.assertIn('id="fixture-movie" controls preload="none"', text)

    def test_committed_navigation_and_subframe_payloads_have_distinct_visit_markers(self) -> None:
        _, _, page_a2 = self.read("/a?visit=a2")
        _, _, page_b1 = self.read("/b?visit=b1&return=a2")
        _, _, frame_a = self.read("/frame/a?visit=a1")
        _, _, frame_b = self.read("/frame/b?visit=a1")

        self.assertIn(
            'data-fixture-page="a" data-fixture-visit="a2"',
            page_a2.decode("utf-8"),
        )
        page_b_text = page_b1.decode("utf-8")
        self.assertIn(
            'data-fixture-page="b" data-fixture-visit="b1"',
            page_b_text,
        )
        self.assertIn('id="navigate-a" href="/a?visit=a2"', page_b_text)
        self.assertIn('id="reload-page"', page_b_text)
        self.assertIn('id="history-back"', page_b_text)
        self.assertIn('id="history-forward"', page_b_text)
        self.assertIn(
            'id="failed-navigation" href="/navigation-failure?visit=b1"',
            page_b_text,
        )
        self.assertIn(
            'data-fixture-page="frame-a" data-fixture-visit="a1"',
            frame_a.decode("utf-8"),
        )
        self.assertIn(
            'data-fixture-page="frame-b" data-fixture-visit="a1"',
            frame_b.decode("utf-8"),
        )

    def test_scripts_encode_one_shot_mutation_network_and_history_flows(self) -> None:
        _, _, site_script = self.read("/assets/site.js")
        _, _, page_b_script = self.read("/assets/page-b.js")
        site_text = site_script.decode("utf-8")

        self.assertIn(
            f"const MUTATION_EVENT_COUNT = {fixture.MUTATION_EVENT_COUNT};",
            site_text,
        )
        self.assertIn(
            f"const DEFAULT_NETWORK_REQUEST_COUNT = {fixture.DEFAULT_NETWORK_REQUEST_COUNT};",
            site_text,
        )
        self.assertIn(
            f"const LARGE_NETWORK_REQUEST_COUNT = {fixture.LARGE_NETWORK_REQUEST_COUNT};",
            site_text,
        )
        self.assertIn(
            f"const NETWORK_REQUEST_CONCURRENCY = {fixture.NETWORK_REQUEST_CONCURRENCY};",
            site_text,
        )
        self.assertIn('attachShadow({ mode: "open" })', site_text)
        self.assertIn('fixtureURL("/api/data", {visit: fixtureVisit})', site_text)
        self.assertIn('fixtureURL("/redirect", {visit: fixtureVisit})', site_text)
        self.assertIn('fixtureURL("/failed", {visit: fixtureVisit})', site_text)
        self.assertIn('alert("Inspector fixture alert")', site_text)
        self.assertIn('confirm("Inspector fixture confirm?")', site_text)
        self.assertIn('prompt("Inspector fixture prompt", "fixture default")', site_text)
        self.assertIn('fixtureURL("/api/echo", {visit: fixtureVisit})', site_text)
        self.assertIn('fixtureURL("/api/burst", {', site_text)
        self.assertIn("window.runInspectorNetworkBurst = emitNetworkBurst", site_text)
        self.assertIn("count = DEFAULT_NETWORK_REQUEST_COUNT", site_text)
        self.assertIn("while (nextRequest < count)", site_text)
        self.assertIn("emitNetworkBurst(LARGE_NETWORK_REQUEST_COUNT", site_text)
        self.assertIn('video.src = "/media/fixture.m3u8"', site_text)
        self.assertIn('location.reload()', site_text)
        self.assertIn('history.back()', site_text)
        self.assertIn('history.forward()', site_text)
        self.assertIn('fixtureURL("/frame/b", {visit: fixtureVisit})', site_text)
        self.assertIn('frame.contentWindow.location.reload()', site_text)
        self.assertIn('fixtureURL("/frame/failure", {visit: fixtureVisit})', site_text)
        self.assertIn('fixtureFrame.remove()', site_text)
        self.assertIn('frameHost.append(fixtureFrame)', site_text)
        page_b_text = page_b_script.decode("utf-8")
        for script in (site_text, page_b_text):
            for periodic_api in ("setInterval", "setTimeout", "requestAnimationFrame"):
                self.assertNotIn(periodic_api, script)
        self.assertIn("history.back()", page_b_text)
        self.assertIn("history.forward()", page_b_text)
        self.assertIn("location.reload()", page_b_text)

    def test_picker_target_exposes_used_and_unused_css_variables(self) -> None:
        _, _, stylesheet = self.read("/assets/site.css")
        text = stylesheet.decode("utf-8")

        self.assertIn("--fixture-used-color: #13276c;", text)
        self.assertIn("--fixture-unused-color: #d52b72;", text)
        self.assertIn("--fixture-unused-spacing: 17px;", text)
        self.assertIn("color: var(--fixture-used-color);", text)
        self.assertNotIn("var(--fixture-unused-color)", text)
        self.assertNotIn("var(--fixture-unused-spacing)", text)

    def test_json_post_preserves_distinct_request_and_response_bodies(self) -> None:
        request_value = {
            "fixture": "request-body",
            "sequence": 1,
            "items": ["alpha", "beta"],
        }

        status, headers, body = self.post_json("/api/echo", request_value)

        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "application/json")
        self.assertEqual(headers["X-Inspector-Fixture"], "self-authored")
        self.assertEqual(
            json.loads(body),
            {
                "fixture": "response-body",
                "received": request_value,
            },
        )

    def test_network_burst_route_preserves_each_request_identity(self) -> None:
        request = fixture.LARGE_NETWORK_REQUEST_COUNT + 137

        status, headers, body = self.read(
            f"/api/burst?visit=a1&run=burst-10000&request={request}"
        )

        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "application/json")
        self.assertEqual(headers["X-Inspector-Fixture"], "self-authored")
        self.assertEqual(headers["X-Inspector-Fixture-Request"], str(request))
        self.assertEqual(headers["X-Inspector-Fixture-Run"], "burst-10000")
        self.assertEqual(headers["X-Inspector-Fixture-Visit"], "a1")
        self.assertEqual(
            json.loads(body),
            {
                "fixture": "network-burst",
                "request": request,
                "run": "burst-10000",
                "visit": "a1",
            },
        )

    def test_network_burst_rejects_missing_or_invalid_identity(self) -> None:
        for path in (
            "/api/burst",
            "/api/burst?visit=a1&run=missing-request",
            "/api/burst?visit=a1&run=negative&request=-1",
            "/api/burst?visit=a1&run=bad%20marker&request=1",
            "/api/burst?visit=a1&run=extra&request=1&unknown=value",
        ):
            with self.subTest(path=path):
                with self.assertRaises(urllib.error.HTTPError) as request_error:
                    self.read(path)

                self.assertEqual(request_error.exception.code, 400)

    def test_local_hls_is_a_finite_self_contained_movie(self) -> None:
        playlist_status, playlist_headers, playlist_body = self.read(
            "/media/fixture.m3u8"
        )
        segment_status, segment_headers, segment_body = self.read("/media/fixture.ts")
        playlist = playlist_body.decode("utf-8")

        self.assertEqual(playlist_status, 200)
        self.assertEqual(
            playlist_headers["Content-Type"],
            "application/vnd.apple.mpegurl",
        )
        self.assertEqual(playlist_body, fixture.HLS_PLAYLIST)
        self.assertIn("#EXT-X-PLAYLIST-TYPE:VOD", playlist)
        self.assertIn("#EXT-X-ENDLIST", playlist)
        self.assertIn("/media/fixture.ts", playlist)
        self.assertIsNone(re.search(r"(?:https?:)?//", playlist))
        self.assertEqual(segment_status, 200)
        self.assertEqual(segment_headers["Content-Type"], "video/mp2t")
        self.assertEqual(segment_headers["Accept-Ranges"], "bytes")
        self.assertEqual(segment_body, fixture.MEDIA_SEGMENT)
        self.assertGreater(len(segment_body), 1_000)
        self.assertEqual(segment_body[0], 0x47)
        self.assertEqual(len(segment_body) % 188, 0)

    def test_media_segment_supports_single_byte_ranges(self) -> None:
        segment_length = len(fixture.MEDIA_SEGMENT)
        cases = (
            ("bytes=188-375", 188, 375),
            ("bytes=376-", 376, segment_length - 1),
            ("bytes=-188", segment_length - 188, segment_length - 1),
        )

        for range_value, start, end in cases:
            with self.subTest(range=range_value):
                status, headers, body = self.read_with_headers(
                    "/media/fixture.ts",
                    {"Range": range_value},
                )

                self.assertEqual(status, 206)
                self.assertEqual(headers["Content-Type"], "video/mp2t")
                self.assertEqual(headers["Accept-Ranges"], "bytes")
                self.assertEqual(
                    headers["Content-Range"],
                    f"bytes {start}-{end}/{segment_length}",
                )
                self.assertEqual(body, fixture.MEDIA_SEGMENT[start : end + 1])

    def test_media_segment_rejects_multiple_or_unsatisfiable_ranges(self) -> None:
        segment_length = len(fixture.MEDIA_SEGMENT)
        for range_value in ("bytes=0-1,4-5", f"bytes={segment_length}-"):
            with self.subTest(range=range_value):
                request = urllib.request.Request(
                    self.base_url + "/media/fixture.ts",
                    headers={"Range": range_value},
                )
                with self.assertRaises(urllib.error.HTTPError) as range_error:
                    urllib.request.urlopen(request, timeout=2)

                self.assertEqual(range_error.exception.code, 416)
                self.assertEqual(
                    range_error.exception.headers["Content-Range"],
                    f"bytes */{segment_length}",
                )
                self.assertEqual(
                    range_error.exception.headers["Accept-Ranges"],
                    "bytes",
                )

    def test_all_page_and_asset_references_are_local(self) -> None:
        bodies = [
            self.read("/a?visit=a1")[2],
            self.read("/a?visit=a2")[2],
            self.read("/b?visit=b1&return=a2")[2],
            self.read("/frame/a?visit=a1")[2],
            self.read("/frame/b?visit=a1")[2],
            self.read("/assets/site.css")[2],
            self.read("/assets/site.js")[2],
            self.read("/assets/page-b.js")[2],
            self.read("/assets/image.svg")[2],
            self.read("/media/fixture.m3u8")[2],
        ]
        combined = b"\n".join(bodies).decode("utf-8")
        self.assertIsNone(re.search(r"(?:https?:)?//(?!www\.w3\.org/2000/svg)", combined))

    def test_redirect_json_image_and_missing_routes_have_stable_wire_shapes(self) -> None:
        opener = urllib.request.build_opener(NoRedirect)
        with self.assertRaises(urllib.error.HTTPError) as redirect_error:
            opener.open(self.base_url + "/redirect?visit=a1", timeout=2)
        self.assertEqual(redirect_error.exception.code, 302)
        self.assertEqual(
            redirect_error.exception.headers["Location"],
            "/api/data?visit=a1",
        )
        with self.assertRaises(urllib.error.HTTPError) as image_redirect_error:
            opener.open(self.base_url + "/redirect-image?visit=a2", timeout=2)
        self.assertEqual(image_redirect_error.exception.code, 302)
        self.assertEqual(
            image_redirect_error.exception.headers["Location"],
            "/assets/image.svg?redirected=1&visit=a2",
        )

        json_status, json_headers, json_body = self.read("/api/data")
        image_status, image_headers, image_body = self.read("/assets/image.svg")
        with self.assertRaises(urllib.error.HTTPError) as missing_error:
            self.read("/missing")

        self.assertEqual(json_status, 200)
        self.assertEqual(json_headers["Content-Type"], "application/json")
        self.assertEqual(json_body, fixture.JSON_DATA)
        self.assertEqual(image_status, 200)
        self.assertEqual(image_headers["Content-Type"], "image/svg+xml")
        self.assertTrue(image_body.startswith(b"<svg"))
        self.assertEqual(missing_error.exception.code, 404)

    def test_failed_fetch_and_navigation_routes_terminate_without_an_http_response(self) -> None:
        for path in (
            "/failed?visit=a1",
            "/navigation-failure?visit=a1",
            "/frame/failure?visit=a1",
        ):
            with self.subTest(path=path):
                connection = http.client.HTTPConnection(
                    "127.0.0.1",
                    self.server.server_port,
                    timeout=2,
                )
                connection.request("GET", path)
                with self.assertRaises(http.client.RemoteDisconnected):
                    connection.getresponse()
                connection.close()

    def test_malformed_request_line_returns_http_error_before_path_exists(self) -> None:
        with socket.create_connection(
            ("127.0.0.1", self.server.server_port),
            timeout=2,
        ) as connection:
            connection.sendall(b"GET /" + (b"x" * 65_537) + b" HTTP/1.1\r\n\r\n")
            response = connection.recv(1_024)

        self.assertTrue(response.startswith(b"HTTP/1.1 414"), response[:80])


if __name__ == "__main__":
    unittest.main()
