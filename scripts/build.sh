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
app="$output_dir/Aster.app"
Tests/Engine/run.sh
Tests/CLI/run.sh
Tests/App/run.sh
xcodebuild -quiet -project Aster.xcodeproj -scheme Aster \
  -configuration "$xcode_configuration" -derivedDataPath "$project_root/build/Xcode" \
  -destination 'platform=macOS,arch=arm64' build
# Publish only a completed build; keep the previous app if compilation fails.
rm -rf "$app"
mkdir -p "$output_dir"
ditto "$project_root/build/Xcode/Build/Products/$xcode_configuration/Aster.app" "$app"
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
