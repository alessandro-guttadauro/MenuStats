import SwiftUI

final class DashboardState: ObservableObject {
    @Published var tab: DashboardTab = .cpu
    /// While the panel is closed the content isn't built, so it doesn't re-render (and query history) on every sample.
    @Published var visible = true
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The dropdown panel. Builds its content only while visible.
struct DashboardView: View {
    static let width: CGFloat = 372

    var model: AppModel
    @ObservedObject var state: DashboardState
    var maxContentHeight: CGFloat
    var openSettings: () -> Void
    var quit: () -> Void
    var onLayoutChange: () -> Void = {}

    var body: some View {
        if state.visible {
            DashboardContent(model: model, state: state, maxContentHeight: maxContentHeight,
                             openSettings: openSettings, quit: quit, onLayoutChange: onLayoutChange)
        } else {
            Color.clear.frame(width: Self.width, height: 1)
        }
    }
}

/// Tab bar, shared chart range, the selected tab, and a footer.
struct DashboardContent: View {
    static let width = DashboardView.width

    @ObservedObject var model: AppModel
    @ObservedObject var state: DashboardState
    var maxContentHeight: CGFloat
    var openSettings: () -> Void
    var quit: () -> Void
    /// Called when the content height changes, so the panel can resize.
    var onLayoutChange: () -> Void = {}

    @AppStorage("chart.range") private var rangeRaw = HistoryRange.live.rawValue
    @State private var contentHeight: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)

            if state.tab != .widgets { // widgets draw their own recent graphs
                Picker("", selection: $rangeRaw) {
                    ForEach(HistoryRange.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            ScrollView(.vertical, showsIndicators: contentHeight > maxContentHeight) {
                content
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .background(GeometryReader { Color.clear.preference(key: ContentHeightKey.self, value: $0.size.height) })
            }
            .frame(height: min(contentHeight, maxContentHeight))
            .onPreferenceChange(ContentHeightKey.self) { height in
                guard abs(height - contentHeight) > 0.5 else { return }
                contentHeight = height
                DispatchQueue.main.async(execute: onLayoutChange)
            }

            Divider()
            footer
        }
        .frame(width: Self.width)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(visibleTabs) { tab in
                let selected = state.tab == tab
                let alert = severity(of: tab)
                Button { state.tab = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 13, weight: .medium)).frame(height: 16)
                            .foregroundStyle(alert.color ?? (selected ? Color.primary : Color.secondary))
                        Text(tab.title).font(.system(size: 9.5, weight: selected ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.primary.opacity(0.09) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// System tabs always; Weather and Date only while their module is enabled.
    private var visibleTabs: [DashboardTab] { DashboardTab.allCases.filter(isEnabledTab) }

    private func isEnabledTab(_ tab: DashboardTab) -> Bool {
        switch tab {
        case .weather: model.settings.isEnabled(.weather)
        case .date: model.settings.isEnabled(.date)
        case .widgets: model.settings.showWidgetTab
        default: true
        }
    }

    /// Worst alert among the modules shown in a tab (sensors covers temperatures and fans).
    private func severity(of tab: DashboardTab) -> Severity {
        let settings = model.settings
        guard settings.severityColors else { return .normal }
        return ModuleID.allCases.filter { $0.tab == tab }.map {
            Severity.of($0, snapshot: model.snapshot, cpuBusy: settings.cpuBusyThreshold,
                        temperatureHot: settings.temperatureHotThreshold, source: settings.sensorSource)
        }.max() ?? .normal
    }

    @ViewBuilder private var content: some View {
        switch state.tab {
        case .cpu: CPUTab(model: model)
        case .memory: MemoryTab(model: model)
        case .disk: DiskTab(model: model)
        case .network: NetworkTab(model: model)
        case .sensors: SensorsTab(model: model)
        case .battery: BatteryTab(model: model)
        case .weather: WeatherTab(weather: model.weather, openSettings: openSettings)
        case .date: DateTab(weather: model.weather)
        case .widgets: WidgetsTab(model: model, openSettings: openSettings)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button { SystemActions.openActivityMonitor() } label: { Label("Monitoraggio Attività", systemImage: "chart.bar.xaxis") }
            Spacer()
            Button(action: openSettings) { Image(systemName: "gearshape") }.help("Impostazioni…")
            Button(action: quit) { Image(systemName: "power") }.help("Esci da MenuStats")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
