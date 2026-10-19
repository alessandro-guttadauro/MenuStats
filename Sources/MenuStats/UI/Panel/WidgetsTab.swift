import MenuStatsWidgetUI
import SwiftUI

/// The dropdown's Widget tab: the same widgets as the desktop, with live data. Small widgets pair up side by side.
struct WidgetsTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings = .shared
    var openSettings: () -> Void

    static let spacing: CGFloat = 8
    static let contentWidth = DashboardView.width - 20

    var body: some View {
        let data = model.widgetData(minutes: false)
        VStack(spacing: Self.spacing) {
            if settings.panelWidgets.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("Nessun widget").font(.system(size: 13, weight: .semibold))
                    Text("Aggiungi i widget che vuoi vedere qui: un elemento alla volta o la panoramica di tutto.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            ForEach(rows, id: \.first!.id) { row in
                HStack(spacing: Self.spacing) {
                    ForEach(row) { widget in tile(widget, data: data) }
                    if row.count == 1, row[0].size == .small { Color.clear.frame(width: Self.smallSide, height: Self.smallSide) }
                }
            }
            controls
        }
    }

    static let smallSide = (contentWidth - spacing) / 2

    private func frame(_ size: WidgetSize) -> CGSize {
        switch size {
        case .small: CGSize(width: Self.smallSide, height: Self.smallSide)
        case .medium: CGSize(width: Self.contentWidth, height: Self.smallSide)
        case .large: CGSize(width: Self.contentWidth, height: Self.smallSide * 2 + Self.spacing)
        }
    }

    /// Consecutive small widgets share a row; medium and large take a row each.
    private var rows: [[PanelWidget]] {
        var rows: [[PanelWidget]] = []
        for widget in settings.panelWidgets {
            if widget.size == .small, let last = rows.last, last.count == 1, last[0].size == .small {
                rows[rows.count - 1].append(widget)
            } else {
                rows.append([widget])
            }
        }
        return rows
    }

    private func tile(_ widget: PanelWidget, data: WidgetData) -> some View {
        let size = frame(widget.size)
        return MenuStatsWidgetView(element: widget.element, size: widget.size, data: data, showsTime: false)
            .padding(14)
            .frame(width: size.width, height: size.height)
            .background(WidgetBackground(element: widget.element))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .contextMenu {
                ForEach(widget.element.sizes) { option in
                    Button { resize(widget, to: option) } label: {
                        if option == widget.size { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
                    }
                }
                Divider()
                Button("Sposta prima") { move(widget, by: -1) }.disabled(settings.panelWidgets.first == widget)
                Button("Sposta dopo") { move(widget, by: 1) }.disabled(settings.panelWidgets.last == widget)
                Divider()
                Button("Rimuovi widget", role: .destructive) { settings.panelWidgets.removeAll { $0.id == widget.id } }
            }
    }

    private var controls: some View {
        HStack {
            Menu {
                ForEach(WidgetElement.allCases) { element in
                    Menu {
                        ForEach(element.sizes) { size in
                            Button(size.label) { settings.panelWidgets.append(PanelWidget(element: element, size: size)) }
                        }
                    } label: { Label(element.title, systemImage: element.symbol) }
                }
            } label: {
                Label("Aggiungi widget", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Button("Modifica…") {
                SettingsNavigation.shared.page = .widgets
                openSettings()
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private func resize(_ widget: PanelWidget, to size: WidgetSize) {
        guard let index = settings.panelWidgets.firstIndex(of: widget) else { return }
        settings.panelWidgets[index].size = size
    }

    private func move(_ widget: PanelWidget, by offset: Int) {
        guard let index = settings.panelWidgets.firstIndex(of: widget) else { return }
        let target = index + offset
        guard settings.panelWidgets.indices.contains(target) else { return }
        settings.panelWidgets.swapAt(index, target)
    }
}
