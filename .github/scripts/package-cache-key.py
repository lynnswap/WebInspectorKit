#!/usr/bin/env python3
"""Hash the calling checkout's tracked Swift package lockfiles for CI caching."""

import hashlib
import os
import subprocess
from pathlib import Path


def lockfiles_digest():
    paths = subprocess.check_output(["git", "ls-files", "-z", "--", "*Package.resolved"])
    digest = hashlib.sha256()
    for path in sorted(filter(None, paths.split(b"\0"))):
        content = Path(os.fsdecode(path)).read_bytes()
        digest.update(path)
        digest.update(b"\0")
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
    return digest.hexdigest()


if __name__ == "__main__":
    output = f"lockfiles={lockfiles_digest()}\n"
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as destination:
        destination.write(output)
    print(output, end="")
