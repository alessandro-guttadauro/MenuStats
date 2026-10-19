import AppKit
import Combine

/// Extra menu bar icon shown only while a new MenuStats release is available; a click opens Settings ▸ Aggiornamenti.
final class UpdateStatusItem: NSObject {
    private let updater: Updater
    private let openSettings: () -> Void
    private var item: NSStatusItem?
    private var cancellable: AnyCancellable?

    init(updater: Updater, openSettings: @escaping () -> Void) {
        self.updater = updater
        self.openSettings = openSettings
        super.init()
        cancellable = updater.$latest.combineLatest(updater.$state).receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    private func refresh() {
        guard updater.updateAvailable else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.target = self
            item.button?.action = #selector(clicked)
            self.item = item
        }
        let symbol: String
        switch updater.state {
        case .downloading, .installing: symbol = "arrow.down.circle.dotted"
        case .failed: symbol = "exclamationmark.arrow.circlepath"
        default: symbol = "arrow.down.circle.fill"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Aggiornamento di MenuStats disponibile")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold).applying(.init(paletteColors: [.white, .controlAccentColor])))
        item?.button?.image = image
        item?.button?.toolTip = "MenuStats \(updater.latest?.version ?? "") è disponibile: fai clic per aggiornare"
    }

    @objc private func clicked() {
        SettingsNavigation.shared.page = .updates
        openSettings()
    }
}
