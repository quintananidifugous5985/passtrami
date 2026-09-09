#!/bin/zsh
set -euo pipefail
project_root=${0:A:h:h}
cd "$project_root"
minimum_macos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)
configuration=${1:-debug}
swift_flags=()
case "$configuration" in
  debug)
    output_dir="$project_root/build"
    ;;
  release)
    output_dir="$project_root/build/Release"
    swift_flags=(-O -whole-module-optimization)
    ;;
  *)
    printf 'Usage: %s [debug|release]\n' "$0" >&2
    exit 64
    ;;
esac
if (( $# > 1 )); then
  printf 'Usage: %s [debug|release]\n' "$0" >&2
  exit 64
fi
app="$output_dir/Aster.app"
# Recreate only the build output so obsolete executable paths cannot remain.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
Tests/Engine/run.sh
Tests/CLI/run.sh
Tests/App/run.sh
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  "${swift_flags[@]}" -target "arm64-apple-macos$minimum_macos" -framework JavaScriptCore -framework Network \
  Sources/Engine/*.swift -o "$app/Contents/Resources/aster-engine"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  "${swift_flags[@]}" -target "arm64-apple-macos$minimum_macos" -framework AppKit Sources/App/*.swift -o "$app/Contents/MacOS/Aster"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  "${swift_flags[@]}" -target "arm64-apple-macos$minimum_macos" Sources/CLI/main.swift -o "$app/Contents/Helpers/aster"
cp Info.plist "$app/Contents/Info.plist"
rsync -a --delete Resources/ "$app/Contents/Resources/" --exclude aster-engine --exclude .DS_Store
mkdir -p "$app/Contents/Resources/Engine"
cp Engine/*.js "$app/Contents/Resources/Engine/"
(
  icon_info=$(mktemp "${TMPDIR:-/tmp/}aster-icon.XXXXXX")
  trap 'rm -f "$icon_info"' EXIT
  xcrun actool Assets/AppIcon.icon --compile "$app/Contents/Resources" \
    --platform macosx --minimum-deployment-target "$minimum_macos" --target-device mac \
    --app-icon AppIcon --output-partial-info-plist "$icon_info" --output-format human-readable-text
  /usr/libexec/PlistBuddy -c "Merge \"$icon_info\"" "$app/Contents/Info.plist"
)
mkdir -p "$app/Contents/Resources/Notices"
cp LICENSE "$app/Contents/Resources/Notices/Aster-GPL-3.0.txt"
cp Vendor/APW/README.md "$app/Contents/Resources/Notices/APW.md"
codesign --force --sign - "$app/Contents/Helpers/aster"
codesign --force --sign - "$app/Contents/Resources/aster-engine"
# Sign only Aster-owned executables.
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
if [[ "$configuration" == release ]]; then
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
  archive="$output_dir/Aster-$version-macOS-arm64.zip"
  rm -f "$archive"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
  (cd "$output_dir" && shasum -a 256 "${archive:t}" > "${archive:t}.sha256")
  printf '%s\n' "$archive"
fi
