#!/usr/bin/env python3
from __future__ import annotations

import argparse
import contextlib
import fcntl
import functools
import os
import shlex
import shutil
import socket
import subprocess
import sys
import webbrowser
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit


BASE_PATH = "WebInspectorKit"
HOST = "127.0.0.1"
SIMULATOR_TRIPLE = "arm64-apple-ios18.0-simulator"
TARGETS = [
    "WebInspectorUI",
    "WebInspectorDataKit",
    "WebInspectorProxyKit",
    "WebInspectorProxyKitTesting",
]
MODULE_PATHS = {
    "webinspectordatakit",
    "webinspectorproxykit",
    "webinspectorproxykittesting",
    "webinspectorui",
}


def parse_port(value: str) -> int:
    try:
        port = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer") from error

    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError("must be between 1 and 65535")
    return port


def resolve_port(parsed_port: int | None) -> int:
    if parsed_port is not None:
        return parsed_port

    value = os.environ.get("PORT", "8080")
    try:
        return parse_port(value)
    except argparse.ArgumentTypeError as error:
        print(f"error: invalid PORT value {value!r}: {error}", file=sys.stderr)
        raise SystemExit(64) from error


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Build combined DocC documentation, serve it with the GitHub Pages "
            "base path, and open the WebInspectorKit documentation root."
        )
    )
    parser.add_argument(
        "--port",
        type=parse_port,
        default=None,
        help="preferred local port; increments if the port is already in use",
    )
    parser.add_argument(
        "--no-open",
        action="store_true",
        help="serve without opening a browser",
    )
    parser.add_argument(
        "--no-generate",
        action="store_true",
        help="reuse the existing .build/docs output",
    )
    parser.add_argument(
        "--no-serve",
        action="store_true",
        help="generate documentation without starting a local server",
    )
    return parser.parse_args()


def require_tool(name: str) -> None:
    if shutil.which(name) is None:
        print(f"error: {name} is required.", file=sys.stderr)
        raise SystemExit(69)


def run(command: list[str], *, cwd: Path) -> None:
    print("+ " + shlex.join(command), flush=True)
    subprocess.run(command, cwd=cwd, check=True)


def command_output(command: list[str], *, cwd: Path | None = None) -> str:
    return subprocess.check_output(command, cwd=cwd, text=True).strip()


def repo_root() -> Path:
    script_root = Path(__file__).resolve().parents[1]
    if (script_root / "Package.swift").is_file():
        return script_root

    if shutil.which("git") is not None:
        try:
            return Path(command_output(["git", "rev-parse", "--show-toplevel"])).resolve()
        except subprocess.CalledProcessError:
            pass

    print("error: could not find the WebInspectorKit repository root.", file=sys.stderr)
    raise SystemExit(66)


@contextlib.contextmanager
def preview_lock(root: Path):
    lock_path = root / ".build" / "docc-preview.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("w") as lock_file:
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(
                "error: another DocC preview is already running. "
                "Stop it with Control-C before starting a new one.",
                file=sys.stderr,
            )
            raise SystemExit(75)

        yield


def generate_documentation(root: Path, output_path: Path, scratch_path: Path) -> None:
    shutil.rmtree(output_path, ignore_errors=True)
    shutil.rmtree(scratch_path, ignore_errors=True)
    shutil.rmtree(root / ".build" / SIMULATOR_TRIPLE, ignore_errors=True)

    output_argument = str(output_path.relative_to(root))
    scratch_argument = str(scratch_path.relative_to(root))
    sdk_path = command_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
    command = [
        "swift",
        "package",
        "--scratch-path",
        scratch_argument,
        "--sdk",
        sdk_path,
        "--triple",
        SIMULATOR_TRIPLE,
        "--allow-writing-to-directory",
        output_argument,
        "generate-documentation",
    ]
    for target in TARGETS:
        command.extend(["--target", target])
    command.extend(
        [
            "--disable-indexing",
            "--enable-experimental-combined-documentation",
            "--transform-for-static-hosting",
            "--hosting-base-path",
            BASE_PATH,
            "--warnings-as-errors",
            "--output-path",
            output_argument,
        ]
    )

    run(command, cwd=root)
    (output_path / ".nojekyll").touch()


def require_generated_documentation(output_path: Path) -> None:
    if (output_path / "index.html").is_file():
        return

    print(
        f"error: generated documentation was not found at {output_path}.",
        file=sys.stderr,
    )
    print("Run without --no-generate to build it first.", file=sys.stderr)
    raise SystemExit(66)


def prepare_site_root(output_path: Path, site_root: Path) -> None:
    shutil.rmtree(site_root, ignore_errors=True)
    site_root.mkdir(parents=True, exist_ok=True)
    (site_root / BASE_PATH).symlink_to(output_path.resolve(), target_is_directory=True)


def first_available_port(starting_port: int) -> int:
    for port in range(starting_port, 65536):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                probe.bind((HOST, port))
            except OSError:
                continue
            return port

    print("error: no available TCP port found.", file=sys.stderr)
    raise SystemExit(69)


def preview_url(port: int) -> str:
    return f"http://{HOST}:{port}/{BASE_PATH}/documentation/"


class DocCPreviewRequestHandler(SimpleHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.redirect_short_docc_path():
            return
        super().do_GET()

    def do_HEAD(self) -> None:
        if self.redirect_short_docc_path():
            return
        super().do_HEAD()

    def redirect_short_docc_path(self) -> bool:
        redirect_path = short_docc_redirect_path(self.path)
        if redirect_path is None:
            return False

        self.send_response(302)
        self.send_header("Location", redirect_path)
        self.end_headers()
        return True


def short_docc_redirect_path(request_path: str) -> str | None:
    parsed = urlsplit(request_path)
    segments = [segment for segment in parsed.path.split("/") if segment]

    if not segments or segments[0] != BASE_PATH:
        return None

    if len(segments) == 1:
        return urlunsplit(("", "", f"/{BASE_PATH}/documentation/", parsed.query, parsed.fragment))

    if segments[1] == "webinspectorkit":
        return urlunsplit(("", "", f"/{BASE_PATH}/documentation/", parsed.query, parsed.fragment))

    if len(segments) >= 3 and segments[1] == "documentation" and segments[2] == "webinspectorkit":
        return urlunsplit(("", "", f"/{BASE_PATH}/documentation/", parsed.query, parsed.fragment))

    if segments[1] not in MODULE_PATHS:
        return None

    suffix = "/".join(segments[2:])
    suffix = f"{suffix}/" if suffix else ""
    return urlunsplit(
        ("", "", f"/{BASE_PATH}/documentation/{segments[1]}/{suffix}", parsed.query, parsed.fragment)
    )


def serve(site_root: Path, port: int, *, open_browser: bool) -> None:
    handler = functools.partial(DocCPreviewRequestHandler, directory=str(site_root))

    with ThreadingHTTPServer((HOST, port), handler) as server:
        url = preview_url(port)
        print(f"Serving DocC documentation at {url}", flush=True)
        print("Press Control-C to stop the server.", flush=True)
        if open_browser:
            webbrowser.open(url)

        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("\nStopping DocC preview server.", flush=True)


def main() -> None:
    args = parse_arguments()
    args.port = resolve_port(args.port)
    root = repo_root()
    output_path = root / ".build" / "docs"
    scratch_path = root / ".build" / "docc-preview"
    site_root = root / ".build" / "docc-preview-site"

    with preview_lock(root):
        if not args.no_generate:
            require_tool("swift")
            require_tool("xcrun")
            generate_documentation(root, output_path, scratch_path)

        require_generated_documentation(output_path)
        prepare_site_root(output_path, site_root)

        if args.no_serve:
            print(f"Generated DocC documentation: {output_path}", flush=True)
            print(f"Preview URL when served: {preview_url(args.port)}", flush=True)
            return

        port = first_available_port(args.port)
        serve(site_root, port, open_browser=not args.no_open)


if __name__ == "__main__":
    main()
