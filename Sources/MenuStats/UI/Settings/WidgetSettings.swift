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
                            footnote: "I widget leggono da soli CPU, memoria, disco, rete, batteria, temperature e ventole, quindi funzionano anche con MenuStats chiuso. Con l'app aperta mostrano in più i grafici dell'ultima ora, la salute ufficiale della batteria e il meteo. macOS decide quando ridisegnarli (di solito ogni 5-15 minuti): l'ora in alto a destra indica quando sono stati letti i dati.") {
                Text("Fai clic destro sulla scrivania ▸ **Modifica widget…**, cerca **MenuStats** e trascina il widget che preferisci: un elemento singolo oppure la **Panoramica** con tutto insieme.")
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
        let data = model.widgetData(minutes: true, forceWeather: true)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                WidgetPreviewTile(element: element, size: .small, data: data)
                WidgetPreviewTile(element: element, size: .medium, data: data)
            }
            if element.sizes.contains(.large) {
                WidgetPreviewTile(element: element, size: .large, data: data)
            }
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
