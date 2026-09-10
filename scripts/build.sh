#!/bin/zsh
set -euo pipefail
project_root=${0:A:h:h}
cd "$project_root"
configuration=${1:-debug}
case "$configuration" in
  debug)
    output_dir="$project_root/build"
    xcode_configuration=Debug
    ;;
  release)
    output_dir="$project_root/build/Release"
    xcode_configuration=Release
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
app="$output_dir/Passtrami.app"
python3 scripts/prepare-extension.py
Tests/Engine/run.sh
Tests/Companion/run.sh
Tests/PreferenceWindow/run.sh
Tests/CLI/run.sh
Tests/App/run.sh
Tests/MCP/run.sh
xcodebuild -quiet -project Passtrami.xcodeproj -scheme Passtrami \
  -configuration "$xcode_configuration" -derivedDataPath "$project_root/build/Xcode" \
  -clonedSourcePackagesDirPath "$project_root/build/SourcePackages" \
  -destination 'platform=macOS,arch=arm64' build
# Publish only a completed build; keep the previous app if compilation fails.
rm -rf "$app"
mkdir -p "$output_dir"
ditto "$project_root/build/Xcode/Build/Products/$xcode_configuration/Passtrami.app" "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
if [[ "$configuration" == release ]]; then
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
  archive="$output_dir/Passtrami-$version-macOS-arm64.zip"
  rm -f "$archive"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
  (cd "$output_dir" && shasum -a 256 "${archive:t}" > "${archive:t}.sha256")
  printf '%s\n' "$archive"
fi
