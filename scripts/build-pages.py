#!/usr/bin/env python3
"""Render and assemble the documentation-only GitHub Pages site.

Rendering is an explicit maintainer action and requires pandoc. CI can verify the
committed render and assemble it without pandoc by using --check and --output.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
SITE = ROOT / "site"
BUILD_MANIFEST = ".pages-build.json"
REPOSITORY_URL = "https://github.com/nat-build-with-oracle/idea-9sep-wed2026-grok-clone"

# This is intentionally explicit: adding a Markdown file never publishes it by
# accident. Keep private references, runtime state, and memory outside this list.
PUBLIC_DOCS = (
    "APPEARANCE.md",
    "ATTACHMENTS.md",
    "BOT-DELETION.md",
    "CODEX-ADAPTER-CONTRACT.md",
    "COMPUTER-TERMINAL-CONTRACT.md",
    "DURABLE-WORKSPACE.md",
    "FEATURE-ATLAS.md",
    "GROUP-MENTIONS.md",
    "GROUP-ROUNDS.md",
    "IMPLEMENTATION.md",
    "NATIVE-PROTOTYPE.md",
    "NATIVE-REWRITE-CONTRACT.md",
    "PROVIDER-CORE.md",
    "PROVIDER-SETUP.md",
    "REFERENCE-SCREENS.md",
    "REPLY-WORKFLOW.md",
    "ROUTINES.md",
    "SCREENS-MANAGEMENT.md",
    "SCREENS-WORKSPACE.md",
    "SCREENSHOT-CATALOG.md",
    "UNREAD-CONVERSATIONS.md",
    "WORKSPACE-EXPORT.md",
)
PUBLIC_ROOT_SOURCES = frozenset(
    {"README.md", "CONTRIBUTING.md", "DESIGN.md", "LICENSE", "PRODUCT.md", "PROPOSAL.md"}
)

# Generic shapes for deployment details that must never enter the public site.
# Patterns are deliberately non-literal so the guard is not itself a disclosure.
PRIVATE_PATTERNS = (
    re.compile(r"\btty\w*\b", re.IGNORECASE),
    re.compile(r"\bkvm[\w-]*\b", re.IGNORECASE),
    re.compile(r"\b10(?:\.\d{1,3}){3}\b"),
    re.compile(r"\b192\.168(?:\.\d{1,3}){2}\b"),
    re.compile(r"\b172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2}\b"),
    re.compile(r"\b[a-z0-9-]+\.(?:netbird|internal)\b", re.IGNORECASE),
)

STYLE = r"""
:root{color-scheme:light dark;--bg:#f6f7fb;--surface:#fff;--text:#18202b;--muted:#5d6877;--line:#d9dee7;--accent:#5a43c7;--code:#f0f2f6}
@media(prefers-color-scheme:dark){:root{--bg:#101319;--surface:#181d25;--text:#edf1f7;--muted:#abb5c4;--line:#343c49;--accent:#a99aff;--code:#11151b}}
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:var(--bg);color:var(--text);font:16px/1.65 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}a{color:var(--accent);text-underline-offset:.18em}a:hover{text-decoration-thickness:2px}.site-nav{position:sticky;top:0;z-index:10;display:flex;gap:.9rem;align-items:center;flex-wrap:wrap;padding:.75rem max(1rem,calc((100vw - 1120px)/2));background:color-mix(in srgb,var(--surface) 92%,transparent);border-bottom:1px solid var(--line);backdrop-filter:blur(12px)}.site-nav a{text-decoration:none;font-weight:650}.site-nav .source{margin-left:auto}.page{width:min(1120px,calc(100% - 2rem));margin:2rem auto 5rem;padding:clamp(1rem,3vw,3.5rem);background:var(--surface);border:1px solid var(--line);border-radius:14px;box-shadow:0 12px 36px #0001}.eyebrow{color:var(--muted);font-size:.85rem;text-transform:uppercase;letter-spacing:.08em}h1,h2,h3,h4{line-height:1.25;scroll-margin-top:5rem}h1{font-size:clamp(2rem,5vw,3.3rem);margin-top:.25rem}h2{margin-top:2.8rem;padding-top:.4rem;border-top:1px solid var(--line)}p,li{max-width:82ch}table{display:block;width:max-content;max-width:100%;overflow-x:auto;border-collapse:collapse;margin:1.5rem 0}th,td{padding:.55rem .75rem;border:1px solid var(--line);text-align:left;vertical-align:top}th{background:var(--code)}pre{max-width:100%;overflow:auto;padding:1rem;border:1px solid var(--line);border-radius:8px;background:var(--code);line-height:1.42}code{font:0.9em/1.45 ui-monospace,SFMono-Regular,Menlo,monospace;overflow-wrap:anywhere}pre code{overflow-wrap:normal}img{display:block;max-width:100%;height:auto;border:1px solid var(--line);border-radius:8px}blockquote{margin-left:0;padding:.15rem 1rem;border-left:4px solid var(--accent);color:var(--muted)}hr{border:0;border-top:1px solid var(--line)}
@media(max-width:620px){.site-nav{gap:.55rem;font-size:.9rem}.site-nav .source{margin-left:0}.page{width:100%;margin:0;padding:1rem;border-width:0;border-radius:0}h1{font-size:2rem}}
""".strip() + "\n"


class BuildError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_file(path: Path, *, beneath: Path) -> None:
    if path.is_symlink():
        raise BuildError(f"symlinks are not publishable: {path.relative_to(ROOT)}")
    try:
        path.resolve().relative_to(beneath.resolve())
    except ValueError as error:
        raise BuildError(f"path escapes allowed root: {path}") from error
    if not path.is_file():
        raise BuildError(f"missing required file: {path.relative_to(ROOT)}")


def screenshot_inventory() -> tuple[dict, dict[str, str]]:
    manifest_path = DOCS / "screenshots" / "manifest.json"
    safe_file(manifest_path, beneath=DOCS / "screenshots")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    records = manifest.get("images")
    if not isinstance(records, list) or not records:
        raise BuildError("screenshot manifest has no image records")
    expected: dict[str, str] = {}
    for record in records:
        name, digest = record.get("file"), record.get("sha256")
        if not isinstance(name, str) or PurePosixPath(name).name != name or name in {"", ".", ".."}:
            raise BuildError(f"unsafe screenshot filename: {name!r}")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise BuildError(f"invalid screenshot hash: {name!r}")
        if name in expected and expected[name] != digest:
            raise BuildError(f"conflicting screenshot hashes: {name}")
        expected[name] = digest
    actual = {path.name for path in (DOCS / "screenshots").glob("*.png")}
    if actual != set(expected):
        raise BuildError(f"screenshot inventory mismatch: missing={sorted(set(expected)-actual)} extra={sorted(actual-set(expected))}")
    for name, digest in expected.items():
        source = DOCS / "screenshots" / name
        safe_file(source, beneath=DOCS / "screenshots")
        if sha256(source) != digest:
            raise BuildError(f"screenshot hash mismatch: {name}")
        with source.open("rb") as handle:
            if handle.read(8) != b"\x89PNG\r\n\x1a\n":
                raise BuildError(f"not a PNG: {name}")
            handle.read(8)
            width, height = struct.unpack(">II", handle.read(8))
        dimensions = {(r.get("width"), r.get("height")) for r in records if r.get("file") == name}
        if dimensions != {(width, height)}:
            raise BuildError(f"screenshot dimensions mismatch: {name}")
    return manifest, expected


def split_target(target: str) -> tuple[str, str]:
    path, marker, fragment = target.partition("#")
    return path, f"#{fragment}" if marker else ""


def rewrite_target(target: str, *, gallery: bool = False) -> str:
    if not target or target.startswith(("#", "https://", "http://", "mailto:")):
        return target
    path, fragment = split_target(target)
    decoded = unquote(path)
    if gallery:
        if decoded == "../FEATURE-ATLAS.md":
            return "../FEATURE-ATLAS.html" + fragment
        if decoded == "../SCREENSHOT-CATALOG.md":
            return "../SCREENSHOT-CATALOG.html" + fragment
        return target
    if decoded in PUBLIC_DOCS:
        return decoded[:-3] + ".html" + fragment
    if decoded.startswith("screenshots/"):
        return decoded + fragment
    # Source-code references leave the publish tree and become explicit GitHub links.
    normalized = PurePosixPath("docs", decoded)
    parts: list[str] = []
    for part in normalized.parts:
        if part == "..":
            if not parts:
                raise BuildError(f"link escapes repository: {target}")
            parts.pop()
        elif part not in {"", "."}:
            parts.append(part)
    repo_path = "/".join(parts)
    if decoded.startswith("../") and repo_path in PUBLIC_ROOT_SOURCES:
        return f"{REPOSITORY_URL}/blob/main/{repo_path}{fragment}"
    if decoded.endswith(".md"):
        raise BuildError(f"Markdown link is not in publication allowlist: {target}")
    return f"{REPOSITORY_URL}/blob/main/{repo_path}{fragment}"


ATTR_RE = re.compile(r'(?P<prefix>\b(?:href|src)=)(?P<quote>["\'])(?P<value>.*?)(?P=quote)')


def rewrite_html_targets(document: str, *, gallery: bool = False) -> str:
    def replace(match: re.Match[str]) -> str:
        value = html.unescape(match.group("value"))
        rewritten = rewrite_target(value, gallery=gallery)
        return f'{match.group("prefix")}{match.group("quote")}{html.escape(rewritten, quote=True)}{match.group("quote")}'
    return ATTR_RE.sub(replace, document)


def title_for(source: Path) -> str:
    match = re.search(r"^#\s+(.+?)\s*$", source.read_text(encoding="utf-8"), re.MULTILINE)
    return match.group(1).replace("`", "") if match else source.stem.replace("-", " ").title()


def page_shell(title: str, body: str, source_name: str) -> str:
    source_url = f"{REPOSITORY_URL}/blob/main/docs/{source_name}"
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(title)} · BotWorkspace</title><link rel="stylesheet" href="style.css"></head>
<body><nav class="site-nav" aria-label="Site"><a href="index.html">Feature atlas</a><a href="SCREENS-WORKSPACE.html">Workspace screens</a><a href="SCREENS-MANAGEMENT.html">Management screens</a><a href="screenshots/">Screenshots</a><a class="source" href="{source_url}">View source on GitHub</a></nav>
<main class="page"><p class="eyebrow">BotWorkspace product contract</p>{body}</main></body></html>
"""


def render_gallery(source: Path) -> str:
    document = rewrite_html_targets(source.read_text(encoding="utf-8"), gallery=True)
    document = document.replace("</head>", '<link rel="stylesheet" href="../style.css"></head>', 1)
    document = document.replace("<main>", '<nav><a href="../index.html">Feature atlas</a> · <a href="../SCREENS-WORKSPACE.html">Workspace screens</a> · <a href="../SCREENS-MANAGEMENT.html">Management screens</a> · <a href="https://github.com/nat-build-with-oracle/idea-9sep-wed2026-grok-clone">GitHub</a></nav><main>', 1)
    return document


def assert_public_text(path: Path) -> None:
    if path.suffix.lower() not in {".html", ".css", ".json", ".md"}:
        return
    text = path.read_text(encoding="utf-8", errors="strict").lower()
    label = path.relative_to(ROOT).as_posix() if path.is_relative_to(ROOT) else str(path)
    for pattern in PRIVATE_PATTERNS:
        if pattern.search(text):
            raise BuildError(f"private deployment detail rejected in {label}")
    forbidden_roots = ("/users/", "\\users\\", ".omx/", "ψ/", "docs/reference/")
    if any(marker in text for marker in forbidden_roots):
        raise BuildError(f"private filesystem reference rejected in {label}")


def input_hashes() -> dict[str, str]:
    sources = [Path(__file__).resolve(), *(DOCS / name for name in PUBLIC_DOCS), DOCS / "screenshots/index.html", DOCS / "screenshots/manifest.json"]
    result = {}
    for source in sources:
        safe_file(source, beneath=ROOT)
        result[source.relative_to(ROOT).as_posix()] = sha256(source)
    return result


def generated_names() -> tuple[str, ...]:
    return ("index.html", "style.css", *(name[:-3] + ".html" for name in PUBLIC_DOCS), "screenshots/index.html")


def render() -> None:
    pandoc = shutil.which("pandoc")
    if not pandoc:
        raise BuildError("--render requires pandoc; --check and --output do not")
    screenshot_inventory()
    for name in PUBLIC_DOCS:
        assert_public_text(DOCS / name)
    assert_public_text(DOCS / "screenshots/index.html")
    with tempfile.TemporaryDirectory(prefix="botworkspace-pages-") as temporary:
        output = Path(temporary)
        (output / "screenshots").mkdir()
        (output / "style.css").write_text(STYLE, encoding="utf-8")
        for name in PUBLIC_DOCS:
            source = DOCS / name
            result = subprocess.run(
                [pandoc, "--from=gfm", "--to=html5", "--wrap=none", str(source)],
                check=True, capture_output=True, text=True, encoding="utf-8"
            )
            body = rewrite_html_targets(result.stdout)
            page = page_shell(title_for(source), body, name)
            destination = output / (name[:-3] + ".html")
            destination.write_text(page, encoding="utf-8")
            assert_public_text(destination)
        shutil.copyfile(output / "FEATURE-ATLAS.html", output / "index.html")
        gallery = output / "screenshots" / "index.html"
        gallery.write_text(render_gallery(DOCS / "screenshots/index.html"), encoding="utf-8")
        assert_public_text(gallery)
        outputs = {name: sha256(output / name) for name in generated_names()}
        metadata = {"formatVersion": 1, "inputs": input_hashes(), "outputs": outputs}
        (output / BUILD_MANIFEST).write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        if SITE.exists():
            if SITE.is_symlink():
                raise BuildError("site directory may not be a symlink")
            allowed = set(generated_names()) | {BUILD_MANIFEST}
            existing = {path.relative_to(SITE).as_posix() for path in SITE.rglob("*") if path.is_file() or path.is_symlink()}
            if not existing.issubset(allowed):
                raise BuildError(f"refusing to replace site with unknown files: {sorted(existing-allowed)}")
            shutil.rmtree(SITE)
        shutil.copytree(output, SITE)
    validate_site()
    print(f"PAGES_RENDER_PASS docs={len(PUBLIC_DOCS)} files={len(generated_names())}")


def read_build_manifest() -> dict:
    path = SITE / BUILD_MANIFEST
    safe_file(path, beneath=SITE)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeError) as error:
        raise BuildError(f"invalid {BUILD_MANIFEST}: {error}") from error


def validate_site() -> None:
    metadata = read_build_manifest()
    if metadata.get("inputs") != input_hashes():
        raise BuildError("committed site is stale; run scripts/build-pages.py --render")
    expected_names = set(generated_names()) | {BUILD_MANIFEST}
    actual_names = {path.relative_to(SITE).as_posix() for path in SITE.rglob("*") if path.is_file() or path.is_symlink()}
    if actual_names != expected_names:
        raise BuildError(f"site inventory mismatch: missing={sorted(expected_names-actual_names)} extra={sorted(actual_names-expected_names)}")
    expected_outputs = metadata.get("outputs")
    if not isinstance(expected_outputs, dict) or set(expected_outputs) != set(generated_names()):
        raise BuildError("invalid generated output inventory")
    for name, digest in expected_outputs.items():
        path = SITE / name
        safe_file(path, beneath=SITE)
        if sha256(path) != digest:
            raise BuildError(f"generated page is stale or modified: {name}")
        assert_public_text(path)


def validate_links(output: Path) -> None:
    html_files = sorted(output.rglob("*.html"))
    ids: dict[Path, set[str]] = {}
    for page in html_files:
        text = page.read_text(encoding="utf-8")
        ids[page] = set(re.findall(r'\bid=["\']([^"\']+)["\']', text))
    for page in html_files:
        text = page.read_text(encoding="utf-8")
        for raw in re.findall(r'\bhref=["\']([^"\']+)["\']', text):
            target = html.unescape(raw)
            parsed = urlsplit(target)
            if parsed.scheme or target.startswith(("mailto:", "javascript:")):
                continue
            relative = unquote(parsed.path)
            destination = page if not relative else page.parent / relative
            if relative.endswith("/"):
                destination /= "index.html"
            destination = destination.resolve()
            try:
                destination.relative_to(output.resolve())
            except ValueError as error:
                raise BuildError(f"local link escapes artifact: {page.relative_to(output)} -> {target}") from error
            if not destination.is_file():
                raise BuildError(f"broken local link: {page.relative_to(output)} -> {target}")
            if parsed.fragment and destination.suffix == ".html":
                if parsed.fragment not in ids.get(destination, set()):
                    raise BuildError(f"broken anchor: {page.relative_to(output)} -> {target}")


def assemble(destination: Path) -> None:
    validate_site()
    _, screenshots = screenshot_inventory()
    resolved = destination.resolve()
    if resolved == ROOT.resolve() or ROOT.resolve() in resolved.parents and resolved in {DOCS.resolve(), SITE.resolve()}:
        raise BuildError(f"unsafe output directory: {destination}")
    if destination.is_symlink():
        raise BuildError("output directory may not be a symlink")
    with tempfile.TemporaryDirectory(prefix="botworkspace-pages-output-", dir=destination.parent if destination.parent.exists() else None) as temporary:
        stage = Path(temporary) / "site"
        stage.mkdir()
        for name in generated_names():
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SITE / name, target)
        screenshot_dir = stage / "screenshots"
        shutil.copyfile(DOCS / "screenshots" / "manifest.json", screenshot_dir / "manifest.json")
        for name in sorted(screenshots):
            shutil.copyfile(DOCS / "screenshots" / name, screenshot_dir / name)
        for path in stage.rglob("*"):
            if path.is_file():
                assert_public_text(path)
        validate_links(stage)
        if destination.exists():
            if not destination.is_dir():
                raise BuildError(f"output exists and is not a directory: {destination}")
            if any(destination.iterdir()):
                raise BuildError(f"refusing to replace nonempty output directory: {destination}")
            destination.rmdir()
        shutil.copytree(stage, destination)
    print(f"PAGES_OUTPUT_PASS destination={destination} pages={len(tuple(destination.rglob('*.html')))} screenshots={len(screenshots)}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--render", action="store_true", help="regenerate committed site/ with pandoc")
    action.add_argument("--check", action="store_true", help="verify committed render freshness and privacy")
    action.add_argument("--output", type=Path, metavar="DIR", help="assemble deployable artifact without pandoc")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        if args.render:
            render()
        elif args.check:
            validate_site()
            screenshot_inventory()
            print(f"PAGES_CHECK_PASS docs={len(PUBLIC_DOCS)} files={len(generated_names())}")
        else:
            assemble(args.output)
    except (BuildError, OSError, subprocess.CalledProcessError) as error:
        print(f"PAGES_BUILD_FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
