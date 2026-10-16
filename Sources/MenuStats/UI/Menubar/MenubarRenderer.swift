import AppKit

/// One module's drawing in the menu bar.
struct MenubarSegment {
    var module: ModuleID
    var width: CGFloat
    var draw: (NSRect) -> Void
}

/// Draws the compact menu bar: every module as a small segment (visual + label/value).
/// Monochrome by default (a template image macOS tints for light and dark menu bars); optionally colored
/// per module, and automatically yellow → orange → red when a module needs attention.
/// Dynamic icons react to what the Mac is doing (load, heat, fans, charging, traffic).
enum MenubarRenderer {
    static let height: CGFloat = 22
    static let segmentGap: CGFloat = 10

    struct Context {
        var snapshot: Snapshot
        var options: MenubarOptions
        var recent: (Metric, Int) -> [Double]
        /// Fan animation angle in radians, advanced by the status bar controller while fans spin.
        var fanAngle: CGFloat = 0
    }

    // MARK: - Composition

    static func image(for modules: [ModuleID], context: Context) -> (image: NSImage, hitRanges: [(ModuleID, ClosedRange<CGFloat>)]) {
        let segments = modules.map { segment(for: $0, context: context) }
        let width = max(1, segments.map(\.width).reduce(0, +) + segmentGap * CGFloat(max(segments.count - 1, 0)))
        var ranges: [(ModuleID, ClosedRange<CGFloat>)] = []
        var x: CGFloat = 0
        for segment in segments {
            // Click targets extend halfway into the gaps.
            ranges.append((segment.module, (x - segmentGap / 2)...(x + segment.width + segmentGap / 2)))
            x += segment.width + segmentGap
        }

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for segment in segments {
                segment.draw(NSRect(x: x, y: 0, width: segment.width, height: height))
                x += segment.width + segmentGap
            }
            return true
        }
        // Monochrome stays a template (macOS tints it); with colors the image carries its own (adaptive) colors.
        image.isTemplate = !context.options.usesColor
        return (image, ranges)
    }

    static func segment(for module: ModuleID, context: Context) -> MenubarSegment {
        let options = context.options
        showLabels = options.showLabels
        ink = Ink(module: module, options: options, severity: Severity.of(
            module, snapshot: context.snapshot, cpuBusy: options.cpuBusyThreshold,
            temperatureHot: options.temperatureHotThreshold, source: options.sensorSource))
        return switch module {
        case .cpu: cpu(context)
        case .memory: memory(context)
        case .disk: disk(context)
        case .network: network(context)
        case .sensors: sensors(context)
        case .fans: fans(context)
        case .battery: battery(context)
        }
    }

    // MARK: - Modules

    private static func cpu(_ context: Context) -> MenubarSegment {
        let settings = context.options
        let cpu = context.snapshot.cpu
        let total = cpu?.total ?? 0
        let busy = settings.dynamicIcons && total >= settings.cpuBusyThreshold
        let value = cpu.map { Format.percent($0.total) } ?? "—"

        var parts: [Part] = []
        switch settings.cpuStyle {
        case .graphPercent:
            parts = [.graph(context.recent(.cpu, 15), width: 30), .text("CPU", value, template: "100%", emphasized: busy)]
        case .percent:
            parts = [.text("CPU", value, template: "100%", emphasized: busy)]
        case .graph:
            parts = [.graph(context.recent(.cpu, 20), width: 40)]
        case .cores:
            parts = [.cores(cpu?.perCore ?? [])]
        }
        if busy { parts.insert(.symbol("flame.fill", size: 9), at: parts.count - (parts.count > 1 ? 1 : 0)) }
        return compose(.cpu, parts)
    }

    private static func memory(_ context: Context) -> MenubarSegment {
        let memory = context.snapshot.memory
        let pressured = context.options.dynamicIcons && (memory?.pressureLevel ?? 1) >= 2
        let fraction = memory?.usedFraction ?? 0

        let lead: Part = pressured ? .symbol("exclamationmark.triangle.fill", size: 11) : .ring(fraction)
        switch context.options.memoryStyle {
        case .ringPercent:
            return compose(.memory, [lead, .text("MEM", Format.percent(fraction), template: "100%")])
        case .percent:
            return compose(.memory, [.text("MEM", Format.percent(fraction), template: "100%", emphasized: pressured)])
        case .used:
            let used = memory.map { String(format: "%.1fG", Double($0.used) / 1_073_741_824) } ?? "—"
            return compose(.memory, [lead, .text("MEM", used, template: "99.9G")])
        case .pressure:
            let label = [1: "OK", 2: "ALTA", 4: "CRIT"][memory?.pressureLevel ?? 1] ?? "—"
            return compose(.memory, [lead, .text("PRESS", label, template: "CRIT", emphasized: pressured)])
        }
    }

    private static func disk(_ context: Context) -> MenubarSegment {
        guard let disk = context.snapshot.disk else { return compose(.disk, [.text("SSD", "—", template: "100%")]) }
        let dynamic = context.options.dynamicIcons
        switch context.options.diskStyle {
        case .activity:
            let reading = disk.readRate > 64_000, writing = disk.writeRate > 64_000
            return compose(.disk, [
                .stacked(top: ("R", Format.rate(disk.readRate, compact: true), !dynamic || reading),
                         bottom: ("W", Format.rate(disk.writeRate, compact: true), !dynamic || writing)),
            ])
        case .free:
            let free = Format.storageCompact(disk.free)
            return compose(.disk, [.symbol("internaldrive", size: 12), .text("LIBERO", free, template: "999G")])
        case .usedPercent:
            return compose(.disk, [.ring(disk.usedFraction), .text("SSD", Format.percent(disk.usedFraction), template: "100%")])
        }
    }

    private static func network(_ context: Context) -> MenubarSegment {
        guard let network = context.snapshot.network else { return compose(.network, [.text("NET", "—", template: "999K")]) }
        let dynamic = context.options.dynamicIcons
        let offline = network.interface == nil
        if offline && dynamic {
            return compose(.network, [.symbol("wifi.slash", size: 11), .text("NET", "OFF", template: "999K")])
        }
        let uploading = network.uploadRate > 2_000, downloading = network.downloadRate > 2_000
        switch context.options.networkStyle {
        case .stacked:
            return compose(.network, [
                .stacked(top: ("↑", Format.rate(network.uploadRate, compact: true), !dynamic || uploading),
                         bottom: ("↓", Format.rate(network.downloadRate, compact: true), !dynamic || downloading)),
            ])
        case .download:
            return compose(.network, [.text("↓ NET", Format.rate(network.downloadRate, compact: true), template: "999K",
                                            emphasized: dynamic && downloading)])
        case .total:
            let total = network.uploadRate + network.downloadRate
            return compose(.network, [.text("NET", Format.rate(total, compact: true), template: "999K",
                                            emphasized: dynamic && (uploading || downloading))])
        }
    }

    private static func sensors(_ context: Context) -> MenubarSegment {
        let snapshot = context.snapshot
        let settings = context.options
        let (label, celsius): (String, Double?) = switch settings.sensorSource {
        case .cpuAverage: ("CPU", snapshot.cpuTemperature)
        case .cpuMax: ("MAX", snapshot.cpuTemperatureMax)
        case .hottest: ("TOP", snapshot.sensors.hottest?.celsius)
        case .ssd: ("SSD", snapshot.ssdTemperature)
        case .battery: ("BAT", snapshot.battery?.temperature ?? snapshot.sensors.batteryTemperature)
        }

        var symbol = "thermometer.medium"
        var hot = false
        if settings.dynamicIcons, let celsius {
            hot = celsius >= settings.temperatureHotThreshold
            symbol = celsius < 50 ? "thermometer.low" : (hot ? "thermometer.high" : "thermometer.medium")
            if snapshot.thermalState == .serious || snapshot.thermalState == .critical {
                symbol = "thermometer.sun.fill" // macOS is throttling for heat
                hot = true
            }
        }
        let value = celsius.map { Format.temperature($0, unit: false) } ?? "—"
        return compose(.sensors, [.symbol(symbol, size: 12), .text(label, value, template: "100°", emphasized: hot)])
    }

    private static func fans(_ context: Context) -> MenubarSegment {
        let fans = context.snapshot.smc?.fans ?? []
        let fastest = fans.max { $0.rpm < $1.rpm }
        let spinning = (fastest?.rpm ?? 0) > 0
        let angle = context.options.dynamicIcons && spinning ? context.fanAngle : 0
        let icon: Part = .fan(angle: angle, dimmed: context.options.dynamicIcons && !spinning)

        guard let fastest else { return compose(.fans, [icon, .text("FAN", "—", template: "6800")]) }
        switch context.options.fanStyle {
        case .rpm:
            return compose(.fans, [icon, .text("FAN", spinning ? String(format: "%.0f", fastest.rpm) : "OFF", template: "6800")])
        case .percent:
            return compose(.fans, [icon, .text("FAN", Format.percent(fastest.fraction), template: "100%")])
        case .iconOnly:
            return compose(.fans, [icon])
        }
    }

    private static func battery(_ context: Context) -> MenubarSegment {
        guard let battery = context.snapshot.battery else {
            return compose(.battery, [.symbol("powerplug.fill", size: 11)])
        }
        let dynamic = context.options.dynamicIcons
        let glyph: Part = .battery(level: battery.percent,
                                   charging: battery.isCharging,
                                   pluggedIn: battery.onACPower && !battery.isCharging,
                                   lowPower: dynamic && context.snapshot.lowPowerMode)
        let low = dynamic && !battery.onACPower && battery.percent <= 0.2

        switch context.options.batteryStyle {
        case .percent:
            return compose(.battery, [glyph, .text("BAT", Format.percent(battery.percent), template: "100%", emphasized: low)])
        case .time:
            let time = battery.minutesRemaining.map { Format.duration(minutes: $0) } ?? (battery.onACPower ? "AC" : "…")
            return compose(.battery, [glyph, .text(battery.isCharging ? "PIENO" : "RESTA", time, template: "10:00", emphasized: low)])
        case .watts:
            let watts = battery.watts.map { String(format: "%.0fW", abs($0)) } ?? "—"
            return compose(.battery, [glyph, .text(battery.isCharging ? "IN" : "OUT", watts, template: "100W")])
        case .iconOnly:
            return compose(.battery, [glyph])
        }
    }

    // MARK: - Parts

    private enum Part {
        case text(String, String, template: String, emphasized: Bool = false)
        case stacked(top: (String, String, Bool), bottom: (String, String, Bool))
        case graph([Double], width: CGFloat = 16)
        case cores([Double])
        case ring(Double)
        case symbol(String, size: CGFloat)
        case fan(angle: CGFloat, dimmed: Bool)
        case battery(level: Double, charging: Bool, pluggedIn: Bool, lowPower: Bool)
    }

    private static let partGap: CGFloat = 3
    /// Set per segment from the context (rendering always happens on the main thread).
    private static var showLabels = true
    private static var ink = Ink(base: .black, accent: .black, value: .black)

    /// Colors for one segment.
    private struct Ink {
        /// Text and neutral marks (tracks, outlines).
        var base: NSColor
        /// The visual: icon, graph, ring, battery fill.
        var accent: NSColor
        /// The value text.
        var value: NSColor

        init(base: NSColor, accent: NSColor, value: NSColor) {
            self.base = base
            self.accent = accent
            self.value = value
        }

        init(module: ModuleID, options: MenubarOptions, severity: Severity) {
            // labelColor resolves when the image is drawn, in the menu bar's own appearance.
            base = options.usesColor ? .labelColor : .black
            accent = base
            value = base
            if options.colorIcons, let custom = options.moduleColors[module] { accent = custom }
            if options.severityColors, let alert = severity.nsColor {
                accent = alert
                if severity >= .high { value = alert }
            }
        }
    }

    private static func compose(_ module: ModuleID, _ parts: [Part]) -> MenubarSegment {
        // Captured now: the image draws lazily, after other segments may have changed the statics.
        let labels = Self.showLabels
        let ink = Self.ink
        let widths = parts.map { width(of: $0, showLabels: labels) }
        let total = widths.reduce(0, +) + partGap * CGFloat(max(parts.count - 1, 0))
        return MenubarSegment(module: module, width: ceil(total)) { rect in
            var x = rect.minX
            for (part, width) in zip(parts, widths) {
                draw(part, in: NSRect(x: x, y: rect.minY, width: width, height: rect.height), showLabels: labels, ink: ink)
                x += width + partGap
            }
        }
    }

    private static func width(of part: Part, showLabels: Bool) -> CGFloat {
        switch part {
        case .text(let label, _, let template, _):
            let valueWidth = measure(template, valueFont(showLabels))
            return showLabels ? max(valueWidth, measure(label, labelFont)) : valueWidth
        case .stacked(let top, let bottom):
            let valueWidth = max(measure("999K", stackFont), measure(top.1, stackFont), measure(bottom.1, stackFont))
            return max(measure(top.0, stackFont), measure(bottom.0, stackFont)) + 2 + valueWidth
        case .graph(_, let width): return width
        case .cores(let cores): return CGFloat(max(cores.count, 1)) * 3
        case .ring: return 13
        case .symbol(_, let size): return size + 3
        case .fan: return 14
        case .battery(_, _, _, let lowPower): return lowPower ? 31 : 22
        }
    }

    private static func draw(_ part: Part, in rect: NSRect, showLabels: Bool, ink: Ink) {
        switch part {
        case .text(let label, let value, _, let emphasized):
            if showLabels {
                drawText(label, font: labelFont, color: ink.base.withAlphaComponent(0.6), in: NSRect(x: rect.minX, y: 11.5, width: rect.width, height: 9))
                drawText(value, font: emphasized ? valueFontBold : valueFont(true), color: ink.value,
                         in: NSRect(x: rect.minX, y: 0.5, width: rect.width, height: 12))
            } else {
                drawText(value, font: emphasized ? NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .bold) : valueFont(false),
                         color: ink.value, in: NSRect(x: rect.minX, y: 3.5, width: rect.width, height: 15))
            }

        case .stacked(let top, let bottom):
            let prefixWidth = max(measure(top.0, stackFont), measure(bottom.0, stackFont))
            for (line, y) in [(top, 10.5), (bottom, 0.5)] as [((String, String, Bool), CGFloat)] {
                let color = line.2 ? ink.value : ink.base.withAlphaComponent(0.45)
                let prefix = line.2 ? ink.accent : color
                drawText(line.0, font: stackFont, color: prefix, in: NSRect(x: rect.minX, y: y, width: prefixWidth, height: 11))
                drawText(line.1, font: stackFont, color: color, in: NSRect(x: rect.minX + prefixWidth + 2, y: y,
                                                                         width: rect.width - prefixWidth - 2, height: 11), alignment: .right)
            }

        case .graph(let values, _):
            // Nearly full menu bar height, like iStat Menus' CPU graph.
            let plot = rect.insetBy(dx: 0.5, dy: 2.5)
            // Faint backdrop so the graph reads as a graph even at low load.
            ink.base.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: plot.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2).fill()
            ink.accent.setFill()
            let slots = max(Int(plot.width / 2), 1)
            for (index, value) in values.suffix(slots).enumerated() {
                let offset = slots - min(values.count, slots) + index
                let height = max(1, plot.height * CGFloat(min(max(value, 0), 1)))
                NSBezierPath(roundedRect: NSRect(x: plot.minX + CGFloat(offset) * 2, y: plot.minY, width: 1.5, height: height),
                             xRadius: 0.5, yRadius: 0.5).fill()
            }

        case .cores(let cores):
            let plot = rect.insetBy(dx: 0, dy: 3)
            for (index, value) in cores.enumerated() {
                let bar = NSRect(x: plot.minX + CGFloat(index) * 3, y: plot.minY, width: 2, height: plot.height)
                ink.base.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
                ink.accent.setFill()
                var filled = bar
                filled.size.height = max(1.5, plot.height * CGFloat(min(max(value, 0), 1)))
                NSBezierPath(roundedRect: filled, xRadius: 1, yRadius: 1).fill()
            }

        case .ring(let fraction):
            let circle = NSRect(x: rect.midX - 6, y: rect.midY - 6, width: 12, height: 12).insetBy(dx: 1.25, dy: 1.25)
            let track = NSBezierPath(ovalIn: circle)
            track.lineWidth = 2.5
            ink.base.withAlphaComponent(0.25).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: circle.midX, y: circle.midY), radius: circle.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * CGFloat(min(max(fraction, 0), 1)), clockwise: true)
            arc.lineWidth = 2.5
            arc.lineCapStyle = .round
            ink.accent.setStroke()
            arc.stroke()

        case .symbol(let name, let size):
            drawSymbol(name, size: size, in: rect, color: ink.accent)

        case .fan(let angle, let dimmed):
            guard let symbol = symbolImage("fan", size: 12) else { return }
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byRadians: angle)
            transform.concat()
            let target = NSRect(x: -symbol.size.width / 2, y: -symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height)
            tinted(symbol, ink.accent).draw(in: target, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.5 : 1)
            NSGraphicsContext.restoreGraphicsState()

        case .battery(let level, let charging, let pluggedIn, let lowPower):
            let body = NSRect(x: rect.minX + 0.5, y: rect.midY - 5, width: 19, height: 10)
            let outline = NSBezierPath(roundedRect: body, xRadius: 2.5, yRadius: 2.5)
            outline.lineWidth = 1
            ink.base.withAlphaComponent(0.55).setStroke()
            outline.stroke()
            ink.base.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: body.maxX + 1, y: body.midY - 2, width: 1.5, height: 4), xRadius: 0.75, yRadius: 0.75).fill()

            let inner = body.insetBy(dx: 2, dy: 2)
            var fill = inner
            fill.size.width = max(1.5, inner.width * CGFloat(min(max(level, 0), 1)))
            ink.accent.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()

            if charging || pluggedIn {
                // Knock the bolt/plug out of the fill, then draw it, so it stays readable at any level.
                let name = charging ? "bolt.fill" : "powerplug.fill"
                if let glyph = symbolImage(name, size: 8) {
                    let glyphRect = NSRect(x: body.midX - glyph.size.width / 2, y: body.midY - glyph.size.height / 2,
                                           width: glyph.size.width, height: glyph.size.height)
                    glyph.draw(in: glyphRect.insetBy(dx: -1, dy: -1), from: .zero, operation: .destinationOut, fraction: 1)
                    tinted(glyph, ink.base).draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
            if lowPower {
                drawSymbol("leaf.fill", size: 8, in: NSRect(x: rect.minX + 22, y: rect.minY, width: 9, height: rect.height),
                           color: ink.base)
            }
        }
    }

    // MARK: - Text and symbols

    private static let labelFont = NSFont.systemFont(ofSize: 7.5, weight: .bold)
    private static let stackFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let valueFontBold = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .heavy)

    private static func valueFont(_ withLabel: Bool) -> NSFont {
        withLabel ? .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold) : .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
    }

    private static func measure(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func drawText(_ text: String, font: NSFont, color: NSColor, in rect: NSRect, alignment: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byClipping
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    private static var symbolCache: [String: NSImage] = [:]

    private static func symbolImage(_ name: String, size: CGFloat) -> NSImage? {
        let key = "\(name)@\(size)"
        if let cached = symbolCache[key] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
        symbolCache[key] = image
        return image
    }

    /// SF Symbols are black masks; paint them in `color` (drawn now, so dynamic colors resolve in the menu bar's appearance).
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        if color == .black { return image }
        let result = NSImage(size: image.size)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        result.unlockFocus()
        return result
    }

    private static func drawSymbol(_ name: String, size: CGFloat, in rect: NSRect, color: NSColor) {
        guard let image = symbolImage(name, size: size) else { return }
        let target = NSRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2,
                            width: image.size.width, height: image.size.height)
        tinted(image, color).draw(in: target)
    }

    /// Flattens a menu bar image for a light or dark bar (template images are tinted, colored ones resolve their colors).
    static func rasterize(_ image: NSImage, dark: Bool, scale: CGFloat = 2) -> NSImage {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let size = image.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        appearance.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(origin: .zero, size: size))
            if image.isTemplate {
                (dark ? NSColor.white : NSColor.black).set()
                NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: size)
        result.addRepresentation(bitmap)
        return result
    }
}

/// Value snapshot of the settings the renderer needs, so previews can render any style.
struct MenubarOptions {
    var showLabels: Bool
    var dynamicIcons: Bool
    var severityColors: Bool
    var colorIcons: Bool
    var moduleColors: [ModuleID: NSColor]
    var cpuStyle: CPUStyle
    var memoryStyle: MemoryStyle
    var diskStyle: DiskStyle
    var networkStyle: NetworkStyle
    var sensorSource: SensorSource
    var fanStyle: FanStyle
    var batteryStyle: BatteryStyle
    var cpuBusyThreshold: Double
    var temperatureHotThreshold: Double

    var usesColor: Bool { severityColors || colorIcons }

    init(_ settings: Settings) {
        showLabels = settings.showLabels
        dynamicIcons = settings.dynamicIcons
        severityColors = settings.severityColors
        colorIcons = settings.colorIcons
        moduleColors = Dictionary(uniqueKeysWithValues: ModuleID.allCases.map { ($0, settings.color(for: $0)) })
        cpuStyle = settings.cpuStyle
        memoryStyle = settings.memoryStyle
        diskStyle = settings.diskStyle
        networkStyle = settings.networkStyle
        sensorSource = settings.sensorSource
        fanStyle = settings.fanStyle
        batteryStyle = settings.batteryStyle
        cpuBusyThreshold = settings.cpuBusyThreshold
        temperatureHotThreshold = settings.temperatureHotThreshold
    }
}
