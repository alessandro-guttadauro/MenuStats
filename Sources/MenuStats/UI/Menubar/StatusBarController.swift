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
        observeRoom()

        model.$snapshot.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.render()
            self?.updateAnimation()
        }.store(in: &cancellables)

        // objectWillChange fires before the new value is stored; rebuild on the next run loop pass.
        settings.objectWillChange.debounce(for: .milliseconds(30), scheduler: RunLoop.main).sink { [weak self] _ in
            self?.debug("impostazioni cambiate: livello \(self?.fitLevel ?? -1) -> 0")
            self?.fitLevel = 0
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
        var modules = settings.visibleModules
        if settings.compactMenubar { modules = Array(modules.prefix(max(settings.compactModuleCount, 1))) }
        // Automatic fit: level 1 drops the labels, each further level one more module from the end.
        if fitLevel >= 2 { modules = Array(modules.prefix(max(modules.count - (fitLevel - 1), 1))) }
        return settings.layout == .combined ? [modules] : modules.map { [$0] }
    }

    // MARK: - Room in the menu bar

    /// How much MenuStats is shrunk to stay visible (0 = as configured). Reset when space may have freed up.
    private var fitLevel = 0

    /// Diagnostics for the automatic fit, on with `MENUSTATS_DEBUG=1` (run the app from a terminal to read them).
    private func debug(_ text: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["MENUSTATS_DEBUG"] != nil else { return }
        NSLog("MENUSTATS \(text())")
    }
    private var pinApplied: Bool?
    private var fitCheck: DispatchWorkItem?
    private var confirmation = FitConfirmation()

    private var maxFitLevel: Int { max(settings.visibleModules.count, 1) }

    /// Where macOS put the items, as one number that changes when any of them moves or resizes.
    private var layoutSignature: Double {
        entries.reduce(0) { total, entry in
            guard let frame = entry.item.button?.window?.frame else { return total }
            return total + Double(frame.minX) * 3 + Double(frame.width)
        }
    }

    private var restoreWork: DispatchWorkItem?

    private func scheduleRestore() {
        guard restoreWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            restoreWork = nil
            guard fitLevel > 0 else { return }
            debug("prova a ripristinare: livello \(fitLevel) -> \(fitLevel - 1)")
            fitLevel -= 1
            confirmation.beganRestore()
            confirmation.layoutChanged(at: Date(), signature: layoutSignature)
            rebuild()
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + confirmation.restoreDelay, execute: work)
    }

    /// macOS places items with a smaller preferred position closer to the clock. Written before each item is
    /// created, so MenuStats stays at the right end and other apps' icons overflow first.
    private func pin(_ autosaveName: String, rank: Int) {
        guard settings.pinNearClock else { return }
        UserDefaults.standard.set(Double(rank + 1), forKey: "NSStatusItem Preferred Position \(autosaveName)")
    }

    /// True when macOS isn't showing the item: behind the notch, pushed off screen or into the overflow.
    private func isHidden(_ item: NSStatusItem) -> Bool {
        guard let window = item.button?.window else { return false }
        guard window.isVisible, window.occlusionState.contains(.visible) else { return true }
        let frame = window.frame
        guard let screen = window.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else { return true }
        if frame.maxX <= screen.frame.minX || frame.minX >= screen.frame.maxX { return true }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           frame.maxX > left.maxX + 1, frame.minX < right.minX - 1 { return true }
        return false
    }

    /// The app owning a window that covers a status item, if any. Another app's window at menu bar level (a full-width
    /// overlay, even a fully transparent one, as some apps keep over the bar; or the lock screen) makes macOS report the
    /// item as occluded although there is plenty of room: that is not a reason to shrink the bar. The system's own windows (the ones that host the status items) do not count.
    private func coveringOwner(of window: NSWindow) -> String? {
        guard let primary = NSScreen.screens.first else { return nil }
        // Core Graphics counts from the top left of the primary screen, AppKit from the bottom left.
        let frame = CGRect(x: window.frame.minX, y: primary.frame.height - window.frame.maxY,
                           width: window.frame.width, height: window.frame.height)
        let ignored: Set<String> = ["Window Server", "Control Center", "SystemUIServer", "Dock"]
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windows {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 25,
                  (info[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  let owner = info[kCGWindowOwnerName as String] as? String, !ignored.contains(owner),
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { continue }
            let overlap = bounds.intersection(frame)
            if !overlap.isNull, overlap.width * overlap.height > frame.width * frame.height * 0.5 { return owner }
        }
        return nil
    }

    private func scheduleFitCheck(after delay: Double = 0.6) {
        fitCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkFit() }
        fitCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func checkFit() {
        guard settings.autoFitMenubar, !entries.isEmpty else { return }
        var hidden = entries.contains { isHidden($0.item) }
        // Looks hidden only because another app's window sits on top of the bar: not a lack of room.
        let cover = hidden ? entries.compactMap { $0.item.button?.window }.compactMap(coveringOwner(of:)).first : nil
        if cover != nil { hidden = false }
        let verdict = confirmation.observe(hidden: hidden, signature: layoutSignature, at: Date())
        if ProcessInfo.processInfo.environment["MENUSTATS_DEBUG"] != nil {
            let details = entries.map { entry -> String in
                guard let window = entry.item.button?.window else { return "senza finestra" }
                return "visibile=\(window.isVisible) occlusione=\(window.occlusionState.rawValue) schermo=\(window.screen?.frame ?? .zero) frame=\(window.frame)"
            }
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            let screen = entries.first?.item.button?.window?.screen
            let bar = screen.map { "barra=\($0.frame.maxY - $0.visibleFrame.maxY) schermo=\($0.frame) visibile=\($0.visibleFrame)" } ?? "senza schermo"
            NSLog("MENUSTATS spazio: app in primo piano=\(front) \(bar) livello \(fitLevel), nascosto \(hidden), coperto da \(cover ?? "nessuno"), verdetto \(verdict), \(details)")
        }
        switch verdict {
        case .fine:
            // Shrunk earlier, fits now: try one step wider after a while (it may have been a passing lack of room).
            if fitLevel > 0 { scheduleRestore() }
        case .wait(let seconds): scheduleFitCheck(after: seconds)
        case .shrink:
            guard fitLevel < maxFitLevel else { return }
            debug("riduco: livello \(fitLevel) -> \(fitLevel + 1)")
            fitLevel += 1
            confirmation.layoutChanged(at: Date(), signature: layoutSignature)
            rebuild()
        }
    }

    /// Something that changes the room in the menu bar happened: start again from the full bar.
    private func resetFit() {
        debug("resetFit (livello \(fitLevel))")
        guard fitLevel > 0 else { scheduleFitCheck(); return }
        restoreWork?.cancel()
        restoreWork = nil
        fitLevel = 0
        rebuild()
    }

    private func observeRoom() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Apps add or remove their icons a moment after launching or quitting.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.resetFit() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.resetFit() }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil,
                                               queue: .main) { [weak self] note in
            guard let self, let window = note.object as? NSWindow,
                  entries.contains(where: { $0.item.button?.window === window }) else { return }
            debug("occlusione cambiata: visibile=\(window.occlusionState.contains(.visible)) frame=\(window.frame)")
            scheduleFitCheck(after: 0.3)
        }
    }

    private func rebuild() {
        let wanted = structure
        // Turning "next to the clock" on recreates the items, since macOS reads the position only when one is created.
        if wanted != entries.map(\.modules) || (settings.pinNearClock && pinApplied != true) {
            pinApplied = settings.pinNearClock
            confirmation.layoutChanged(at: Date(), signature: layoutSignature)
            entries.forEach { NSStatusBar.system.removeStatusItem($0.item) }
            // New status items appear to the left of older ones, so create them right-to-left.
            entries = wanted.reversed().enumerated().map { rank, modules in
                let name = "MenuStats." + (wanted.count == 1 ? "combined" : modules[0].rawValue)
                pin(name, rank: rank)
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.autosaveName = name
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
        scheduleFitCheck()
    }

    private func render() {
        var options = MenubarOptions(settings)
        if settings.compactMenubar || fitLevel >= 1 { options.showLabels = false }
        let context = MenubarRenderer.Context(
            snapshot: model.snapshot,
            options: options,
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
            if abs(entries[index].item.length - length) > 0.5 {
                entries[index].item.length = length
                confirmation.layoutChanged(at: Date(), signature: layoutSignature)
                scheduleFitCheck() // a wider value can push MenuStats out of the bar
            }
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
        debug("clic sulla barra (livello \(fitLevel))")
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
