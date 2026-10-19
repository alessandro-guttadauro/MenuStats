import AppKit
import CoreLocation
import MapKit
import SwiftUI

/// Where this Mac is, for the Map tab. Asks macOS for the position only while the tab is on screen.
final class MapLocator: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Status: Equatable { case idle, locating, waitingForPermission, denied, failed }

    @Published private(set) var location: CLLocation?
    @Published private(set) var placeName: String?
    @Published private(set) var status: Status = .idle
    @Published private(set) var updated: Date?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func refresh() {
        switch manager.authorizationStatus {
        case .notDetermined:
            // A menu bar app has no window in front, and macOS may not show the permission prompt to a background app.
            status = .waitingForPermission
            NSApp.activate(ignoringOtherApps: true)
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            status = .denied
        default:
            status = .locating
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard status == .waitingForPermission || status == .denied else { return }
        refresh()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        self.location = location
        updated = Date()
        status = .idle
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { [weak self] marks, _ in
            DispatchQueue.main.async {
                let mark = marks?.first
                self?.placeName = [mark?.thoroughfare, mark?.locality].compactMap { $0 }.joined(separator: ", ")
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        status = (error as? CLError)?.code == .denied ? .denied : .failed
    }
}

/// Map with this Mac's position, plus a way into Find My for the other devices and people.
struct MapTab: View {
    var mapHeight: CGFloat = 240
    @StateObject private var locator = MapLocator()
    @StateObject private var nearby = NearbyDevicesMonitor()
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        VStack(spacing: 8) {
            Card(title: "Questo Mac", trailing: locator.updated.map { DateText.string($0, "HH:mm") }) {
                map
                    .frame(height: mapHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack(alignment: .firstTextBaseline) {
                    Label(locator.placeName.flatMap { $0.isEmpty ? nil : $0 } ?? statusText, systemImage: "laptopcomputer")
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer()
                    if let accuracy = locator.location?.horizontalAccuracy, accuracy > 0 {
                        Text("± \(Int(accuracy)) m").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Button { locator.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Aggiorna la posizione")
                }
                if locator.status == .denied || locator.status == .waitingForPermission {
                    Button("Apri Servizi di localizzazione…") { SystemActions.openLocationSettings() }
                        .font(.system(size: 11))
                }
            }

            NearbyCard(monitor: nearby)

            Card(title: "iPhone, AirTag e amici") {
                Text("Apple non permette ad altre app di leggere le posizioni di Dov'è (iPhone, AirTag, amici): si vedono solo nell'app Dov'è.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { Self.openFindMy() } label: { Label("Apri Dov'è", systemImage: "location.circle") }
            }
        }
        .onAppear { locator.refresh() }
    }

    @ViewBuilder private var map: some View {
        if let coordinate = locator.location?.coordinate {
            let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500)
            if #available(macOS 14, *) {
                Map(initialPosition: .region(region)) {
                    Marker("Questo Mac", systemImage: "laptopcomputer", coordinate: coordinate)
                        .tint(settings.customColor(for: .map) ?? .red)
                }
                .id(coordinate.latitude + coordinate.longitude)
            } else {
                Map(coordinateRegion: .constant(region), annotationItems: [MapPin(coordinate: coordinate)]) {
                    MapMarker(coordinate: $0.coordinate)
                }
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05))
                VStack(spacing: 6) {
                    if locator.status == .locating { ProgressView().controlSize(.small) }
                    Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
            }
        }
    }

    private var statusText: String {
        switch locator.status {
        case .waitingForPermission: "In attesa del permesso di posizione"
        case .denied: "MenuStats non può usare la posizione"
        case .failed: "Posizione non disponibile al momento"
        case .locating, .idle: "Rilevo la posizione…"
        }
    }

    private static func openFindMy() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.findmy") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

private struct MapPin: Identifiable {
    let coordinate: CLLocationCoordinate2D
    var id: Double { coordinate.latitude + coordinate.longitude }
}
