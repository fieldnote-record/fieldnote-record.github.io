#!/bin/bash
# Builds "Fieldnote Companion.app" (Apple silicon + Intel) and zips it for the installer.
set -euo pipefail
cd "$(dirname "$0")"
BUILD=$(mktemp -d)
APP="$BUILD/Fieldnote Companion.app"
mkdir -p "$APP/Contents/MacOS"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos12.0" source/main.swift -o "$BUILD/FieldnoteCompanion-$arch"
done
lipo -create "$BUILD"/FieldnoteCompanion-arm64 "$BUILD"/FieldnoteCompanion-x86_64 -output "$APP/Contents/MacOS/FieldnoteCompanion"
cp source/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
rm -f FieldnoteCompanion.zip
ditto -c -k --keepParent "$APP" FieldnoteCompanion.zip
echo "Built companion/FieldnoteCompanion.zip ($(du -h FieldnoteCompanion.zip | cut -f1))"
