#!/bin/zsh
set -euo pipefail
project_root=${0:A:h:h:h}
cd "$project_root"
xcodebuild -quiet -project Aster.xcodeproj -scheme AsterMCPTests -configuration Debug \
  -derivedDataPath "$project_root/build/XcodeMCP" \
  -clonedSourcePackagesDirPath "$project_root/build/SourcePackages" \
  -destination 'platform=macOS,arch=arm64' build
python3 Tests/MCP/test_protocol.py "$project_root/build/XcodeMCP/Build/Products/Debug/aster-mcp-tests"
