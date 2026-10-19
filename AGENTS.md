# Istruzioni per agenti IA

Queste regole valgono per qualsiasi assistente IA (Claude Code, Codex, Copilot, Cursor…) che lavora su questo repository.

## Regola: una release dopo ogni commit su `main`

Ogni commit che arriva su `main` (push diretto o merge di una pull request) e cambia l'app deve diventare subito una release GitHub: chi scarica lo zip, e l'aggiornamento automatico dentro l'app, devono avere sempre il codice dell'ultimo commit.

**Lo fa GitHub Actions** (`.github/workflows/release.yml`): a ogni push su `main` compila l'app su macOS, crea il tag, pubblica `MenuStats-X.Y.Z.zip` con le note e lo SHA-256. Non serve pubblicare release a mano.

- Conta come cambiamento all'app qualsiasi modifica a `Sources/`, `Resources/`, `scripts/`, `Package.swift` o `.github/`.
- I commit che toccano solo documentazione (`README.md`, `docs/`, questo file) non creano una release: lo zip sarebbe identico. Finiscono nella release successiva.
- Dopo il push controlla che il workflow sia andato a buon fine (`gh run list --workflow Release --limit 1`). Se fallisce, correggi e fai un nuovo commit: non lasciare mai `main` avanti all'ultima release con codice non rilasciato.

## Che numero di versione usare

Versioni `vMAJOR.MINOR.PATCH`, partendo dall'ultimo tag. Il workflow alza la **PATCH** di serie; per il resto scrivilo nel messaggio di un commit:

- **PATCH** (`v1.2.0` → `v1.2.1`): correzioni, piccoli ritocchi, miglioramenti a funzioni esistenti. Nessun marcatore.
- **MINOR** (`v1.2.1` → `v1.3.0`): un modulo, una scheda o un'impostazione nuova. Scrivi `[minor]` nel messaggio.
- **MAJOR**: solo se lo chiede il maintainer. Scrivi `[major]`.
- `[skip release]` non pubblica nulla (usalo solo se il maintainer lo chiede).

La versione dell'app viene dal tag: `scripts/build-app.sh` la legge con `git describe` (o da `VERSION=`). Non va scritta in nessun file.

## Note di rilascio

Il workflow le compone dai messaggi dei commit dall'ultima release, aggiunge l'elenco delle pull request con gli autori e lo SHA-256 dello zip. Quindi:

- Scrivi messaggi di commit in italiano, dal punto di vista di chi usa l'app, non del codice.
- Il titolo del commit diventa una voce di "Novità": breve e chiaro.
- Se vuoi note più curate, modificale dopo con `gh release edit vX.Y.Z --notes-file …` nello stesso stile delle precedenti (`gh release view v1.2.0`).

## Aggiornamento automatico nell'app

MenuStats controlla `releases/latest` ogni 6 ore e offre l'aggiornamento con un'icona nella barra dei menu. Perché funzioni:

- La release deve avere **un solo zip** con `MenuStats.app/` alla radice (il workflow usa `ditto --keepParent`).
- La versione dentro l'app (`CFBundleShortVersionString`) deve essere più alta di quella installata, e il bundle id deve restare `local.menustats`.
- Non pubblicare release come *prerelease* o *draft* se devono arrivare agli utenti.

## Se non hai i permessi

Se l'account con cui lavori non può fare push su `thomas-addamo/MenuStats`, apri una pull request: al merge il workflow pubblica la release. Non pubblicare release su un fork al posto dell'originale.
