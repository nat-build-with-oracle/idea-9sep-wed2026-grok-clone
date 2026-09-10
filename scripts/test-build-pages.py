#!/usr/bin/env python3
"""Focused regression tests for the static Pages builder."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("build-pages.py")
SPEC = importlib.util.spec_from_file_location("build_pages", SCRIPT)
assert SPEC and SPEC.loader
build_pages = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build_pages)


class LinkRewriteTests(unittest.TestCase):
    def test_allowlisted_markdown_becomes_sibling_html_with_anchor(self) -> None:
        self.assertEqual(
            build_pages.rewrite_target("DURABLE-WORKSPACE.md#verification-evidence"),
            "DURABLE-WORKSPACE.html#verification-evidence",
        )

    def test_screenshot_subpath_stays_relative(self) -> None:
        self.assertEqual(
            build_pages.rewrite_target("screenshots/example.png"),
            "screenshots/example.png",
        )

    def test_repo_source_becomes_public_github_link(self) -> None:
        self.assertEqual(
            build_pages.rewrite_target("../Packages/Example/File.swift"),
            build_pages.REPOSITORY_URL + "/blob/main/Packages/Example/File.swift",
        )

    def test_allowlisted_root_markdown_becomes_github_source_link(self) -> None:
        self.assertEqual(
            build_pages.rewrite_target("../README.md#documentation"),
            build_pages.REPOSITORY_URL + "/blob/main/README.md#documentation",
        )

    def test_unknown_markdown_is_rejected(self) -> None:
        with self.assertRaises(build_pages.BuildError):
            build_pages.rewrite_target("PRIVATE-NOTES.md")

    def test_gallery_markdown_nav_is_rewritten_at_nested_depth(self) -> None:
        self.assertEqual(
            build_pages.rewrite_target("../FEATURE-ATLAS.md", gallery=True),
            "../FEATURE-ATLAS.html",
        )


class PrivacyAndFreshnessTests(unittest.TestCase):
    def test_generic_private_marker_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            page = Path(temporary) / "page.html"
            # Synthetic RFC1918 address; no real deployment identifier is encoded.
            page.write_text("<p>connect 10.23.45.67</p>", encoding="utf-8")
            with self.assertRaises(build_pages.BuildError):
                build_pages.assert_public_text(page)

    def test_absolute_home_directory_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            page = Path(temporary) / "page.html"
            page.write_text("<p>/Users/example/secret.png</p>", encoding="utf-8")
            with self.assertRaises(build_pages.BuildError):
                build_pages.assert_public_text(page)

    def test_ignored_runtime_path_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            page = Path(temporary) / "page.md"
            page.write_text("See .omx/example/private-index.md", encoding="utf-8")
            with self.assertRaises(build_pages.BuildError):
                build_pages.assert_public_text(page)

    def test_input_hash_change_marks_site_stale(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            site = Path(temporary)
            manifest = site / build_pages.BUILD_MANIFEST
            manifest.write_text(json.dumps({"inputs": {"a": "old"}}), encoding="utf-8")
            with mock.patch.object(build_pages, "SITE", site), mock.patch.object(
                build_pages, "input_hashes", return_value={"a": "new"}
            ):
                with self.assertRaisesRegex(build_pages.BuildError, "stale"):
                    build_pages.validate_site()


if __name__ == "__main__":
    unittest.main(verbosity=2)
