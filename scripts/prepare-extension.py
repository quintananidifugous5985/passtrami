#!/usr/bin/env python3
"""Download the pinned Apple extension for local builds; never run from Xcode."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import stat
import struct
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile

VERSION = "3.3.0"
ARCHIVE_URL = (
    "https://clients2.googleusercontent.com/crx/blobs/"
    "Abe5cL4HiqnAe4qbFMo4VYFiaOo4wNqZj5qSORW-P7yohUSTldayamgGpuJq3uNrROpk4BTg2M6ybUiBo0tPvwB00yPxUdOzUTw4_n7utHw6xuPJK2IzVZzGo_kFXugPEVYAxlKa5WDo5gYaxqV8JTvRO3G-dWEEI1AM/"
    "PEJDIJMOENMKGEPPBFLOBDENHHABJLAJ_3_3_0_0.crx"
)
ARCHIVE_SHA256 = "3fefff3058e77877345d5d5c6ef6f1fb8c085ed2c1e4ecf76d16bf2fb64667b0"
# Sorted relative path + NUL + file SHA256 + newline, excluding Chrome's _metadata.
TREE_SHA256 = "9bc6c4259822e5f8883e3f7962f4584f2b5ee054124ac1a10d503d2252a780d8"
DEFAULT_DESTINATION = Path(__file__).resolve().parent.parent / "Resources" / "AppleExtension"


class SetupError(Exception):
    pass


def validate_extension(directory):
    if directory.is_symlink() or not directory.is_dir():
        raise SetupError("Apple's extension is missing. Run python3 scripts/prepare-extension.py before building.")
    for name in ("manifest.json", "background.js"):
        path = directory / name
        if path.is_symlink() or not path.is_file():
            raise SetupError("Apple's extension is incomplete. Move the directory aside, then run the setup command again.")
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("version") != VERSION:
        raise SetupError("Apple's extension has the wrong version; version 3.3.0 is required.")
    digest = hashlib.sha256()
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise SetupError("Apple's extension contains a symbolic link.")
        if path.is_dir():
            continue
        if not path.is_file():
            raise SetupError("Apple's extension contains an unsupported file.")
        relative = path.relative_to(directory).as_posix()
        digest.update(relative.encode("utf-8") + b"\0" + hashlib.sha256(path.read_bytes()).hexdigest().encode("ascii") + b"\n")
    if digest.hexdigest() != TREE_SHA256:
        raise SetupError("Apple's extension does not match the pinned files. Move the directory aside, then run the setup command again.")


def download_archive():
    with urllib.request.urlopen(ARCHIVE_URL, timeout=60) as response:
        data = response.read(10 * 1024 * 1024 + 1)
    if hashlib.sha256(data).hexdigest() != ARCHIVE_SHA256:
        raise SetupError("Apple's extension download failed its SHA256 check.")
    return data


def extract_archive(data, destination):
    if hashlib.sha256(data).hexdigest() != ARCHIVE_SHA256:
        raise SetupError("Apple's extension download failed its SHA256 check.")
    if len(data) < 12:
        raise SetupError("Apple's extension has an invalid CRX header.")
    magic, version, header_size = struct.unpack_from("<4sII", data)
    offset = 12 + header_size
    if magic != b"Cr24" or version != 3 or offset >= len(data):
        raise SetupError("Apple's extension has an invalid CRX3 header.")
    # CRX3 stores a little-endian header length followed by an ordinary ZIP.
    with zipfile.ZipFile(io.BytesIO(data[offset:])) as archive:
        for item in archive.infolist():
            path = PurePosixPath(item.filename)
            if path.is_absolute() or ".." in path.parts or stat.S_ISLNK(item.external_attr >> 16):
                raise SetupError("Apple's extension archive contains an unsafe path.")
            # These files belong to Chrome's installed-extension verifier, not an unpacked extension.
            if path.parts and path.parts[0] == "_metadata":
                continue
            archive.extract(item, destination)
    validate_extension(destination)


def prepare(destination, check_only=False):
    if destination.exists() or destination.is_symlink() or check_only:
        validate_extension(destination)
        return
    data = download_archive()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".passtrami-extension-", dir=destination.parent) as temporary:
        staging = Path(temporary) / "AppleExtension"
        staging.mkdir()
        extract_archive(data, staging)
        if destination.exists() or destination.is_symlink():
            raise SetupError("The extension destination appeared during setup. Run the check again.")
        os.rename(staging, destination)


def main():
    parser = argparse.ArgumentParser(description="Prepare Apple's pinned iCloud Passwords extension for a local build.")
    parser.add_argument("--check", action="store_true", help="Verify existing files without a network request.")
    parser.add_argument("--destination", type=Path, default=DEFAULT_DESTINATION, help="Extension directory (default: Resources/AppleExtension).")
    arguments = parser.parse_args()
    try:
        prepare(arguments.destination, check_only=arguments.check)
    except (SetupError, OSError, ValueError, urllib.error.URLError, zipfile.BadZipFile) as error:
        print("Extension setup failed: " + str(error), file=sys.stderr)
        return 1
    print("Apple's iCloud Passwords extension 3.3.0 is ready.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
