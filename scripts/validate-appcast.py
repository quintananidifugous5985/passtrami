#!/usr/bin/env python3
"""Check the feed against a single immutable GitHub release asset."""
import base64
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

if len(sys.argv) != 6:
    raise SystemExit("Usage: validate-appcast.py APPCAST REPOSITORY TAG ZIP_NAME ZIP_BYTES")
feed, repository, tag, filename, size = sys.argv[1:]
match = re.fullmatch(r"v([0-9]+(?:\.[0-9]+)*)b([0-9]+)", tag)
if not match:
    raise SystemExit("Release tag must be vVERSIONbBUILD.")
namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(Path(feed)).getroot().findall("./channel/item")
if len(items) != 1:
    raise SystemExit("The feed must contain exactly one stable release.")
item = items[0]
if item.findtext(namespace + "version") != match[2] or item.findtext(namespace + "shortVersionString") != match[1]:
    raise SystemExit("Feed version does not match the release tag.")
if item.find(namespace + "channel") is not None:
    raise SystemExit("The stable feed cannot contain a prerelease channel.")
enclosures = item.findall("enclosure")
if len(enclosures) != 1:
    raise SystemExit("The release must have one full update archive.")
enclosure = enclosures[0]
url = f"https://github.com/{repository}/releases/download/{tag}/{filename}"
if enclosure.get("url") != url or enclosure.get("length") != size or int(size) <= 0:
    raise SystemExit("Feed URL or archive size does not match the release asset.")
signature = enclosure.get(namespace + "edSignature", "")
if len(base64.b64decode(signature, validate=True)) != 64:
    raise SystemExit("Feed has no valid Ed25519 signature value.")
# The release script verifies this signature with Sparkle. The installed app
# independently verifies it when it downloads the archive.
print(signature)
