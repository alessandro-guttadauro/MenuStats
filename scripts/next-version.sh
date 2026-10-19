#!/bin/zsh
# Prints the next release version (or "skip") for the commits since the last v* tag, and writes the release
# notes to the file given as $1. Used by .github/workflows/release.yml and tested by scripts/test.sh.
#   - patch by default, [minor] / [major] in a commit message bumps those;
#   - "skip" when HEAD is already tagged, a commit says [skip release], or only documentation changed.
set -euo pipefail
NOTES="${1:-/dev/null}"
LAST=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo v0.0.0)
if git tag --points-at HEAD | grep -q '^v[0-9]'; then echo skip; exit 0; fi
RANGE="$LAST..HEAD"; [[ $LAST == v0.0.0 ]] && RANGE=HEAD
MESSAGES=$(git log --format=%B "$RANGE")
if print -r -- "$MESSAGES" | grep -qF '[skip release]'; then echo skip; exit 0; fi
if [[ -z $(git log --format=%H "$RANGE" -- Sources Resources scripts Package.swift .github) ]]; then echo skip; exit 0; fi
IFS=. read -r MAJOR MINOR PATCH <<< "${LAST#v}"
if print -r -- "$MESSAGES" | grep -qF '[major]'; then MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0
elif print -r -- "$MESSAGES" | grep -qF '[minor]'; then MINOR=$((MINOR + 1)); PATCH=0
else PATCH=$((PATCH + 1)); fi
VERSION="$MAJOR.$MINOR.$PATCH"
{
    echo "## Novità"
    git log --no-merges --format='- %s' "$RANGE" | sed -E 's/ ?\[(minor|major)\]//g'
    echo
    echo "## Installazione"
    echo "Se hai già MenuStats 1.3.0 o successivo, l'aggiornamento compare da solo nella barra dei menu: un clic e si installa."
    echo "Altrimenti scarica \`MenuStats-$VERSION.zip\`, estrai e sostituisci \`MenuStats.app\`; al primo avvio clic destro ▸ **Apri** (app non notarizzata)."
    echo
    echo "Requisiti: Mac con Apple Silicon, macOS 13 o successivo (macOS 14 per i widget)."
} > "$NOTES"
echo "$VERSION"
