#!/bin/bash
# Removes Fieldnote Companion.
#   curl -fsSL https://fieldnote-record.github.io/companion/uninstall.sh | bash
set -uo pipefail
LABEL="io.github.fieldnote-record.companion"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -x FieldnoteCompanion 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Fieldnote Companion.app"
defaults delete "$LABEL" 2>/dev/null
echo "Fieldnote Companion has been removed."
