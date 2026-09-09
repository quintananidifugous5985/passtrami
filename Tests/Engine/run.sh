#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h:h}"
test_dir=$(mktemp -d "${TMPDIR:-/tmp/}passtrami-engine-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
sources=(EngineHost/**/*.swift)
sources=(${sources:#EngineHost/main.swift})
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macos26.2 -framework JavaScriptCore -framework Network \
  "${sources[@]}" Tests/Engine/*.swift -o "$test_dir/tests"
"$test_dir/tests"
