#!/bin/bash
# Installs Fieldnote Companion, the menu bar app for fieldnote-record.github.io.
#   curl -fsSL https://fieldnote-record.github.io/companion/install.sh | bash
set -euo pipefail

BASE="https://fieldnote-record.github.io/companion"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/Fieldnote Companion.app"
LABEL="io.github.fieldnote-record.companion"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "$(uname)" != "Darwin" ]; then echo "Fieldnote Companion only runs on macOS."; exit 1; fi

echo "Downloading Fieldnote Companion…"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$BASE/FieldnoteCompanion.zip" -o "$TMP/app.zip"

echo "Installing to ~/Applications…"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x FieldnoteCompanion 2>/dev/null || true
mkdir -p "$APP_DIR" "$HOME/Library/LaunchAgents"
rm -rf "$APP"
ditto -x -k "$TMP/app.zip" "$APP_DIR"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# Start now and at every login.
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/FieldnoteCompanion</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo ""
echo "Fieldnote Companion is running. Look for the record icon in your menu bar."
echo "Click it to see your pairing code, then enter the code on https://fieldnote-record.github.io"
echo ""
echo "To remove it later:"
echo "  curl -fsSL $BASE/uninstall.sh | bash"
