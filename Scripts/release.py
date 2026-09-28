#!/usr/bin/env python3
"""Create an approved draft and dispatch CI, or verify/publish it from Actions."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import quote


class ReleaseError(Exception):
    pass


class APIError(ReleaseError):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


class GitHub:
    def __init__(self, repository):
        self.repository = repository

    def api(self, path, method="GET", data=None):
        command = ["gh", "api", "--include", "--method", method,
                   f"repos/{self.repository}/{path}"]
        if data is not None:
            command += ["--input", "-"]
        result = subprocess.run(
            command, input=json.dumps(data) if data is not None else None,
            capture_output=True, text=True, check=False,
        )
        header, separator, body = result.stdout.partition("\n\n")
        if not separator or not header.startswith("HTTP/"):
            raise ReleaseError(result.stderr.strip() or "GitHub returned no HTTP response.")
        status = int(header.splitlines()[0].split()[1])
        payload = json.loads(body) if body.strip() else None
        if result.returncode or not 200 <= status < 300:
            message = payload.get("message", body) if isinstance(payload, dict) else body
            raise APIError(status, f"{method} {path}: {message}")
        return payload


def publication_fields(release):
    return {key: release[key] for key in
            ("tag_name", "target_commitish", "name", "body", "prerelease")}


def fingerprint(release):
    if release.get("assets"):
        raise ReleaseError("Uploaded assets are not approved by this source-release workflow; no assets were removed.")
    # Only publication content is compared; timestamps, counters, and URLs may change.
    content = dict(publication_fields(release), id=release["id"])
    return hashlib.sha256(json.dumps(content, sort_keys=True).encode()).hexdigest()


def check_sha(sha):
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ReleaseError("Use the full lowercase 40-character target commit SHA.")


def tag_commit(github, tag):
    try:
        entry = github.api("git/ref/tags/" + quote(tag, safe=""))
    except APIError as error:
        if error.status == 404:
            return None
        raise
    obj = entry["object"]
    while obj["type"] == "tag":
        obj = github.api("git/tags/" + obj["sha"])["object"]
    if obj["type"] != "commit":
        raise ReleaseError(f"Tag {tag} does not point to a commit.")
    return obj["sha"]


def check_tag(github, tag, sha):
    actual = tag_commit(github, tag)
    if actual is not None and actual != sha:
        raise ReleaseError(f"Tag {tag} points to {actual}, not approved commit {sha}.")
    return actual


def matching_releases(github, tag):
    matches = []
    page = 1
    while True:
        releases = github.api(f"releases?per_page=100&page={page}")
        matches += [release for release in releases if release["tag_name"] == tag]
        if len(releases) < 100:
            return matches
        page += 1


def start(github, tag, sha, title, notes, prerelease):
    check_sha(sha)
    if subprocess.run(["git", "check-ref-format", f"refs/tags/{tag}"],
                      capture_output=True, check=False).returncode:
        raise ReleaseError("The version must be a valid Git tag name.")
    # Resolve before creating a draft; branch names never become publication targets.
    if github.api("commits/" + sha)["sha"] != sha:
        raise ReleaseError("The target is not the requested commit.")
    check_tag(github, tag, sha)
    matches = matching_releases(github, tag)
    if len(matches) > 1:
        raise ReleaseError(f"Multiple releases use {tag}; select the intended draft first.")
    requested = dict(tag_name=tag, target_commitish=sha, name=title,
                     body=notes, prerelease=prerelease)
    if matches:
        release = matches[0]
        if not release["draft"]:
            raise ReleaseError(f"{tag} is already published.")
        if any(release[key] != value for key, value in requested.items()):
            raise ReleaseError("The existing draft differs from the supplied target or content; it was not changed.")
    else:
        release = github.api("releases", "POST", dict(requested, draft=True))
    print(f"Draft: {release['html_url']}", flush=True)
    inputs = dict(release_id=str(release["id"]), target_sha=sha,
                  content_digest=fingerprint(release))
    try:
        github.api("actions/workflows/release.yml/dispatches", "POST",
                   dict(ref="main", inputs=inputs))
    except ReleaseError as error:
        raise ReleaseError(
            f"{error}\nDraft {release['id']} remains. Dispatch acceptance may be uncertain; "
            "inspect Actions before retrying the same command."
        ) from error
    print(f"Target: {sha}")
    print("Release workflow dispatch accepted. Successful checks will publish this draft.")
    print(f"Actions: https://github.com/{github.repository}/actions/workflows/release.yml")


def verify(github, release_id, sha, digest):
    check_sha(sha)
    release = github.api(f"releases/{release_id}")
    if release["target_commitish"] != sha or fingerprint(release) != digest:
        raise ReleaseError("The release target or approved content changed; publication stopped.")
    check_tag(github, release["tag_name"], sha)
    return release


def publish(github, release_id, sha, digest):
    release = verify(github, release_id, sha, digest)
    if not release["draft"]:
        if tag_commit(github, release["tag_name"]) != sha:
            raise ReleaseError("The published release no longer has its approved tag.")
        print(f"Already published: {release['html_url']}")
        return
    tag = release["tag_name"]
    if tag_commit(github, tag) is None:
        try:
            github.api("git/refs", "POST", dict(ref="refs/tags/" + tag, sha=sha))
        except APIError as error:
            # Another run may have created the same tag between the read and write.
            if error.status != 422 or check_tag(github, tag, sha) is None:
                raise ReleaseError(
                    f"{error}\nNo release was published. Inspect tag rules and publication credentials. "
                    "If GitHub requires Workflows permission for this commit, configure RELEASE_TOKEN "
                    "with Contents and Workflows write access, then rerun the failed publish job."
                ) from error
    # Re-read after tag creation, so changes during that operation are also caught.
    verify(github, release_id, sha, digest)
    try:
        published = github.api(
            f"releases/{release_id}", "PATCH",
            dict(publication_fields(release), draft=False,
                 make_latest="false" if release["prerelease"] else "legacy"),
        )
    except ReleaseError as error:
        raise ReleaseError(
            f"{error}\nTag {tag} may already exist at {sha}. Inspect the release; "
            "rerun the failed publish job to resume without moving the tag."
        ) from error
    if published["draft"] or fingerprint(published) != digest:
        raise ReleaseError("GitHub's publication response did not preserve the approved release.")
    print(f"Published: {published['html_url']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    launch = commands.add_parser("start", help="Create/reuse a draft and start automatic publication")
    launch.add_argument("version")
    launch.add_argument("--target", required=True, help="Approved full commit SHA")
    launch.add_argument("--notes-file", required=True, type=Path)
    launch.add_argument("--title", help="Defaults to the version")
    launch.add_argument("--prerelease", action="store_true")
    launch.add_argument("--repo", help="Defaults to this checkout's GitHub repository")
    for name in ("verify", "publish"):
        command = commands.add_parser(name, help="Internal Actions entry point")
        command.add_argument("--repo", required=True)
        command.add_argument("--release-id", required=True, type=int)
        command.add_argument("--target", required=True)
        command.add_argument("--digest", required=True)
    arguments = parser.parse_args()
    try:
        repository = arguments.repo
        if repository is None:
            repository = subprocess.check_output(
                ["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
                cwd=Path(__file__).resolve().parent.parent, text=True,
            ).strip()
        github = GitHub(repository)
        if arguments.command == "start":
            start(github, arguments.version, arguments.target,
                  arguments.title or arguments.version,
                  arguments.notes_file.read_text(encoding="utf-8"), arguments.prerelease)
        elif arguments.command == "verify":
            release = verify(github, arguments.release_id, arguments.target, arguments.digest)
            print(f"Verified: {release['html_url']} at {arguments.target}")
        else:
            publish(github, arguments.release_id, arguments.target, arguments.digest)
    except (ReleaseError, OSError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
