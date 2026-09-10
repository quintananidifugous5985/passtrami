#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h:h}"
test_directory=$(mktemp -d "${TMPDIR:-/tmp/}passtrami-companion-tests.XXXXXX")
trap 'rm -rf "$test_directory"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macos26.2 Companion/CompanionModels.swift Companion/CompanionCloudStore.swift \
  Tests/Companion/main.swift \
  -o "$test_directory/tests"
"$test_directory/tests"
