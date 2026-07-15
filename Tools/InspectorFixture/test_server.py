#!/usr/bin/env python3

from __future__ import annotations

import http.client
import re
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

    def test_page_a_contains_the_integrated_protocol_stressors(self) -> None:
        status, headers, body = self.read("/a")
        text = body.decode("utf-8")

        self.assertEqual(status, 200)
        self.assertEqual(headers["X-Inspector-Fixture"], "self-authored")
        self.assertEqual(text.count('class="fixture-card"'), fixture.CARD_COUNT)
        self.assertGreater(fixture.CARD_COUNT, 2_048)
        self.assertIn('id="mutation-burst"', text)
        self.assertIn('id="picker-target"', text)
        self.assertIn('<fixture-shadow id="shadow-host">', text)
        self.assertIn('id="fixture-frame" src="/frame"', text)
        self.assertIn('id="navigate-b" href="/b"', text)

    def test_scripts_encode_one_shot_mutation_network_and_history_flows(self) -> None:
        _, _, site_script = self.read("/assets/site.js")
        _, _, page_b_script = self.read("/assets/page-b.js")
        site_text = site_script.decode("utf-8")

        self.assertIn(
            f"const MUTATION_EVENT_COUNT = {fixture.MUTATION_EVENT_COUNT};",
            site_text,
        )
        self.assertIn('attachShadow({ mode: "open" })', site_text)
        self.assertIn('fetch("/api/data")', site_text)
        self.assertIn('fetch("/redirect")', site_text)
        self.assertIn('fetch("/failed")', site_text)
        self.assertNotIn("setInterval", site_text)
        self.assertIn("history.back()", page_b_script.decode("utf-8"))

    def test_all_page_and_asset_references_are_local(self) -> None:
        bodies = [
            self.read("/a")[2],
            self.read("/b")[2],
            self.read("/frame")[2],
            self.read("/assets/site.css")[2],
            self.read("/assets/site.js")[2],
            self.read("/assets/page-b.js")[2],
            self.read("/assets/image.svg")[2],
        ]
        combined = b"\n".join(bodies).decode("utf-8")
        self.assertIsNone(re.search(r"(?:https?:)?//(?!www\.w3\.org/2000/svg)", combined))

    def test_redirect_json_image_and_missing_routes_have_stable_wire_shapes(self) -> None:
        opener = urllib.request.build_opener(NoRedirect)
        with self.assertRaises(urllib.error.HTTPError) as redirect_error:
            opener.open(self.base_url + "/redirect", timeout=2)
        self.assertEqual(redirect_error.exception.code, 302)
        self.assertEqual(redirect_error.exception.headers["Location"], "/api/data")

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

    def test_failed_route_terminates_without_an_http_response(self) -> None:
        connection = http.client.HTTPConnection(
            "127.0.0.1",
            self.server.server_port,
            timeout=2,
        )
        connection.request("GET", "/failed")
        with self.assertRaises(http.client.RemoteDisconnected):
            connection.getresponse()
        connection.close()


if __name__ == "__main__":
    unittest.main()
