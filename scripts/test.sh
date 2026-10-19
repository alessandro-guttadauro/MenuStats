#!/bin/zsh
# Every automatic check: unit tests, the widget extension's live sampler, and the release version logic.
# Runs locally and in the release workflow before anything is published.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ Test unitari"
swift test 2>&1 | grep -E "error|failed|Executed .* tests" | tail -3
swift test >/dev/null 2>&1 || { echo "Test unitari falliti"; exit 1; }

echo "▸ Campionatore dei widget (compilato come l'estensione, per macOS 14)"
OUT=build/tests
mkdir -p "$OUT"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -target arm64-apple-macos14.0 -sdk "$SDK_PATH" -module-name WidgetSampler \
    Sources/MenuStatsWidgetUI/*.swift Sources/MenuStatsWidgets/LiveSampler.swift Tests/WidgetSampler/main.swift \
    -framework SwiftUI -framework IOKit -o "$OUT/widget-sampler"
# The sampler compares with this Mac's battery and disks; on CI runners only the build is checked.
if [[ -z ${CI:-} ]]; then "$OUT/widget-sampler"; fi

echo "▸ Estensione dei widget (come in build-app.sh)"
xcrun swiftc -O -target arm64-apple-macos14.0 -sdk "$SDK_PATH" -parse-as-library -application-extension \
    -module-name MenuStatsWidgets Sources/MenuStatsWidgetUI/*.swift Sources/MenuStatsWidgets/*.swift \
    -framework WidgetKit -framework SwiftUI -framework IOKit \
    -Xlinker -e -Xlinker _NSExtensionMain -o "$OUT/MenuStatsWidgets"
echo "  ✓ compilata"

echo "▸ Versione delle release"
REPO=$(mktemp -d)
NEXT="$PWD/scripts/next-version.sh"
(
    cd "$REPO"
    git init -q && git config user.email t@t && git config user.name t
    commit() { mkdir -p "$(dirname "$1")"; echo $RANDOM >> "$1"; git add -A; git commit -qm "$2"; }
    expect() { local got=$("$NEXT"); [[ $got == "$1" ]] && echo "  ✓ $2 → $got" || { echo "  ✗ $2: atteso $1, ottenuto $got"; exit 1; } }
    commit Sources/a.swift "primo"; git tag v1.2.0
    expect skip "HEAD già rilasciato"
    commit README.md "solo documentazione"
    expect skip "solo documentazione"
    commit Sources/a.swift "correzione"
    expect 1.2.1 "correzione (patch)"
    commit Sources/b.swift "nuovo modulo [minor]"
    expect 1.3.0 "funzione nuova [minor]"
    commit Sources/c.swift "rifatto tutto [major]"
    expect 2.0.0 "[major]"
    git tag v2.0.0; commit Sources/a.swift "prova [skip release]"
    expect skip "[skip release]"
)
rm -rf "$REPO"
echo "Tutti i test superati"
