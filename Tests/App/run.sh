#!/bin/zsh
set -euo pipefail
project_root=${0:A:h:h:h}
cd "$project_root"
test_directory=$(mktemp -d "${TMPDIR:-/tmp/}aster-app-tests.XXXXXX")
trap 'rm -rf "$test_directory"' EXIT
minimum_macos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target "arm64-apple-macos$minimum_macos" \
  App/Settings/CLIInstaller.swift App/Bundle+DisplayName.swift App/MCPSettings.swift Tests/App/main.swift \
  -o "$test_directory/tests"
"$test_directory/tests"
