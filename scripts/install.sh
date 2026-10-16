#!/bin/zsh
# Builds MenuStats.app, installs it in ~/Applications (a stable path for "Open at login") and relaunches it.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh
DEST="$HOME/Applications/MenuStats.app"
mkdir -p "$HOME/Applications"

# Re-register the helper only when its binary changed: with ad hoc signing macOS may ask for approval again.
HELPER_CHANGED=1
cmp -s build/MenuStats.app/Contents/MacOS/MenuStatsHelper "$DEST/Contents/MacOS/MenuStatsHelper" 2>/dev/null && HELPER_CHANGED=0
pkill -x MenuStats 2>/dev/null && sleep 1 || true
# Update the bundle in place: deleting and recreating it would invalidate the privileged helper's
# Background Task Management entry (launchd then fails with "copy_bundle_path … error 0x6f").
rsync -a --delete build/MenuStats.app/ "$DEST/"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
HELPER_WAS_INSTALLED=0
[[ $HELPER_CHANGED == 1 ]] && launchctl print system/local.menustats.helper >/dev/null 2>&1 && HELPER_WAS_INSTALLED=1
"$LSREGISTER" -f "$DEST"
open "$DEST"

# A rebuilt helper has a new ad hoc code hash: register it again so launchd accepts the new binary
# (no new approval needed). Retried because Background Task Management sometimes keeps the stale entry.
if [[ $HELPER_WAS_INSTALLED == 1 ]]; then
    for attempt in 1 2 3; do
        sleep 2
        "$DEST/Contents/MacOS/MenuStats" --uninstall-helper >/dev/null
        sleep 5
        "$LSREGISTER" -f "$DEST"
        sleep 1
        "$DEST/Contents/MacOS/MenuStats" --install-helper >/dev/null
        sleep 4
        if launchctl print system/local.menustats.helper 2>/dev/null | grep -q "state = running"; then
            echo "Helper ventole aggiornato"
            break
        fi
        [[ $attempt == 3 ]] && echo "Attenzione: helper non avviato, reinstallalo da Impostazioni ▸ Ventole"
    done
fi
echo "Installato e avviato $DEST"
