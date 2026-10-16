<p align="center"><img src="docs/icon.png" width="160" alt="Icona di MenuStats"></p>

# MenuStats

Monitor di sistema per la barra dei menu di macOS, ispirato a iStat Menus. È un'implementazione
indipendente: non contiene codice o asset di Bjango e non è affiliato a Bjango.

## Installazione

1. Scarica lo zip `MenuStats-<versione>.zip` dall'ultima [release](https://github.com/thomas-addamo/MenuStats/releases/latest)
   e sposta `MenuStats.app` in `~/Applications` o `/Applications`.
2. L'app ha una firma ad hoc e non è notarizzata: al primo avvio fai clic destro ▸ **Apri**, oppure
   `xattr -dr com.apple.quarantine /Applications/MenuStats.app`.
3. Per il controllo delle ventole: Impostazioni ▸ Ventole ▸ Installa helper, poi consenti MenuStats in
   Impostazioni di Sistema ▸ Generali ▸ Elementi login.

Requisiti: macOS 13 o successivo; temperature e controllo ventole su Apple Silicon. Testato su MacBook Pro
M3 Pro con macOS 27. Per compilare: Xcode 26 o successivo (icona Liquid Glass con `actool`).

## Funzioni

- **Barra dei menu compatta**: tutti i moduli in una voce unica (o una voce per modulo), con etichette
  piccole sopra i valori. Moduli: CPU, Memoria, Disco, Rete, Temperature, Ventole, Batteria.
- **Stili per modulo** (come in iStat Menus), con anteprima nelle Impostazioni: grafico/percentuale/barre per
  core, anello/percentuale/usata/pressione, lettura-scrittura/spazio libero, upload-download/totale,
  sensore da mostrare, giri ventole, percentuale/tempo/watt della batteria.
- **Icone dinamiche**: ventola che gira con le ventole attive, fiamma con CPU sotto carico, termometro che
  sale (e con il sole se macOS rallenta per il calore), frecce di rete/disco accese solo con traffico,
  batteria con fulmine/spina/foglia (basso consumo), avviso con pressione di memoria alta.
- **Colori**: allerte automatiche giallo → arancione → rosso quando serve attenzione (verde in carica);
  facoltativamente un colore a scelta per ogni modulo.
- **Tendina a schede** (CPU, Memoria, Disco, Rete, Sensori, Batteria) con grafici Live / 1 h / 24 h / 7 g,
  mirino al passaggio del mouse, barre per core (efficienza/prestazioni), composizione della memoria,
  volumi (usato / eliminabile / libero), app che usano più CPU, memoria, disco e rete (raggruppate per app),
  ventole e consumo, griglia dei sensori, salute della batteria e modalità basso consumo.
- **Notifiche**: CPU alta, temperatura alta, batteria scarica o carica, ventole al massimo.
- **Storico** SQLite di 8 giorni, **apertura al login**, °C/°F, intervallo di aggiornamento.
- **Controllo ventole** (Auto / Personalizzato con slider per ventola) nella scheda Sensori e in
  Impostazioni ▸ Ventole, tramite un helper con privilegi di root.
- **Limite di carica** 80 / 90 / 100% nella scheda Batteria e in Impostazioni ▸ Batteria.

## Uso

```bash
./scripts/install.sh                 # compila, installa in ~/Applications e avvia
swift run MenuStats --verify         # confronta i valori con gli strumenti di macOS (✓/✗)
swift run MenuStats --dump           # stampa una lettura di tutto
swift run MenuStats --benchmark      # costo di ogni lettore e del disegno della barra
swift run MenuStats --render-ui /tmp/ui   # PNG di barra, tendine e impostazioni (chiaro/scuro)
build/MenuStats.app/Contents/MacOS/MenuStats --self-test /tmp/live   # apre ogni tendina dell'app reale e la cattura
~/Applications/MenuStats.app/Contents/MacOS/MenuStats --install-helper     # registra l'helper (o dalle Impostazioni)
~/Applications/MenuStats.app/Contents/MacOS/MenuStats --uninstall-helper
~/Applications/MenuStats.app/Contents/MacOS/MenuStats --fan-test 0 3000    # prova ventola 0 rileggendo le chiavi SMC
```

Clic su un modulo: tendina sulla scheda giusta. Clic destro: Impostazioni, Monitoraggio Attività, Esci.

## Attendibilità

`--verify` confronta 18 valori con `top`, `sysctl`, `diskutil`, `route`, `ipconfig`, `pmset` e Informazioni
di Sistema. Note:
- **Disco**: "libero" è lo spazio realmente libero (come `df`/diskutil); lo spazio che macOS può liberare da
  solo (cache, istantanee locali) è indicato a parte come "eliminabile".
- **Capacità massima della batteria**: è il valore di Apple (Informazioni di Sistema), non una stima.
- **Attivo da**: tempo dall'avvio, sonno incluso (come `uptime`).
- Temperature, ventole e potenza non sono verificabili senza root (`powermetrics`).

## Fonti dati (nessun privilegio di root)

| Modulo | API |
|---|---|
| CPU | `host_processor_info`, `getloadavg`, `hw.perflevel*` |
| Memoria | `host_statistics64(HOST_VM_INFO64)`, `vm.swapusage`, `kern.memorystatus_vm_pressure_level` |
| Disco | `IOBlockStorageDriver` → `Statistics`; capacità da `URLResourceValues` |
| Rete | `sysctl NET_RT_IFLIST2`, SystemConfiguration; per app: `nettop` (solo con la scheda Rete aperta) |
| Temperature | `IOHIDEventSystemClient` (API privata), in background ogni 5 s |
| Ventole, potenza | SMC in sola lettura (`F*Ac`, `F*Mn`, `F*Mx`, `PSTR`, `PDTR`) |
| Batteria | IOPowerSources, `AppleSmartBattery`, `system_profiler SPPowerDataType` (salute) |
| Processi | `proc_listallpids`, `proc_pid_rusage`, `proc_pidpath` |

## Controllo ventole e limite di carica

**Ventole: helper con privilegi.** `MenuStatsHelper` è un LaunchDaemon dentro il bundle
(`Contents/MacOS/MenuStatsHelper`, plist in `Contents/Library/LaunchDaemons/local.menustats.helper.plist`),
registrato con `SMAppService.daemon` (macOS 13+) da Impostazioni ▸ Ventole ▸ Installa helper. Dopo la
registrazione bisogna consentirlo in Impostazioni di Sistema ▸ Generali ▸ Elementi login. L'app gli parla via
XPC (`local.menustats.helper`, protocollo in `Sources/MenuStatsShared`).

- Su Apple Silicon (M3 Pro, macOS 27) le chiavi scrivibili sono `Ftst`, `F{n}Md` e `F{n}Tg`. La modalità
  personalizzata scrive `Ftst=1`, `F{n}Md=1` e `F{n}Tg` = giri. Quella automatica scrive `F{n}Md=0` e, quando
  nessuna ventola è più manuale, `Ftst=0`. `F{n}Mn` e `F{n}Mx` sono di sola lettura e fanno da limiti.
- La scrittura passa per `MSSMCWrite` (`Sources/CIOKitPrivate/shim.c`, comando `kSMCWriteKey = 6`), che
  rifiuta dimensioni diverse da quella della chiave.
- **Sicurezza** (tutto applicato dall'helper):
  - accetta solo questa copia di MenuStats: requisito di firma sulla connessione (cdhash dell'app con firma
    ad hoc, Team ID con Developer ID);
  - valida indice della ventola e velocità e rifiuta valori fuori da `F{n}Mn`…`F{n}Mx`;
  - rimette le ventole in automatico quando l'app si chiude o va in crash (connessione XPC chiusa), prima
    dello stop, su SIGTERM, all'avvio dell'helper e quando macOS segnala stress termico (una velocità fissa
    non sale da sola sotto carico).
- **Firma**: con la firma ad hoc l'helper si registra e funziona dopo l'approvazione in Elementi login; il
  Developer ID non serve per l'uso locale. Per distribuire l'app ad altri Mac servono Developer ID e
  notarizzazione: `SIGN_IDENTITY="Developer ID Application: …" ./scripts/build-app.sh`.

**Limite di carica: limite nativo di macOS.** Su macOS 27 le chiavi SMC usate dagli altri strumenti
(`CH0B`/`CH0C`, `CHTE`) non esistono più, e le nuove sono protette da un entitlement privato anche per root.
MenuStats usa quindi lo stesso limite di Impostazioni di Sistema ▸ Batteria (framework privato PowerUI,
`Sources/CIOKitPrivate/chargelimit.m`). Non richiede root né l'helper, accetta 80–100% e lo applica il
sistema anche in stop e dopo il riavvio. Verifica: `pmset -g battlimit`.

## Limiti noti

- Senza root si vedono solo i processi del proprio utente.
- La modalità personalizzata fissa la velocità: il firmware non la alza da solo. Per questo l'helper torna in
  automatico sotto stress termico.
- Il limite di carica scende al massimo all'80% (limite di macOS).
- In modalità "una voce per modulo" la distanza tra le voci la decide macOS; la voce unica è più compatta.
