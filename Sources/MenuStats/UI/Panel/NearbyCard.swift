import SwiftUI

/// The user's own devices that macOS can hear right now (paired accessories, iPhone, iPad, Apple Watch), on a radar.
/// Bluetooth gives a rough distance from the signal strength, never a direction, so the dots are spread around the
/// circle only to keep them apart. Other people's devices are never shown.
struct NearbyCard: View {
    @ObservedObject var monitor: NearbyDevicesMonitor
    @ObservedObject private var settings = Settings.shared

    /// Heard right now, or connected (a connected accessory is obviously close even when macOS gives no signal for it).
    private var nearby: [NearbyDevice] { monitor.devices.filter { $0.inRange || $0.connected } }
    private var outOfRange: [NearbyDevice] { monitor.devices.filter { !$0.inRange && !$0.connected } }

    var body: some View {
        Card(title: "I miei dispositivi vicini", trailing: monitor.loaded ? "\(nearby.count)" : nil) {
            if !monitor.loaded {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Cerco i tuoi dispositivi…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if monitor.devices.isEmpty {
                Text("Nessun dispositivo Bluetooth associato a questo Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                if settings.nearbyShowRadar, nearby.contains(where: \.inRange) { NearbyRadar(devices: nearby.filter(\.inRange)).frame(height: 190) }
                ForEach(nearby) { device in
                    HStack(spacing: 8) {
                        Image(systemName: device.symbol).frame(width: 18).foregroundStyle(.secondary)
                        Text(device.name).font(.system(size: 12)).lineLimit(1)
                        if device.connected {
                            Text("collegato").font(.system(size: 9.5, weight: .medium)).foregroundStyle(Palette.color(2))
                        }
                        Spacer()
                        if let rssi = device.rssi {
                            Text("\(Int(rssi)) dBm").font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        Text(device.distance.map(NearbyMath.label(forDistance:)) ?? "—")
                            .font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 54, alignment: .trailing)
                    }
                }
                if nearby.isEmpty {
                    Text("Nessuno dei tuoi dispositivi è nel raggio del Bluetooth.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !outOfRange.isEmpty {
                    Text("Non nelle vicinanze: " + outOfRange.map(\.name).joined(separator: ", "))
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Solo i dispositivi che macOS già conosce: accessori associati e dispositivi Apple (iPhone, iPad, Apple Watch) che riconosce. La distanza è una stima dal segnale (può sbagliare di diversi metri) e non c'è la direzione. Nulla viene salvato né inviato.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}

/// The Mac in the middle, rings at 1, 3 and 10 meters, one icon per device at its estimated distance.
struct NearbyRadar: View {
    var devices: [NearbyDevice]

    /// 0…1 from the center. Closer distances get more room: 1 m at a third of the radius, 3 m at two thirds, 10 m at the edge.
    /// Under one meter the icons keep clear of the Mac in the middle.
    static func radius(forDistance meters: Double) -> Double {
        switch meters {
        case ..<1: 0.2 + 0.13 * max(meters, 0)
        case ..<3: 0.33 + 0.33 * (meters - 1) / 2
        default: 0.66 + 0.34 * min((meters - 3) / 7, 1)
        }
    }

    /// Icons are spread evenly around the circle, in the order of their identifiers, so they never pile up:
    /// the angle means nothing, Bluetooth has no direction.
    static func angles(for ids: [String]) -> [String: Double] {
        let sorted = ids.sorted()
        let step = 2 * Double.pi / Double(max(sorted.count, 1))
        var result: [String: Double] = [:]
        for (index, id) in sorted.enumerated() {
            result[id] = -Double.pi / 2 + step * Double(index)
        }
        return result
    }

    var body: some View {
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) / 2 - 6
            let angles = Self.angles(for: devices.map(\.id))
            ZStack {
                ForEach([1.0, 3.0, 10.0], id: \.self) { meters in
                    ring(meters, radius: radius)
                }
                Image(systemName: "laptopcomputer").font(.system(size: 13)).foregroundStyle(.secondary)
                ForEach(devices) { device in
                    icon(for: device, radius: radius, angle: angles[device.id] ?? 0)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(.easeInOut(duration: 0.6), value: devices.map { $0.rssi ?? 0 })
        }
    }

    private func ring(_ meters: Double, radius: CGFloat) -> some View {
        let size = 2 * radius * CGFloat(Self.radius(forDistance: meters))
        return ZStack {
            Circle().stroke(Palette.neutral, lineWidth: 1).frame(width: size, height: size)
            Text("\(Int(meters)) m").font(.system(size: 8.5)).foregroundStyle(.tertiary).offset(y: -size / 2 - 6)
        }
    }

    private func icon(for device: NearbyDevice, radius: CGFloat, angle: Double) -> some View {
        let meters = device.distance ?? 10
        let distance = CGFloat(Self.radius(forDistance: meters)) * radius
        return Image(systemName: device.symbol)
            .font(.system(size: 11))
            .foregroundStyle(Palette.color(0))
            .offset(x: CGFloat(cos(angle)) * distance, y: CGFloat(sin(angle)) * distance)
            .help("\(device.name) · \(NearbyMath.label(forDistance: meters))")
    }
}
