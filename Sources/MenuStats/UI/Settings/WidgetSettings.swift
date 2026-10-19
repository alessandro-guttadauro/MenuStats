import MenuStatsWidgetUI
import SwiftUI
import WidgetKit

/// Settings ▸ Widget: how to add the desktop widgets, and every widget previewed with the current data.
struct WidgetSettings: View {
    var model: AppModel
    @ObservedObject var feed: SlowFeed
    @State private var element: WidgetElement = .overview
    @State private var reloaded = false

    init(model: AppModel) {
        self.model = model
        feed = model.slowFeed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Widget sulla scrivania e nel Centro Notifiche",
                            footnote: "macOS ridisegna i widget ogni pochi minuti, quindi ci sono solo valori che cambiano lentamente: memoria, disco, batteria e meteo. CPU, rete, temperature e ventole restano nella barra dei menu, che si aggiorna ogni 2 secondi. I widget leggono da soli memoria, disco e batteria e funzionano anche con MenuStats chiuso; il meteo, il grafico della memoria e la salute ufficiale della batteria arrivano dall'app. L'ora in alto a destra indica quando sono stati letti i dati.") {
                Text("Fai clic destro sulla scrivania ▸ **Modifica widget…**, cerca **MenuStats** e trascina il widget che preferisci: Memoria, Disco, Batteria, Meteo oppure la **Panoramica** con tutto insieme, in formato piccolo o medio.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Aggiorna i widget ora") {
                        model.widgets.exportNow()
                        reloaded = true
                    }
                    if reloaded { Text("Fatto").foregroundStyle(.secondary) }
                }
            }

            SettingsSection(title: "Anteprima") {
                Picker("Elemento", selection: $element) {
                    ForEach(WidgetElement.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .frame(maxWidth: 280)
                Text(element.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                preview
            }
        }
    }

    private var preview: some View {
        let data = model.widgetData(forceWeather: true)
        return HStack(alignment: .top, spacing: 14) {
            ForEach(element.sizes) { WidgetPreviewTile(element: element, size: $0, data: data) }
        }
        .padding(.vertical, 4)
    }
}

/// A widget at its real desktop size, with the same margins and background as WidgetKit draws.
struct WidgetPreviewTile: View {
    var element: WidgetElement
    var size: WidgetSize
    var data: WidgetData?

    var body: some View {
        MenuStatsWidgetView(element: element, size: size, data: data, showsTime: false)
            .padding(WidgetMetrics.margin)
            .frame(width: WidgetMetrics.size(size).width, height: WidgetMetrics.size(size).height)
            .background(WidgetBackground(element: element))
            .clipShape(RoundedRectangle(cornerRadius: WidgetMetrics.cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}
