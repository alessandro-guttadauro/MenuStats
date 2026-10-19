import SwiftUI

/// Settings ▸ Aggiornamenti: current and latest version, release notes, one-click install.
struct UpdateSettings: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: Updater.canInstall ? "MenuStats \(Updater.currentVersion)" : "MenuStats (sviluppo)", footnote: footnote) {
                status
                HStack {
                    if updater.updateAvailable {
                        switch updater.state {
                        case .downloading, .installing:
                            Button("Annulla") { updater.cancel() }.disabled(updater.state == .installing)
                        default:
                            Button("Scarica e installa") { updater.installUpdate() }
                                .keyboardShortcut(.defaultAction)
                                .disabled(!Updater.canInstall)
                        }
                    }
                    Button("Controlla ora") { updater.check(userInitiated: true) }
                        .disabled(updater.state == .checking || updater.state == .installing)
                    Spacer()
                    if let latest = updater.latest {
                        Link("Note su GitHub", destination: latest.page).font(.system(size: 11))
                    }
                }
                Toggle("Controlla automaticamente gli aggiornamenti", isOn: $updater.automaticChecks)
            }
            if let latest = updater.latest, updater.updateAvailable, !latest.notes.isEmpty {
                SettingsSection(title: "Novità della versione \(latest.version)") {
                    Text(notes(latest.notes))
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 8) {
            switch updater.state {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Controllo in corso…")
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 180)
                Text("Download \(Int(fraction * 100))%")
            case .installing:
                ProgressView().controlSize(.small)
                Text("Installazione: MenuStats si riaprirà da solo tra un attimo…")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).fixedSize(horizontal: false, vertical: true)
            default:
                if updater.updateAvailable, let latest = updater.latest {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor).font(.system(size: 16))
                    Text("È disponibile MenuStats **\(latest.version)**\(latest.size > 0 ? " (\(ByteCountFormatter.string(fromByteCount: Int64(latest.size), countStyle: .file)))" : "").")
                } else if updater.latest != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("MenuStats è aggiornato.")
                } else {
                    Text("Non ho ancora controllato gli aggiornamenti.").foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 12))
    }

    private var footnote: String {
        var text = "L'aggiornamento viene scaricato da GitHub, verificato (impronta SHA-256 pubblicata e firma dell'app) e installato al posto della versione attuale: non servono comandi e macOS non chiede di nuovo “Apri comunque”. Impostazioni, storico e helper delle ventole restano."
        if let lastCheck = updater.lastCheck {
            text += " Ultimo controllo: \(lastCheck.formatted(date: .abbreviated, time: .shortened))."
        }
        if !Updater.canInstall { text += " (Questa copia non è un'app installata: aggiorna con scripts/install.sh.)" }
        return text
    }

    /// Release notes are Markdown; show them with inline styling, keeping line breaks.
    private func notes(_ markdown: String) -> AttributedString {
        let cleaned = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var line = String(line)
                if line.hasPrefix("## ") || line.hasPrefix("### ") { line = "**" + line.drop { $0 == "#" || $0 == " " } + "**" }
                if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "•  " + line.dropFirst(2) }
                return line
            }
            .joined(separator: "\n")
        return (try? AttributedString(markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(cleaned)
    }
}
