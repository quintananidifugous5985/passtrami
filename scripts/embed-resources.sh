#!/bin/zsh
set -euo pipefail
cd "$SRCROOT"
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$resources/Engine" "$resources/Notices"
# Preserve Apple's extension layout; compile only the native targets in Xcode.
rsync -a Resources/ "$resources/" --exclude .DS_Store
cp Engine/*.js "$resources/Engine/"
cp LICENSE "$resources/Notices/Aster-GPL-3.0.txt"
cp Vendor/APW/README.md "$resources/Notices/APW.md"
