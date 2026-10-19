import Combine
import SwiftUI

// MARK: - GPU (CPU tab)

/// GPU load, read every 2 s while the card is on screen. The Neural Engine has no counter an app can read.
struct GPUCard: View {
    @State private var stats: GPUStats? = GPUReader.sample()
    @State private var history: [Double] = []
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Card(title: "GPU e Neural Engine", trailing: stats?.name) {
            if let stats {
                HStack(alignment: .top) {
                    Hero(value: Format.percent(stats.utilization), caption: "Utilizzo GPU", accent: Palette.color(3))
                    Spacer()
                    StatGrid(items: [
                        ("Rendering", stats.renderer.map { Format.percent($0) } ?? "—"),
                        ("Tiling", stats.tiler.map { Format.percent($0) } ?? "—"),
                    ], columns: 1)
                    .frame(width: 120)
                }
                UsageBar(fraction: stats.utilization, color: Palette.color(3), height: 6)
                if history.count > 1 { Sparkline(values: history, color: Palette.color(3)).frame(height: 28) }
            } else {
                Text("Utilizzo della GPU non disponibile su questo Mac.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("Neural Engine: macOS mostra il suo utilizzo solo a powermetrics, che richiede la password di amministratore.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(tick) { _ in
            stats = GPUReader.sample()
            if let value = stats?.utilization { history = Array((history + [value]).suffix(60)) }
        }
    }
}

/// Minimal line of recent values (0…1), for cards that keep their own short history.
struct Sparkline: View {
    var values: [Double]
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            let step = proxy.size.width / CGFloat(max(values.count - 1, 1))
            Path { path in
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(index) * step, y: proxy.size.height * (1 - CGFloat(min(max(value, 0), 1))))
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}

// MARK: - Bluetooth accessories (Battery tab)

struct DeviceBatteriesCard: View {
    @StateObject private var monitor = DeviceBatteryMonitor()

    var body: some View {
        Card(title: "Dispositivi collegati") {
            if monitor.devices.isEmpty {
                Text(monitor.loaded ? "Nessun accessorio Bluetooth con batteria collegato (AirPods, mouse, tastiera, trackpad)."
                                    : "Cerco gli accessori collegati…")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(monitor.devices) { device in
                VStack(alignment: .leading, spacing: 4) {
                    Label(device.name, systemImage: device.symbol).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    ForEach(Array(device.levels.enumerated()), id: \.offset) { _, level in
                        HStack(spacing: 8) {
                            if let label = level.label {
                                Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
                            }
                            UsageBar(fraction: level.percent, color: level.percent <= 0.2 ? .red : Palette.color(2), height: 5)
                            Text(Format.percent(level.percent)).font(.system(size: 11)).monospacedDigit().frame(width: 38, alignment: .trailing)
                        }
                    }
                }
            }
            Text("L'iPhone non condivide la batteria con il Mac: per quella usa il widget Batterie o Dov'è.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}

// MARK: - Ping and speed test (Network tab)

struct NetworkToolsCard: View {
    @ObservedObject private var tools = NetworkTools.shared
    @AppStorage("ping.host") private var host = "1.1.1.1"

    var body: some View {
        Card(title: "Ping e velocità") {
            HStack(spacing: 6) {
                TextField("Indirizzo (es. 1.1.1.1)", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { tools.runPing(host: host) }
                Button { tools.runPing(host: host) } label: {
                    if tools.pinging { ProgressView().controlSize(.mini) } else { Text("Ping") }
                }
                .controlSize(.small)
                .disabled(tools.pinging)
            }
            if let ping = tools.ping, ping.average != nil {
                StatGrid(items: [
                    ("Medio", ping.average.map { String(format: "%.1f ms", $0) } ?? "—"),
                    ("Min / max", [ping.minimum, ping.maximum].compactMap { $0.map { String(format: "%.0f", $0) } }.joined(separator: " / ") + " ms"),
                    ("Pacchetti persi", ping.loss.map { Format.percent($0) } ?? "—"),
                ])
            }
            Divider()
            HStack {
                Button { tools.runSpeedTest() } label: {
                    Label(tools.testingSpeed ? "Test in corso (circa 20 s)…" : "Test di velocità", systemImage: "speedometer")
                }
                .controlSize(.small)
                .disabled(tools.testingSpeed)
                if tools.testingSpeed { ProgressView().controlSize(.mini) }
                Spacer()
                if let speed = tools.speed { Text(DateText.string(speed.date, "HH:mm")).font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
            if let speed = tools.speed {
                HStack {
                    Hero(value: speed.download.map(Self.mbps) ?? "—", caption: "Download", accent: Palette.color(0))
                    Spacer()
                    Hero(value: speed.upload.map(Self.mbps) ?? "—", caption: "Upload", accent: Palette.color(1))
                    Spacer()
                }
                if let rpm = speed.responsiveness {
                    Text("Reattività: \(Int(rpm)) RPM (\(Self.responsivenessLabel(rpm)))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let error = tools.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            Text("Usa gli strumenti di macOS (ping e networkQuality, server Apple). Il test scarica e invia qualche centinaio di MB.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func mbps(_ bits: Double) -> String {
        bits >= 1e9 ? String(format: "%.2f Gb/s", bits / 1e9) : String(format: "%.0f Mb/s", bits / 1e6)
    }

    private static func responsivenessLabel(_ rpm: Double) -> String {
        rpm >= 1000 ? "alta" : rpm >= 200 ? "media" : "bassa"
    }
}
