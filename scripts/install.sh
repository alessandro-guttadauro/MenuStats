#!/bin/zsh
# Builds MenuStats.app, installs it in ~/Applications (a stable path for "Open at login") and relaunches it.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh
DEST="$HOME/Applications/MenuStats.app"
mkdir -p "$HOME/Applications"

# A changed helper comes under a new name (see build-app.sh): the installed app unregisters its own helper first,
# the new one registers its own, as the in-app updater does. No new approval is needed.
label() { /usr/libexec/PlistBuddy -c "Print :MSHelperLabel" "$1/Contents/Info.plist" 2>/dev/null || echo local.menustats.helper; }
NEW_LABEL=$(label build/MenuStats.app)
OLD_LABEL=$(label "$DEST")
HELPER_WAS_INSTALLED=0
[[ "$OLD_LABEL" != "$NEW_LABEL" ]] && launchctl print "system/$OLD_LABEL" >/dev/null 2>&1 && HELPER_WAS_INSTALLED=1
pkill -x MenuStats 2>/dev/null && sleep 1 || true
[[ $HELPER_WAS_INSTALLED == 1 ]] && "$DEST/Contents/MacOS/MenuStats" --uninstall-helper >/dev/null
# Update the bundle in place: deleting and recreating it would invalidate the privileged helper's
# Background Task Management entry (launchd then fails with "copy_bundle_path … error 0x6f").
rsync -a --delete build/MenuStats.app/ "$DEST/"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$DEST"
if [[ $HELPER_WAS_INSTALLED == 1 ]]; then
    "$DEST/Contents/MacOS/MenuStats" --install-helper >/dev/null
    sleep 3
    if launchctl print "system/$NEW_LABEL" 2>/dev/null | grep -q "state = running"; then
        echo "Helper aggiornato ($NEW_LABEL)"
    else
        echo "Attenzione: helper non avviato, reinstallalo da Impostazioni ▸ Ventole"
    fi
fi
open "$DEST"
echo "Installato e avviato $DEST"
