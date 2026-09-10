#!/usr/bin/env python3
"""Capture only isolated, synthetic native fixtures for the documentation atlas.

Requires the existing macOS/Swift toolchain and Python 3; installs nothing.
Never opens the user's persistent workspace or the live Codex stdin smoke.
Default output and logs are ignored local artifacts. Publishing is a separate,
manual review step; this script does not stage, commit, or upload anything.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
from datetime import datetime, timezone


ROOT = Path(__file__).resolve().parents[1]
SCENARIOS = [
    ("sample-chat", "native-prototype.sh", ["snapshot"]),
    ("sample-picker", "native-prototype.sh", ["snapshot", "--picker"]),
    ("sample-group-picker", "native-prototype.sh", ["snapshot", "--group"]),
    ("workspace", "native-app.sh", ["smoke"]),
    ("workspace-minimum", "native-app.sh", ["smoke", "--minimum"]),
    ("provider-chat", "native-app.sh", ["provider-smoke"]),
    ("provider-settings", "native-app.sh", ["provider-smoke", "--settings"]),
    ("router-settings", "native-app.sh", ["provider-smoke", "--router-models"]),
    ("codex-chat", "native-app.sh", ["codex-smoke"]),
    ("codex-settings", "native-app.sh", ["codex-smoke", "--settings"]),
    ("edit-bot", "native-app.sh", ["profile-smoke"]),
    ("edit-group", "native-app.sh", ["profile-smoke", "--edit-group"]),
    ("reply", "native-app.sh", ["reply-smoke"]),
    ("export", "native-app.sh", ["export-smoke"]),
    ("deletion", "native-app.sh", ["deletion-smoke"]),
    ("routine", "native-app.sh", ["routine-smoke"]),
    ("attachment", "native-app.sh", ["attachment-smoke"]),
    ("appearance", "native-app.sh", ["appearance-smoke"]),
    ("appearance-minimum", "native-app.sh", ["appearance-smoke", "--minimum"]),
    ("unread", "native-app.sh", ["unread-smoke", "--fixture-foreground"]),
    ("group-round", "native-app.sh", ["group-smoke"]),
    ("group-round-minimum", "native-app.sh", ["group-smoke", "--minimum"]),
    ("mention", "native-app.sh", ["mention-smoke"]),
    ("mention-minimum", "native-app.sh", ["mention-smoke", "--minimum"]),
]


def prepare_output(path):
    """Fail closed rather than mix new captures with an earlier evidence set."""
    if path.is_symlink():
        raise ValueError("Capture output must not be a symbolic link")
    output = path.resolve()
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise ValueError("Capture output must be a new or empty directory")
    output.mkdir(parents=True, exist_ok=True)
    (output / "runs").mkdir()
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="Print scenarios without running them")
    parser.add_argument("--only", choices=[s[0] for s in SCENARIOS], action="append")
    run_stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    parser.add_argument("--output", type=Path,
                        default=ROOT / ".omx/artifacts/screen-atlas/captures" / run_stamp,
                        help="New or empty directory; defaults to a unique ignored run directory")
    args = parser.parse_args()
    scenarios = [s for s in SCENARIOS if not args.only or s[0] in args.only]
    if args.list:
        for name, script, flags in scenarios:
            print(f"{name}: scripts/{script} {' '.join(flags)}")
        return 0
    if sys.platform != "darwin":
        parser.error("Native captures require macOS; use --list elsewhere")
    try:
        output = prepare_output(args.output)
    except ValueError as error:
        parser.error(str(error))
    manifest = {
        "formatVersion": 1,
        "capturedAtUTC": datetime.now(timezone.utc).isoformat(),
        "sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "captureKind": "native-window-render; isolated synthetic fixtures, not desktop capture",
        "limitations": [
            "Fixture screenshots are not proof of live provider or physical UI interaction.",
            "Unread uses explicit fixture foreground, not the real window-focus gate.",
            "User-supplied reference screenshots and production auth are never inputs.",
        ],
        "scenarios": [],
        "images": [],
    }
    env = os.environ.copy()
    # Prevent a caller's bundle override from turning sample snapshots into a durable launch.
    env.pop("NATIVE_WORKSPACE_APP", None)
    for name, script, flags in scenarios:
        command = [str(ROOT / "scripts" / script), *flags]
        print(f"CAPTURE {name}", flush=True)
        result = subprocess.run(command, cwd=ROOT, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        (output / "runs" / f"{name}.log").write_text(result.stdout)
        if result.returncode:
            print(result.stdout[-4000:], file=sys.stderr)
            raise RuntimeError(f"{name} failed ({result.returncode}); see local runs log")
        snapshots = [Path(line.split("=", 1)[1]) for line in result.stdout.splitlines()
                     if line.startswith("NATIVE_SNAPSHOT=")]
        if not snapshots:
            raise RuntimeError(f"{name} produced no native screenshots")
        manifest["scenarios"].append({"id": name, "command": f"scripts/{script} {' '.join(flags)}",
                                      "exitCode": result.returncode})
        for source in snapshots:
            if not source.name.startswith("native-shell-") or source.suffix != ".png":
                raise RuntimeError(f"Unexpected screenshot name for {name}")
            data = source.read_bytes()
            if data[:8] != b"\x89PNG\r\n\x1a\n":
                raise RuntimeError(f"Invalid PNG from {name}")
            width, height = struct.unpack(">II", data[16:24])
            filename = f"{name}--{source.name.removeprefix('native-shell-')}"
            shutil.copyfile(source, output / filename)
            manifest["images"].append({"scenario": name, "file": filename,
                                       "width": width, "height": height,
                                       "sha256": hashlib.sha256(data).hexdigest()})
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"PASS {name}: {len(snapshots)} image(s)", flush=True)
    print(f"ATLAS_CAPTURE_PASS scenarios={len(scenarios)} images={len(manifest['images'])}")
    print(output / "manifest.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
