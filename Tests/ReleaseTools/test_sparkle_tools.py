#!/usr/bin/env python3
"""Exercise the production tool runner with trusted test pins and harmless ZIP fixtures."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import zlib

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("sparkle_tools", Path(__file__).resolve().parents[2] / "scripts/sparkle-tools.py")
tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tools)


def fixture_archive(names=tools.TOOLS):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        for name in sorted(names):
            entry = zipfile.ZipInfo("bin/" + name)
            entry.create_system = 3
            entry.external_attr = 0o100755 << 16
            archive.writestr(entry, '#!/bin/sh\nprintf "%s\\n" "$0" >> "$1"\n')
    return output.getvalue()


class SparkleToolsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="passtrami-tools-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.lock = self.root / "Passtrami.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        self.lock.parent.mkdir(parents=True)
        self.log = self.root / "tool runs.txt"
        self.archive = fixture_archive()
        checksum = patch.object(tools, "CHECKSUM", hashlib.sha256(self.archive).hexdigest())
        checksum.start()
        self.addCleanup(checksum.stop)
        self.lock.write_text(json.dumps({"pins": [{"identity": "sparkle", "location": tools.REPOSITORY,
            "state": {"version": tools.VERSION, "revision": tools.REVISION}}]}))
        self.cache = self.root / "build/SparkleTools" / (tools.REVISION + ".zip")

    def run_tool(self, name="generate_keys", archive=None):
        data = self.archive if archive is None else archive
        with patch.object(tools.urllib.request, "urlopen", return_value=io.BytesIO(data)) as download:
            result = tools.run_tool(self.root, name, [str(self.log)])
        return result, download

    def assert_no_temporary_tools(self):
        self.assertFalse(list((self.root / "build/SparkleTools").glob("run-*")))

    def test_verified_archive_reused_but_executables_are_always_fresh(self):
        result, download = self.run_tool()
        self.assertEqual(result, 0)
        download.assert_called_once_with(tools.REPOSITORY +
            f"/releases/download/{tools.VERSION}/Sparkle-for-Swift-Package-Manager.zip", timeout=60)
        with patch.object(tools.urllib.request, "urlopen", side_effect=AssertionError("Unexpected download")):
            self.assertEqual(tools.run_tool(self.root, "sign_update", [str(self.log)]), 0)
        paths = self.log.read_text().splitlines()
        self.assertEqual(len(paths), 2)
        self.assertNotEqual(Path(paths[0]).parents[1], Path(paths[1]).parents[1])
        self.assertTrue(all(not Path(path).exists() for path in paths))
        self.assertEqual(self.cache.read_bytes(), self.archive)
        self.assert_no_temporary_tools()

    def test_replaced_download_never_executes(self):
        with self.assertRaisesRegex(SystemExit, "checksum failed"):
            self.run_tool(archive=b"replaced upstream asset")
        self.assertFalse(self.log.exists())
        self.assertFalse(self.cache.exists())
        self.assert_no_temporary_tools()

    def test_modified_cached_archive_is_rechecked_before_execution(self):
        self.run_tool()
        self.cache.write_bytes(b"modified local archive")
        with patch.object(tools.urllib.request, "urlopen", side_effect=AssertionError("Unexpected download")):
            with self.assertRaisesRegex(SystemExit, "checksum failed"):
                tools.run_tool(self.root, "generate_keys", [str(self.log)])
        self.assertEqual(len(self.log.read_text().splitlines()), 1)
        self.assert_no_temporary_tools()

    def test_poisoned_checkout_and_matching_bad_zip_cannot_replace_source_pin(self):
        bad_archive = self.archive + b"modified upstream archive"
        manifest = (f'let version = "{tools.VERSION}"\n'
                    f'let checksum = "{hashlib.sha256(bad_archive).hexdigest()}"\n').encode()
        checkout = self.root / "build/SourcePackages/checkouts/Sparkle"
        objects = checkout / ".git/objects"
        # Simulate a replaced loose object whose contents do not match its name.
        poisoned_object = objects / "00" / ("0" * 38)
        poisoned_object.parent.mkdir(parents=True)
        poisoned_object.write_bytes(zlib.compress(b"blob " + str(len(manifest)).encode() + b"\0" + manifest))
        (checkout / "Package.swift").write_bytes(manifest)
        self.cache.parent.mkdir(parents=True)
        self.cache.write_bytes(bad_archive)
        with patch.object(tools.subprocess, "run") as subprocess_run:
            with patch.object(tools.urllib.request, "urlopen", side_effect=AssertionError("Unexpected download")):
                with self.assertRaisesRegex(SystemExit, "checksum failed"):
                    tools.run_tool(self.root, "generate_keys", [str(self.log)])
            subprocess_run.assert_not_called()
        self.assertFalse(self.log.exists())
        self.assert_no_temporary_tools()

    def test_package_repository_version_and_revision_must_match_source_pin(self):
        for field, changed in [("location", "https://example.invalid/Sparkle"),
                               ("version", "2.9.7"), ("revision", "0" * 40)]:
            with self.subTest(field=field):
                pin = {"identity": "sparkle", "location": tools.REPOSITORY,
                       "state": {"version": tools.VERSION, "revision": tools.REVISION}}
                (pin if field == "location" else pin["state"])[field] = changed
                self.lock.write_text(json.dumps({"pins": [pin]}))
                with patch.object(tools.urllib.request, "urlopen", side_effect=AssertionError("Unexpected download")):
                    with patch.object(tools.subprocess, "run") as subprocess_run:
                        with self.assertRaisesRegex(SystemExit, "must match the Sparkle tools pin"):
                            tools.run_tool(self.root, "generate_keys", [str(self.log)])
                        subprocess_run.assert_not_called()
                self.assertFalse(self.log.exists())
                self.assertFalse(self.cache.exists())

    def test_verified_archive_missing_a_tool_does_not_execute(self):
        missing = fixture_archive({"generate_keys"})
        with patch.object(tools, "CHECKSUM", hashlib.sha256(missing).hexdigest()):
            with self.assertRaisesRegex(SystemExit, "missing"):
                self.run_tool(archive=missing)
        self.assertFalse(self.log.exists())
        self.assert_no_temporary_tools()

    def test_unknown_tool_is_rejected(self):
        with self.assertRaisesRegex(SystemExit, "Use generate_appcast"):
            self.run_tool(name="sh")
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
