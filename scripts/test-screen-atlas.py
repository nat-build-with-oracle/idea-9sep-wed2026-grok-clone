#!/usr/bin/env python3
"""Offline regression tests for atlas completeness and isolated capture output."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


capture = load("capture-screen-atlas")
verify = load("verify-screen-atlas")


class CaptureOutputTests(unittest.TestCase):
    def test_new_run_creates_logs_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            output = capture.prepare_output(Path(directory) / "new-run")
            self.assertTrue((output / "runs").is_dir())

    def test_nonempty_run_is_rejected_without_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            old = path / "existing.png"
            old.write_bytes(b"old evidence")
            with self.assertRaises(ValueError):
                capture.prepare_output(path)
            self.assertEqual(old.read_bytes(), b"old evidence")
            self.assertEqual(list(path.iterdir()), [old])

    def test_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "real").mkdir()
            (path / "link").symlink_to(path / "real", target_is_directory=True)
            with self.assertRaises(ValueError):
                capture.prepare_output(path / "link")
            self.assertEqual(list((path / "real").iterdir()), [])


class PublishedSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        # Other repository links can legitimately fail in this miniature copy;
        # each test asserts the particular completeness diagnostic it exercises.
        (self.root / "docs").mkdir()
        for name in verify.DOCS:
            shutil.copyfile(ROOT / "docs" / name, self.root / "docs" / name)
        shutil.copytree(ROOT / "docs/screenshots", self.root / "docs/screenshots")
        self.old_root = verify.ROOT
        verify.ROOT = self.root
        self.addCleanup(setattr, verify, "ROOT", self.old_root)

    def diagnostics(self):
        output = io.StringIO()
        with contextlib.redirect_stderr(output), contextlib.redirect_stdout(output):
            self.assertEqual(verify.main(), 1)
        return output.getvalue()

    def test_missing_screen_is_rejected(self):
        path = self.root / "docs/SCREENS-WORKSPACE.md"
        path.write_text(path.read_text().replace("## W01 —", "## Removed screen —"))
        self.assertIn("exactly the expected 55 screen IDs", self.diagnostics())

    def test_partial_scenario_list_is_rejected(self):
        path = self.root / "docs/screenshots/manifest.json"
        manifest = json.loads(path.read_text())
        manifest["scenarios"].pop()
        path.write_text(json.dumps(manifest))
        self.assertIn("exactly the expected 24 scenarios", self.diagnostics())

    def test_missing_duplicate_capture_record_is_rejected(self):
        path = self.root / "docs/screenshots/manifest.json"
        manifest = json.loads(path.read_text())
        manifest["images"].pop()
        path.write_text(json.dumps(manifest))
        self.assertIn("62 records, 58 PNG files, 50 unique rasters", self.diagnostics())


if __name__ == "__main__":
    unittest.main()
