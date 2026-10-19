import MenuStatsWidgetUI
import SwiftUI

/// Widgets in the dropdown (choose, size and order them) and how to add them to the desktop.
struct WidgetSettings: View {
    var model: AppModel
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Nella tendina",
                            footnote: "I widget piccoli si affiancano a due a due. Puoi anche fare clic destro su un widget nella tendina per cambiarne la dimensione, spostarlo o rimuoverlo.") {
                Toggle("Mostra la scheda Widget nella tendina", isOn: $settings.showWidgetTab)
                if settings.showWidgetTab {
                    Divider()
                    if settings.panelWidgets.isEmpty {
                        Text("Nessun widget: aggiungine uno.").foregroundStyle(.secondary)
                    }
                    ForEach(settings.panelWidgets.indices, id: \.self) { index in
                        row(index)
                    }
                    HStack {
                        Menu {
                            ForEach(WidgetElement.allCases) { element in
                                Button {
                                    settings.panelWidgets.append(PanelWidget(element: element, size: element == .overview ? .medium : .small))
                                } label: { Label(element.title, systemImage: element.symbol) }
                            }
                        } label: { Label("Aggiungi widget", systemImage: "plus") }
                        .fixedSize()
                        Spacer()
                        Button("Ripristina predefiniti") { settings.panelWidgets = PanelWidget.defaults }
                    }
                }
            }

            SettingsSection(title: "Sulla scrivania e nel Centro Notifiche",
                            footnote: "I widget si aggiornano ogni pochi minuti mentre MenuStats è aperto (macOS limita la frequenza di aggiornamento dei widget). L'ora in alto a destra indica quando sono stati letti i dati; con ⚠︎ i dati sono vecchi perché MenuStats è chiuso.") {
                Text("Fai clic destro sulla scrivania ▸ **Modifica widget…**, cerca **MenuStats** e trascina il widget che preferisci: un elemento singolo (CPU, Memoria, Disco, Rete, Temperature, Ventole, Batteria, Meteo) oppure la **Panoramica** con tutto insieme, in formato piccolo, medio o grande.")
                    .fixedSize(horizontal: false, vertical: true)
                Preview(model: model)
            }
        }
    }

    private func row(_ index: Int) -> some View {
        let widget = settings.panelWidgets[index]
        return HStack(spacing: 10) {
            Image(systemName: widget.element.symbol)
                .frame(width: 22)
                .foregroundStyle(WidgetPalette.color(widget.element))
            Picker("", selection: Binding(get: { settings.panelWidgets[index].element }, set: { element in
                settings.panelWidgets[index].element = element
                if !element.sizes.contains(settings.panelWidgets[index].size) { settings.panelWidgets[index].size = .medium }
            })) {
                ForEach(WidgetElement.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            Picker("", selection: $settings.panelWidgets[index].size) {
                ForEach(widget.element.sizes) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: widget.element.sizes.count == 3 ? 210 : 140)
            Spacer()
            Button { settings.panelWidgets.swapAt(index, index - 1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
            Button { settings.panelWidgets.swapAt(index, index + 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == settings.panelWidgets.count - 1)
            Button { settings.panelWidgets.remove(at: index) } label: { Image(systemName: "trash") }
        }
        .buttonStyle(.borderless)
    }
}

/// A few widgets with the current data, as they appear on the desktop.
private struct Preview: View {
    var model: AppModel
    @ObservedObject var feed: SlowFeed

    init(model: AppModel) {
        self.model = model
        feed = model.slowFeed
    }

    var body: some View {
        let data = model.widgetData(minutes: true)
        HStack(alignment: .top, spacing: 12) {
            tile(.cpu, .small, data, CGSize(width: 158, height: 158))
            tile(.overview, .medium, data, CGSize(width: 338, height: 158))
        }
        .padding(.top, 4)
    }

    private func tile(_ element: WidgetElement, _ size: WidgetSize, _ data: WidgetData, _ frame: CGSize) -> some View {
        MenuStatsWidgetView(element: element, size: size, data: data, showsTime: false)
            .padding(14)
            .frame(width: frame.width, height: frame.height)
            .background(WidgetBackground(element: element))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}
