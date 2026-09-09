#!/bin/zsh
set -euo pipefail
project_root=${0:A:h:h:h}
cd "$project_root"
test_directory=$(mktemp -d "${TMPDIR:-/tmp/}aster-cli-tests.XXXXXX")
trap 'rm -rf "$test_directory"' EXIT
minimum_macos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)
cat CLI/main.swift Tests/CLI/tests.swift > "$test_directory/main.swift"
xcrun swiftc -D ASTER_CLI_TEST -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target "arm64-apple-macos$minimum_macos" "$test_directory/main.swift" -o "$test_directory/tests"
"$test_directory/tests"
