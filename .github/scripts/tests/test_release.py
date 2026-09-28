"""Release protocol tests; all GitHub writes are in-memory."""
import copy
import contextlib
import io
import importlib.util
import json
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "release", Path(__file__).resolve().parents[3] / "Scripts" / "release.py"
)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

SHA = "a" * 40
OTHER = "b" * 40


def draft(**changes):
    value = dict(id=42, tag_name="v0.1.0", target_commitish=SHA,
                 name="First release", body="One\n\nTwo\n", prerelease=False,
                 draft=True, html_url="https://github.com/example/project/releases/42")
    value.update(changes)
    return value


class FakeGitHub:
    repository = "example/project"

    def __init__(self, item=None):
        self.release = copy.deepcopy(item)
        self.tag = None
        self.calls = []
        self.dispatch_error = False
        self.publish_error = False
        self.tag_error = False
        self.after_tag = None
        self.before_publish = None
        self.older_page = False

    @property
    def writes(self):
        return [call for call in self.calls if call[1] != "GET"]

    def api(self, path, method="GET", data=None):
        self.calls.append((path, method, copy.deepcopy(data)))
        if path.startswith("commits/"):
            return {"sha": path.split("/")[-1]}
        if path.startswith("git/ref/tags/"):
            if self.tag is None:
                raise release.APIError(404, "Not Found")
            return {"object": dict(type="commit", sha=self.tag)}
        if path.startswith("releases?"):
            if self.older_page and path.endswith("page=1"):
                return [draft(id=i, tag_name=f"old-{i}") for i in range(100)]
            return [copy.deepcopy(self.release)] if self.release else []
        if path == "releases" and method == "POST":
            self.release = dict(data, id=42, html_url="https://github.com/example/project/releases/42")
            return copy.deepcopy(self.release)
        if path == "actions/workflows/release.yml/dispatches":
            if self.dispatch_error:
                raise release.APIError(503, "Dispatch response unavailable")
            return None
        if path == "git/refs" and method == "POST":
            if self.tag_error:
                raise release.APIError(403, "Resource not accessible by integration: workflows permission required")
            self.tag = data["sha"]
            if self.after_tag:
                self.after_tag(self)
            return {"ref": data["ref"]}
        if path == "releases/42":
            if method == "PATCH":
                if self.publish_error:
                    raise release.APIError(503, "Publication failed")
                if self.before_publish:
                    self.before_publish(self)
                self.release.update({key: value for key, value in data.items() if key != "make_latest"})
            return copy.deepcopy(self.release)
        raise AssertionError((path, method, data))


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.output = io.StringIO()
        self.redirect = contextlib.redirect_stdout(self.output)
        self.redirect.__enter__()

    def tearDown(self):
        self.redirect.__exit__(None, None, None)

    def start(self, github, **overrides):
        values = dict(tag="v0.1.0", sha=SHA, title="First release",
                      notes="One\n\nTwo\n", prerelease=False)
        values.update(overrides)
        release.start(github, **values)

    def test_start_keeps_notes_and_pins_dispatch_without_creating_tag(self):
        github = FakeGitHub()
        self.start(github)
        self.assertEqual(github.release, draft())
        self.assertIsNone(github.tag)
        self.assertEqual([call[0] for call in github.writes],
                         ["releases", "actions/workflows/release.yml/dispatches"])
        dispatch = github.writes[-1][2]
        self.assertEqual(dispatch["ref"], "main")
        self.assertEqual(dispatch["inputs"], dict(
            release_id="42", target_sha=SHA, content_digest=release.fingerprint(draft())))

    def test_start_reuses_matching_draft_in_later_page(self):
        github = FakeGitHub(draft())
        github.older_page = True
        self.start(github)
        self.assertEqual(len(github.writes), 1)
        self.assertIn("dispatches", github.writes[0][0])

    def test_existing_content_or_published_release_is_not_overwritten(self):
        for changes in (dict(body="Changed"), dict(name="Changed"),
                        dict(target_commitish=OTHER), dict(prerelease=True), dict(draft=False)):
            with self.subTest(changes=changes):
                github = FakeGitHub(draft(**changes))
                with self.assertRaises(release.ReleaseError):
                    self.start(github)
                self.assertEqual(github.writes, [])

    def test_dispatch_failure_leaves_reusable_draft(self):
        github = FakeGitHub()
        github.dispatch_error = True
        with self.assertRaisesRegex(release.ReleaseError, "Draft 42 remains"):
            self.start(github)
        self.assertTrue(github.release["draft"])
        self.assertIsNone(github.tag)
        github.dispatch_error = False
        self.start(github)
        self.assertEqual(sum(call[0] == "releases" for call in github.writes), 1)

    def test_branch_target_or_conflicting_tag_never_creates_draft(self):
        for target, tag in (("main", None), (SHA, OTHER)):
            github = FakeGitHub()
            github.tag = tag
            with self.assertRaises(release.ReleaseError):
                self.start(github, sha=target)
            self.assertEqual(github.writes, [])

    def test_annotated_tags_are_peeled(self):
        github = FakeGitHub()
        with patch.object(github, "api", side_effect=[
            {"object": {"type": "tag", "sha": OTHER}},
            {"object": {"type": "commit", "sha": SHA}},
        ]):
            self.assertEqual(release.check_tag(github, "v0.1.0", SHA), SHA)

    def test_lookup_failure_is_not_treated_as_missing_tag(self):
        github = FakeGitHub()
        with patch.object(github, "api", side_effect=release.APIError(403, "Forbidden")):
            with self.assertRaises(release.APIError):
                release.tag_commit(github, "v0.1.0")

    def test_verify_detects_content_target_and_tag_changes_without_writes(self):
        original = draft()
        for changes in (dict(body="Changed"), dict(name="Changed"), dict(prerelease=True),
                        dict(tag_name="v0.2.0"), dict(target_commitish=OTHER)):
            github = FakeGitHub(draft(**changes))
            with self.assertRaises(release.ReleaseError):
                release.verify(github, 42, SHA, release.fingerprint(original))
            self.assertEqual(github.writes, [])
        github = FakeGitHub(original)
        github.tag = OTHER
        with self.assertRaises(release.ReleaseError):
            release.publish(github, 42, SHA, release.fingerprint(original))
        self.assertEqual(github.writes, [])

    def test_verify_ignores_unrelated_metadata_and_never_publishes(self):
        github = FakeGitHub(draft(updated_at="later", download_count=10))
        release.verify(github, 42, SHA, release.fingerprint(draft()))
        self.assertEqual(github.writes, [])
        self.assertTrue(github.release["draft"])

    def test_publish_creates_exact_tag_and_preserves_stable_or_prerelease_content(self):
        for prerelease in (False, True):
            github = FakeGitHub(draft(prerelease=prerelease))
            digest = release.fingerprint(github.release)
            release.publish(github, 42, SHA, digest)
            self.assertEqual(github.tag, SHA)
            self.assertFalse(github.release["draft"])
            self.assertEqual(release.fingerprint(github.release), digest)
            self.assertEqual(github.writes[0], ("git/refs", "POST", dict(ref="refs/tags/v0.1.0", sha=SHA)))
            self.assertEqual(github.writes[1][2], dict(
                tag_name="v0.1.0", target_commitish=SHA, name="First release",
                body="One\n\nTwo\n", prerelease=prerelease, draft=False,
                make_latest="false" if prerelease else "legacy"))

    def test_publish_writes_approved_fields_even_if_the_draft_changes_after_verification(self):
        github = FakeGitHub(draft())
        digest = release.fingerprint(github.release)
        github.before_publish = lambda state: state.release.update(
            name="Unapproved title", body="Unapproved notes", tag_name="v9.9.9",
            target_commitish=OTHER, prerelease=True)
        release.publish(github, 42, SHA, digest)
        self.assertEqual(release.fingerprint(github.release), digest)
        self.assertFalse(github.release["draft"])
        self.assertEqual(github.tag, SHA)

    def test_existing_assets_stop_dispatch_without_removing_them(self):
        github = FakeGitHub(draft(assets=[{"id": 91, "name": "unapproved.zip"}]))
        with self.assertRaisesRegex(release.ReleaseError, "Uploaded assets are not approved"):
            self.start(github)
        self.assertEqual(github.writes, [])
        self.assertEqual(github.release["assets"][0]["id"], 91)

    def test_assets_added_during_validation_stop_publication(self):
        github = FakeGitHub(draft())
        digest = release.fingerprint(github.release)
        github.release["assets"] = [{"id": 92, "name": "new.zip"}]
        with self.assertRaisesRegex(release.ReleaseError, "Uploaded assets are not approved"):
            release.publish(github, 42, SHA, digest)
        self.assertEqual(github.writes, [])
        self.assertTrue(github.release["draft"])

    def test_failed_publication_can_resume_without_recreating_tag(self):
        github = FakeGitHub(draft())
        digest = release.fingerprint(github.release)
        github.publish_error = True
        with self.assertRaisesRegex(release.ReleaseError, "Tag v0.1.0 may already exist"):
            release.publish(github, 42, SHA, digest)
        self.assertTrue(github.release["draft"])
        self.assertEqual(github.tag, SHA)
        github.publish_error = False
        release.publish(github, 42, SHA, digest)
        self.assertFalse(github.release["draft"])
        self.assertEqual(sum(call[0] == "git/refs" for call in github.writes), 1)
        github.calls = []
        release.publish(github, 42, SHA, digest)
        self.assertEqual(github.writes, [])

    def test_change_during_tag_creation_stops_publication(self):
        github = FakeGitHub(draft())
        github.after_tag = lambda state: state.release.update(body="Edited during CI")
        with self.assertRaises(release.ReleaseError):
            release.publish(github, 42, SHA, release.fingerprint(draft()))
        self.assertTrue(github.release["draft"])
        self.assertEqual(len(github.writes), 1)

    def test_workflow_permission_failure_preserves_draft_and_can_resume_with_new_credentials(self):
        github = FakeGitHub(draft())
        digest = release.fingerprint(github.release)
        github.tag_error = True
        with self.assertRaisesRegex(release.ReleaseError, "configure RELEASE_TOKEN"):
            release.publish(github, 42, SHA, digest)
        self.assertTrue(github.release["draft"])
        self.assertIsNone(github.tag)
        self.assertFalse(any(call[1] == "PATCH" for call in github.writes))
        github.tag_error = False
        release.publish(github, 42, SHA, digest)
        self.assertEqual(github.tag, SHA)
        self.assertFalse(github.release["draft"])

    def test_racing_tag_creation_only_accepts_the_same_commit(self):
        for actual in (SHA, OTHER):
            github = FakeGitHub(draft())
            def create(state):
                state.tag = actual
                raise release.APIError(422, "Reference already exists")
            github.after_tag = create
            if actual == SHA:
                release.publish(github, 42, SHA, release.fingerprint(draft()))
                self.assertFalse(github.release["draft"])
            else:
                with self.assertRaises(release.ReleaseError):
                    release.publish(github, 42, SHA, release.fingerprint(draft()))
                self.assertTrue(github.release["draft"])

    def test_gh_transport_preserves_json_and_distinguishes_http_failure(self):
        github = release.GitHub("example/project")
        with patch.object(release.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, 'HTTP/2.0 201 Created\nX: value\n\n{"id":42}', "")
            self.assertEqual(github.api("releases", "POST", {"body": "first\nsecond"}), {"id": 42})
            self.assertEqual(json.loads(run.call_args.kwargs["input"]), {"body": "first\nsecond"})
            run.return_value = subprocess.CompletedProcess([], 1, 'HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}', "")
            with self.assertRaises(release.APIError) as caught:
                github.api("releases/42")
            self.assertEqual(caught.exception.status, 404)
            run.return_value = subprocess.CompletedProcess([], 0, "HTTP/2.0 204 No Content\nX: value\n\n", "")
            self.assertIsNone(github.api("actions/workflows/release.yml/dispatches", "POST", {}))


if __name__ == "__main__":
    unittest.main()
