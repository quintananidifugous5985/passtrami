#!/bin/zsh
set -euo pipefail
project_root=${0:A:h:h:h}
cd "$project_root"
test_directory=$(mktemp -d "${TMPDIR:-/tmp/}passtrami-engine-process-tests.XXXXXX")
trap 'if [[ -f "$test_directory/Fixture.app/Contents/Resources/held-writer-pid" ]]; then kill -KILL "$(cat "$test_directory/Fixture.app/Contents/Resources/held-writer-pid")" 2>/dev/null || true; fi; rm -rf "$test_directory"' EXIT
fixture="$test_directory/Fixture.app/Contents"
mkdir -p "$fixture/MacOS" "$fixture/Resources"
cat > "$fixture/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.zats.Passtrami.EngineProcessTests</string>
<key>CFBundleExecutable</key><string>tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun clang -Wall -Wextra -Werror Tests/EngineProcess/fixture.c -o "$fixture/Resources/passtrami-engine"
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macos26.2 App/BrowserRuntimeStatus.swift App/MCPSettings.swift \
  App/EngineProcess.swift Tests/EngineProcess/main.swift -o "$fixture/MacOS/tests"
"$fixture/MacOS/tests"
