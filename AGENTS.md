# Istruzioni per agenti IA

Queste regole valgono per qualsiasi assistente IA (Claude Code, Codex, Copilot, Cursor…) che lavora su questo repository.

## Regola: una release dopo ogni commit su `main`

Ogni volta che un commit arriva su `main` (push diretto o merge di una pull request) e cambia l'app, pubblica subito una nuova release GitHub. Chi scarica lo zip deve avere sempre il codice dell'ultimo commit.

- Conta come cambiamento all'app qualsiasi modifica a `Sources/`, `Resources/`, `scripts/` o `Package.swift`.
- I commit che toccano solo documentazione (`README.md`, `docs/`, questo file) non richiedono una release: lo zip sarebbe identico. Finiscono nella release successiva.
- Non lasciare mai `main` avanti all'ultima release con codice non rilasciato. Prima di chiudere il lavoro controlla:

  ```bash
  git fetch --tags && git log --oneline "$(git describe --tags --abbrev=0)"..origin/main -- Sources Resources scripts Package.swift
  ```

  Se l'output non è vuoto, manca una release.

## Che numero di versione usare

Versioni `vMAJOR.MINOR.PATCH`, partendo dall'ultimo tag (`git describe --tags --abbrev=0`):

- **PATCH** (`v1.2.0` → `v1.2.1`): correzioni, piccoli ritocchi, miglioramenti a funzioni esistenti.
- **MINOR** (`v1.2.1` → `v1.3.0`): un modulo, una scheda o un'impostazione nuova.
- **MAJOR**: solo se lo chiede il maintainer.

La versione dell'app viene dal tag: `scripts/build-app.sh` la legge con `git describe`. Non va scritta in nessun file.

## Come fare la release

Lavora da un checkout pulito di `main` aggiornato, con Xcode 26 o successivo.

```bash
git checkout main && git pull --ff-only
V=1.2.1                                    # nuova versione, senza la "v"
swift build                                # deve compilare senza avvisi
git tag -a "v$V" -m "MenuStats $V"
git push origin "v$V"
VERSION="$V" ./scripts/build-app.sh        # crea build/MenuStats.app
ditto -c -k --keepParent build/MenuStats.app "build/MenuStats-$V.zip"
shasum -a 256 "build/MenuStats-$V.zip"
gh release create "v$V" "build/MenuStats-$V.zip" --title "MenuStats $V" --notes-file build/notes.md --verify-tag
```

Lo zip deve contenere `MenuStats.app/` alla radice (per questo serve `--keepParent`).

## Note di rilascio

In italiano, nello stesso stile delle release precedenti (`gh release view v1.2.0`). Scrivile in `build/notes.md`, che non viene committato:

```markdown
## Novità
- **Titolo breve** (di @autore, [#N](https://github.com/thomas-addamo/MenuStats/pull/N)): cosa cambia per chi usa l'app.

## Correzioni
- Cosa non funzionava e ora funziona.

## Installazione
Scarica `MenuStats-X.Y.Z.zip`, estrai e sostituisci `MenuStats.app`; al primo avvio clic destro ▸ **Apri** (app non notarizzata). Se usi il controllo ventole, dopo l'aggiornamento potrebbe servire riapprovare MenuStats in Impostazioni di Sistema ▸ Generali ▸ Elementi login.

Requisiti: Mac con Apple Silicon, macOS 13 o successivo.

SHA-256 di `MenuStats-X.Y.Z.zip`: `…`
```

- Descrivi i cambiamenti dal punto di vista di chi usa l'app, non del codice.
- Cita autore e pull request per i contributi esterni e ringrazia in fondo.
- Ometti le sezioni vuote (per esempio niente "Correzioni" se non ce ne sono).
- Indica sempre lo SHA-256 dello zip pubblicato.

## Se non hai i permessi

Se l'account con cui lavori non può fare push di tag o creare release su `thomas-addamo/MenuStats`, non pubblicare release su un fork al posto dell'originale. Scrivi le note di rilascio pronte (versione, testo, comandi) nella descrizione della pull request, così il maintainer pubblica la release subito dopo il merge.
