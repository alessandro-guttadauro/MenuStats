import AppKit
import Combine

/// Owns the status items: one combined item (compact) or one per module, re-rendered on every
/// sample and on settings changes. A left click opens the dashboard on the clicked module's tab.
final class StatusBarController: NSObject {
    private let model: AppModel
    private let settings: Settings
    private let panel: DashboardPanelController
    private let openSettings: () -> Void

    private struct Entry {
        var item: NSStatusItem
        var modules: [ModuleID]
        var hitRanges: [(ModuleID, ClosedRange<CGFloat>)] = []
        var imageWidth: CGFloat = 0
        /// Pixels of the image currently shown, to skip identical updates.
        var pixels = Data()
        /// Appearance the shown bitmap was rasterized for; a light/dark switch forces a new one on the next render.
        var appearanceName: NSAppearance.Name?
    }

    private var entries: [Entry] = []
    private var cancellables: Set<AnyCancellable> = []
    private var fanAngle: CGFloat = 0
    private var steamPhase: CGFloat = 0
    private var animationTimer: Timer?

    init(model: AppModel, panel: DashboardPanelController, openSettings: @escaping () -> Void) {
        self.model = model
        self.settings = model.settings
        self.panel = panel
        self.openSettings = openSettings
        super.init()

        model.$snapshot.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.render()
            self?.updateAnimation()
        }.store(in: &cancellables)

        // objectWillChange fires before the new value is stored; rebuild on the next run loop pass.
        settings.objectWillChange.debounce(for: .milliseconds(30), scheduler: RunLoop.main).sink { [weak self] _ in
            self?.rebuild()
        }.store(in: &cancellables)

        // A new weather report re-renders the bar (every 15 minutes at most).
        model.weather.$report.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.render() }
        }.store(in: &cancellables)

        // Starting or ending an Awake session updates the bar at once, not at the next sample.
        model.awake.$state.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.render()
            self?.updateAnimation()
        }.store(in: &cancellables)

        rebuild()
    }

    /// One-second clock, only while the date module shows seconds (otherwise the 2 s sample is enough).
    private var clockTimer: Timer?

    private func updateClock() {
        let needsSeconds = settings.isEnabled(.date) && settings.dateStyle == .timeSeconds
        if needsSeconds, clockTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.render() }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            clockTimer = timer
        } else if !needsSeconds, let timer = clockTimer {
            timer.invalidate()
            clockTimer = nil
        }
    }

    private var structure: [[ModuleID]] {
        let modules = settings.visibleModules
        return settings.layout == .combined ? [modules] : modules.map { [$0] }
    }

    private func rebuild() {
        let wanted = structure
        if wanted != entries.map(\.modules) {
            entries.forEach { NSStatusBar.system.removeStatusItem($0.item) }
            // New status items appear to the left of older ones, so create them right-to-left.
            entries = wanted.reversed().map { modules in
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.autosaveName = "MenuStats." + (wanted.count == 1 ? "combined" : modules[0].rawValue)
                item.button?.target = self
                item.button?.action = #selector(clicked(_:))
                item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
                item.button?.imagePosition = .imageOnly
                return Entry(item: item, modules: modules)
            }.reversed()
        }
        render()
        updateAnimation()
        updateClock()
    }

    private func render() {
        let context = MenubarRenderer.Context(
            snapshot: model.snapshot,
            options: MenubarOptions(settings),
            recent: { [weak model] metric, count in model?.recentValues(metric, count: count) ?? [] },
            fanAngle: fanAngle,
            steamPhase: steamPhase,
            weather: model.weather.report,
            weatherConfigured: settings.weatherLocation != nil,
            awake: model.awake.state
        )
        for index in entries.indices {
            guard let button = entries[index].item.button else { continue }
            let rendered = MenubarRenderer.image(for: entries[index].modules, context: context)
            // Rasterize once, in the menu bar's appearance, and hand AppKit a bitmap only when its pixels changed:
            // an NSImage drawing handler would re-run text layout on every redraw of the menu bar.
            let appearance = button.effectiveAppearance
            let bitmap = Self.rasterize(rendered.image, appearance: appearance,
                                        scale: button.window?.backingScaleFactor ?? 2)
            if bitmap.pixels != entries[index].pixels || entries[index].appearanceName != appearance.name {
                entries[index].appearanceName = appearance.name
                button.image = bitmap.image
                entries[index].pixels = bitmap.pixels
            }
            // Exact width instead of variableLength (which pads both sides). Only when it changes:
            // every length change makes macOS re-layout the whole menu bar.
            let length = ceil(rendered.image.size.width) + 2
            if abs(entries[index].item.length - length) > 0.5 { entries[index].item.length = length }
            entries[index].hitRanges = rendered.hitRanges
            entries[index].imageWidth = rendered.image.size.width
        }
    }

    private static func rasterize(_ image: NSImage, appearance: NSAppearance, scale: CGFloat) -> (image: NSImage, pixels: Data) {
        let size = image.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)),
                                         pixelsHigh: Int(ceil(size.height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return (image, Data()) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance { image.draw(in: NSRect(origin: .zero, size: size)) }
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: size)
        result.addRepresentation(rep)
        result.isTemplate = image.isTemplate
        let pixels = rep.bitmapData.map { Data(bytes: $0, count: rep.bytesPerRow * rep.pixelsHigh) } ?? Data()
        return (result, pixels)
    }

    // MARK: - Fan and steam animation

    private var shouldAnimateFan: Bool {
        settings.dynamicIcons && settings.isEnabled(.fans) && model.snapshot.fansSpinning
    }

    /// Steam rises from the cup while an Awake session runs.
    private var shouldAnimateSteam: Bool {
        settings.dynamicIcons && settings.isEnabled(.awake) && model.awake.state.isActive
    }

    private func updateAnimation() {
        let animate = shouldAnimateFan || shouldAnimateSteam
        if animate, animationTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in self?.advanceAnimation() }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        } else if !animate, animationTimer != nil {
            animationTimer?.invalidate()
            animationTimer = nil
            fanAngle = 0
            steamPhase = 0
            render()
        }
    }

    private func advanceAnimation() {
        if shouldAnimateFan {
            let fraction = model.snapshot.smc?.fans.map(\.fraction).max() ?? 0
            // 0.4–2 revolutions per second depending on fan speed.
            fanAngle -= CGFloat(2 * Double.pi * (0.4 + 1.6 * fraction) / 12)
        } else {
            fanAngle = 0
        }
        // One steam cycle every 2.5 s.
        steamPhase = shouldAnimateSteam ? (steamPhase + 1 / (12 * 2.5)).truncatingRemainder(dividingBy: 1) : 0
        render()
    }

    // MARK: - Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let entry = entries.first(where: { $0.item.button === sender }), let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showQuickMenu(for: entry.item)
            return
        }

        // The image is centered in the button; map the click to a segment.
        let location = sender.convert(event.locationInWindow, from: nil)
        let offset = (sender.bounds.width - entry.imageWidth) / 2
        let x = location.x - offset
        let range = entry.hitRanges.first { $0.1.contains(x) } ?? entry.hitRanges.min {
            abs(($0.1.lowerBound + $0.1.upperBound) / 2 - x) < abs(($1.1.lowerBound + $1.1.upperBound) / 2 - x)
        }
        guard let (module, segment) = range, let window = sender.window else { return }

        let midX = offset + (segment.lowerBound + segment.upperBound) / 2
        let pointInWindow = sender.convert(NSPoint(x: midX, y: sender.bounds.minY), to: nil)
        let anchor = window.convertPoint(toScreen: pointInWindow)
        panel.toggle(tab: module.tab, anchor: NSPoint(x: anchor.x, y: window.frame.minY))
    }

    /// Screen anchor under a module's segment (bottom-center), as a click there would compute.
    func anchor(for module: ModuleID) -> NSPoint? {
        guard let entry = entries.first(where: { $0.modules.contains(module) }), let button = entry.item.button,
              let window = button.window, let range = entry.hitRanges.first(where: { $0.0 == module })?.1 else { return nil }
        let offset = (button.bounds.width - entry.imageWidth) / 2
        let point = window.convertPoint(toScreen: button.convert(NSPoint(x: offset + (range.lowerBound + range.upperBound) / 2, y: 0), to: nil))
        return NSPoint(x: point.x, y: window.frame.minY)
    }

    /// The status item buttons, for self-test captures.
    var buttons: [NSStatusBarButton] { entries.compactMap { $0.item.button } }

    private func showQuickMenu(for item: NSStatusItem) {
        panel.close()
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Impostazioni…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let activity = NSMenuItem(title: "Apri Monitoraggio Attività", action: #selector(openActivityMonitor), keyEquivalent: "")
        activity.target = self
        menu.addItem(activity)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Esci da MenuStats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil // restore left-click handling
    }

    @objc private func openSettingsAction() { openSettings() }
    @objc private func openActivityMonitor() { SystemActions.openActivityMonitor() }
}
