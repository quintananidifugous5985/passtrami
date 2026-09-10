#!/bin/zsh
set -euo pipefail
project_root=${0:A:h:h}
cd "$project_root"
if (( $# != 2 )); then
  print -u2 'Usage: SIGNING_IDENTITY="Developer ID Application: ..." TEAM_ID=... ./scripts/prepare-release.sh NOTES.md NOTARY_PROFILE'
  exit 64
fi
: ${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity.}
: ${TEAM_ID:?Set TEAM_ID to your Apple Developer team ID.}
notes=${1:A}
notary_profile=$2
[[ -s "$notes" ]] || { print -u2 'Release notes must be a nonempty file.'; exit 65; }
[[ -z $(git status --porcelain) ]] || { print -u2 'Commit all source changes before preparing a release.'; exit 65; }
repository=zats/passtrami
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Info.plist)
feed_url=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Info.plist)
public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Info.plist)
[[ "$feed_url" == "https://zats.io/passtrami/appcast.xml" ]] || { print -u2 'Unexpected update feed URL.'; exit 65; }
tag="v${version}b${build_number}"
[[ "$tag" =~ '^v[0-9]+(\.[0-9]+)*b[0-9]+$' ]] || { print -u2 'Invalid version or build number.'; exit 65; }
output="$project_root/build/Distribution/$tag"
[[ ! -e "$output" ]] || { print -u2 "Release output already exists: $output"; exit 73; }
tools=$(python3 scripts/sparkle-tools.py)
[[ $("$tools/generate_keys" --account "$bundle_id" -p) == "$public_key" ]] || { print -u2 'Sparkle public key does not match the signing account.'; exit 65; }
python3 scripts/prepare-extension.py
Tests/Engine/run.sh
Tests/CLI/run.sh
Tests/App/run.sh
Tests/MCP/run.sh
mkdir -p "$project_root/build/Distribution"
work=$(mktemp -d "$project_root/build/Distribution/.prepare.XXXXXX")
trap 'rm -rf "$work"' EXIT
xcodebuild -quiet -project Passtrami.xcodeproj -scheme Passtrami \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$project_root/build/Distribution/DerivedData" \
  -clonedSourcePackagesDirPath "$project_root/build/SourcePackages" \
  -archivePath "$work/Passtrami.xcarchive" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" ENABLE_HARDENED_RUNTIME=YES archive
python3 - "$work/export.plist" "$SIGNING_IDENTITY" "$TEAM_ID" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({'method': 'developer-id', 'signingStyle': 'manual',
                  'signingCertificate': sys.argv[2], 'teamID': sys.argv[3]}, output)
PY
xcodebuild -quiet -exportArchive -archivePath "$work/Passtrami.xcarchive" \
  -exportPath "$work/export" -exportOptionsPlist "$work/export.plist"
app="$work/export/Passtrami.app"
requirement="=anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
codesign --verify --deep --strict -R "$requirement" "$app"
codesign --verify --strict -R "$requirement" "$app/Contents/Helpers/passtrami"
for helper in passtrami-engine passtrami-mcp; do
  codesign --verify --strict -R "$requirement" "$app/Contents/Resources/$helper"
done
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/notarization.zip"
xcrun notarytool submit "$work/notarization.zip" --keychain-profile "$notary_profile" \
  --wait --output-format json > "$work/notarization.json"
python3 - "$work/notarization.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization was not accepted: ' + str(result.get('id', 'no submission ID')))
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict -R "$requirement" "$app"
spctl --assess --type execute --verbose=2 "$app"
assets="$work/assets"
mkdir "$assets"
archive_name="Passtrami-${version}-b${build_number}-macOS-arm64.zip"
archive="$assets/$archive_name"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
cp "$notes" "$assets/${archive_name:r}.md"
"$tools/generate_appcast" --account "$bundle_id" --maximum-deltas 0 --maximum-versions 1 \
  --embed-release-notes --download-url-prefix "https://github.com/$repository/releases/download/$tag/" \
  --link "https://github.com/$repository" -o "$assets/appcast.xml" "$assets"
signature=$(python3 scripts/validate-appcast.py "$assets/appcast.xml" "$repository" "$tag" "$archive_name" "$(stat -f %z "$archive")")
"$tools/sign_update" --account "$bundle_id" --verify "$archive" "$signature"
rm "$assets/${archive_name:r}.md"
(cd "$assets" && shasum -a 256 "$archive_name" > "$archive_name.sha256")
cp "$archive" "$assets/Passtrami.zip"
ditto "$app" "$assets/Passtrami.app"
cp "$work/notarization.json" "$assets/notarization.json"
git rev-parse HEAD > "$assets/source-commit.txt"
mv "$assets" "$output"
print "Prepared $tag at $output"
print 'No release has been published. Follow docs/releasing.md to publish the verified assets.'
