#!/usr/bin/env python3
"""Check the documentation dump, local links, screen IDs, and actual PNG evidence."""

import hashlib
import json
from pathlib import Path
import re
import struct
import sys
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
DOCS = [
    "FEATURE-ATLAS.md", "SCREENS-WORKSPACE.md", "SCREENS-MANAGEMENT.md",
    "SCREENSHOT-CATALOG.md", "REFERENCE-SCREENS.md", "COMPUTER-TERMINAL-CONTRACT.md",
]
EXPECTED_SCREENS = (
    {f"W{i:02}" for i in range(1, 20)}
    | {f"M{i:02}" for i in range(1, 21)}
    | {f"M20{suffix}" for suffix in "ABCD"}
    | {f"R{i:02}" for i in range(1, 9)}
    | {f"C{i:02}" for i in range(1, 5)}
)
EXPECTED_SCENARIOS = {
    "sample-chat", "sample-picker", "sample-group-picker", "workspace", "workspace-minimum",
    "provider-chat", "provider-settings", "router-settings", "codex-chat", "codex-settings",
    "edit-bot", "edit-group", "reply", "export", "deletion", "routine", "attachment",
    "appearance", "appearance-minimum", "unread", "group-round", "group-round-minimum",
    "mention", "mention-minimum",
}


def main():
    errors = []
    manifest = json.loads((ROOT / "docs/screenshots/manifest.json").read_text())
    scenario_ids = [scenario["id"] for scenario in manifest["scenarios"]]
    if set(scenario_ids) != EXPECTED_SCENARIOS or len(scenario_ids) != 24:
        errors.append("Published atlas must contain exactly the expected 24 scenarios")
    files = {}
    for item in manifest["images"]:
        path = ROOT / "docs/screenshots" / item["file"]
        if path.parent != ROOT / "docs/screenshots" or not path.is_file():
            errors.append(f"Missing or unsafe image: {item['file']}")
            continue
        data = path.read_bytes()
        if data[:8] != b"\x89PNG\r\n\x1a\n" or len(data) < 24:
            errors.append(f"Invalid PNG: {path.name}")
            continue
        if list(struct.unpack(">II", data[16:24])) != [item["width"], item["height"]]:
            errors.append(f"Dimension mismatch: {path.name}")
        if hashlib.sha256(data).hexdigest() != item["sha256"]:
            errors.append(f"Hash mismatch: {path.name}")
        if item["file"] in files and files[item["file"]] != item["sha256"]:
            errors.append(f"Conflicting repeated capture: {path.name}")
        files[item["file"]] = item["sha256"]
    if set(files) != {p.name for p in (ROOT / "docs/screenshots").glob("*.png")}:
        errors.append("Gallery files differ from manifest inventory")
    # This verifier certifies the fixed published snapshot, not partial --only captures.
    if (len(manifest["images"]), len(files), len(set(files.values()))) != (62, 58, 50):
        errors.append("Published snapshot must contain 62 records, 58 PNG files, 50 unique rasters")
    if any(s["exitCode"] != 0 for s in manifest["scenarios"]):
        errors.append("A capture scenario was not successful")
    catalog = (ROOT / "docs/SCREENSHOT-CATALOG.md").read_text()
    for name in files:
        if name not in catalog:
            errors.append(f"Image missing from catalog: {name}")
    screen_ids = []
    for filename in DOCS:
        path = ROOT / "docs" / filename
        if not path.is_file():
            errors.append(f"Missing atlas document: {filename}")
            continue
        text = path.read_text()
        if len(re.findall(r"^```", text, re.M)) % 2:
            errors.append(f"Unbalanced code fences: {filename}")
        if re.search(r"/Users/[^/\s]+/|[\w.-]+\.netbird\b", text):
            errors.append(f"Private local path/host in public atlas: {filename}")
        for match in re.finditer(r"!?\[[^\]]*\]\(([^)]+)\)", text):
            target = match.group(1).split(' "', 1)[0]
            parsed = urlsplit(target)
            if parsed.scheme or not parsed.path:
                continue
            target_path = (path.parent / unquote(parsed.path)).resolve()
            if not target_path.exists():
                errors.append(f"Broken local link in {filename}: {target}")
        headings = list(re.finditer(r"^#{2,3} ([WMRC]\d{2}[A-Z]?)\s+[—-][^\n]*", text, re.M))
        for index, match in enumerate(headings):
            screen_id = match.group(1)
            screen_ids.append(screen_id)
            end = headings[index + 1].start() if index + 1 < len(headings) else len(text)
            section = text[match.start():end]
            if "```text" not in section:
                errors.append(f"No ASCII wireframe for {screen_id} in {filename}")
            if screen_id.startswith(("W", "M")) and screen_id not in catalog:
                errors.append(f"No screenshot/coverage mapping for {screen_id}")
    if len(screen_ids) != len(set(screen_ids)):
        errors.append("Duplicate screen IDs across atlas documents")
    if set(screen_ids) != EXPECTED_SCREENS:
        errors.append("Published atlas must contain exactly the expected 55 screen IDs")
    gallery = ROOT / "docs/screenshots/index.html"
    if not gallery.exists():
        errors.append("Missing offline screenshot gallery")
    else:
        for target in re.findall(r'(?:src|href)="([^"]+)"', gallery.read_text()):
            parsed = urlsplit(target)
            if not parsed.scheme and parsed.path and not (gallery.parent / unquote(parsed.path)).exists():
                errors.append(f"Broken gallery link: {target}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"ATLAS_VERIFY_PASS docs={len(DOCS)} screen_ids={len(screen_ids)} "
          f"scenarios={len(manifest['scenarios'])} capture_records={len(manifest['images'])} "
          f"png_files={len(files)} unique_rasters={len(set(files.values()))}")
    print("Verified local links, ASCII sections, coverage mappings, PNG dimensions/hashes, and gallery links.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
