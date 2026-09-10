#!/usr/bin/env python3
"""Run release tools from Sparkle's pinned and verified SwiftPM archive."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request

TOOLS = {"generate_appcast", "generate_keys", "sign_update"}
REPOSITORY = "https://github.com/sparkle-project/Sparkle"
# Update these values together with Package.resolved. Checksum source:
# https://raw.githubusercontent.com/sparkle-project/Sparkle/ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a/Package.swift
VERSION = "2.9.6"
REVISION = "ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a"
CHECKSUM = "8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606"


def pinned_artifact(root):
    lock = root / "Passtrami.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    pins = [pin for pin in json.loads(lock.read_text())["pins"] if pin["identity"] == "sparkle"]
    if (len(pins) != 1 or pins[0]["location"] != REPOSITORY
            or pins[0]["state"]["version"] != VERSION
            or pins[0]["state"]["revision"] != REVISION):
        raise SystemExit("Package.resolved must match the Sparkle tools pin in scripts/sparkle-tools.py.")
    url = f"{REPOSITORY}/releases/download/{VERSION}/Sparkle-for-Swift-Package-Manager.zip"
    return REVISION, url, CHECKSUM


def run_tool(root, tool, arguments):
    if tool not in TOOLS:
        raise SystemExit("Use generate_appcast, generate_keys, or sign_update.")
    revision, url, checksum = pinned_artifact(root)
    cache = root / "build/SparkleTools" / (revision + ".zip")
    cache.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="run-", dir=cache.parent) as temporary:
        temporary = Path(temporary)
        archive = temporary / "Sparkle.zip"
        cached = cache.exists()
        if cached:
            shutil.copyfile(cache, archive)
        else:
            with urllib.request.urlopen(url, timeout=60) as response, archive.open("wb") as output:
                shutil.copyfileobj(response, output)
        digest = hashlib.sha256()
        with archive.open("rb") as source:
            for chunk in iter(lambda: source.read(1_048_576), b""):
                digest.update(chunk)
        if digest.hexdigest() != checksum:
            raise SystemExit("Sparkle tools checksum failed; no release tool was run.")
        if not cached:
            verified = temporary / "verified.zip"
            shutil.copyfile(archive, verified)
            verified.replace(cache)
        extracted = temporary / "extracted"
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(extracted)], check=True)
        for name in TOOLS:
            executable = extracted / "bin" / name
            if not executable.is_file() or executable.is_symlink():
                raise SystemExit(f"The verified Sparkle archive is missing {name}.")
        return subprocess.run([str(extracted / "bin" / tool), *arguments]).returncode


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("Usage: sparkle-tools.py TOOL [ARGUMENTS...]")
    raise SystemExit(run_tool(Path(__file__).resolve().parent.parent, sys.argv[1], sys.argv[2:]))
