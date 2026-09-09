#!/usr/bin/env python3
"""Fetch the official tools for the Sparkle version in Package.resolved."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request

root = Path(__file__).resolve().parent.parent
lock = root / "Passtrami.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
version = next(p["state"]["version"] for p in json.loads(lock.read_text())["pins"] if p["identity"] == "sparkle")
name = f"Sparkle-{version}.tar.xz"
with urllib.request.urlopen(f"https://api.github.com/repos/sparkle-project/Sparkle/releases/tags/{version}", timeout=30) as response:
    release = json.load(response)
asset = next(a for a in release["assets"] if a["name"] == name)
digest = asset.get("digest", "")
if not digest.startswith("sha256:") or len(digest) != 71:
    raise SystemExit("Sparkle release has no SHA256 digest; cannot verify tools.")
expected_url = f"https://github.com/sparkle-project/Sparkle/releases/download/{version}/{name}"
if asset["browser_download_url"] != expected_url:
    raise SystemExit("Unexpected Sparkle tools download URL.")
destination = root / "build" / f"Sparkle-{version}"
marker = destination / ".verified-sha256"
if not marker.exists() or marker.read_text().strip() != digest:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="sparkle-tools-", dir=destination.parent) as temporary:
        archive = Path(temporary) / name
        with urllib.request.urlopen(expected_url, timeout=60) as response, archive.open("wb") as output:
            shutil.copyfileobj(response, output)
        if "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
            raise SystemExit("Sparkle tools checksum failed.")
        extracted = Path(temporary) / "extracted"
        extracted.mkdir()
        subprocess.run(["tar", "-xf", str(archive), "-C", str(extracted)], check=True)
        for tool in ("generate_appcast", "generate_keys", "sign_update"):
            if not (extracted / "bin" / tool).is_file():
                raise SystemExit(f"Sparkle tools archive is missing {tool}.")
        (extracted / ".verified-sha256").write_text(digest + "\n")
        if destination.exists():
            shutil.rmtree(destination)
        extracted.rename(destination)
print(destination / "bin")
