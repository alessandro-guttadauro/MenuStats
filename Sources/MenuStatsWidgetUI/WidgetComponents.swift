import SwiftUI

// Building blocks of the widgets: drawn with plain shapes so they render the same in WidgetKit
// (where views are archived, not live) and in the dropdown.

/// Circular gauge with a rounded end.
public struct WidgetRing: View {
    var fraction: Double
    var color: Color
    var lineWidth: CGFloat

    public init(fraction: Double, color: Color, lineWidth: CGFloat = 6) {
        self.fraction = fraction; self.color = color; self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(fraction, 1)))
                .stroke(
                    AngularGradient(colors: [color.opacity(0.75), color], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(360 * max(min(fraction, 1), 0.01))),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

/// Ring with the value in the middle.
struct LabeledRing: View {
    var fraction: Double
    var color: Color
    var text: String
    var lineWidth: CGFloat = 6
    var fontSize: CGFloat = 13

    var body: some View {
        WidgetRing(fraction: fraction, color: color, lineWidth: lineWidth)
            .overlay(
                Text(text)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(lineWidth + 2)
            )
    }
}

/// Area chart of recent values, scaled to `maximum` (or to the largest value).
struct Sparkline: View {
    var values: [Double]
    var color: Color
    var maximum: Double?
    var minimum: Double?
    var filled = true

    var body: some View {
        GeometryReader { proxy in
            let points = normalized(in: proxy.size)
            if points.count >= 2 {
                ZStack {
                    if filled {
                        area(points, height: proxy.size.height)
                            .fill(LinearGradient(colors: [color.opacity(0.32), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    }
                    line(points).stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            } else {
                Capsule().fill(color.opacity(0.15)).frame(height: 2).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    private func normalized(in size: CGSize) -> [CGPoint] {
        let finite = values.filter(\.isFinite)
        guard finite.count >= 2 else { return [] }
        let low = minimum ?? 0
        let high = max(maximum ?? (finite.max() ?? 1), low + 0.000_001)
        let step = size.width / CGFloat(finite.count - 1)
        return finite.enumerated().map { index, value in
            let fraction = (min(max(value, low), high) - low) / (high - low)
            return CGPoint(x: CGFloat(index) * step, y: size.height - 1 - CGFloat(fraction) * (size.height - 2))
        }
    }

    private func line(_ points: [CGPoint]) -> Path {
        Path { path in
            path.move(to: points[0])
            for index in 1..<points.count {
                let previous = points[index - 1], point = points[index]
                let middle = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
                path.addQuadCurve(to: middle, control: previous)
                if index == points.count - 1 { path.addQuadCurve(to: point, control: middle) }
            }
        }
    }

    private func area(_ points: [CGPoint], height: CGFloat) -> Path {
        var path = line(points)
        path.addLine(to: CGPoint(x: points.last!.x, y: height))
        path.addLine(to: CGPoint(x: points[0].x, y: height))
        path.closeSubpath()
        return path
    }
}

/// Horizontal bar.
struct CapsuleBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.18))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.8), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// Bar split in colored parts (memory composition).
struct SegmentedBar: View {
    var parts: [(fraction: Double, color: Color)]
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1.5) {
                ForEach(parts.indices, id: \.self) { index in
                    Rectangle().fill(parts[index].color)
                        .frame(width: max(0, proxy.size.width * min(parts[index].fraction, 1) - 1.5))
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.1))
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}

/// Element icon and name, with optional trailing text.
struct WidgetHeader: View {
    var element: WidgetElement
    var title: String?
    var trailing: String?
    var color: Color?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: element.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color ?? WidgetPalette.color(element))
            Text(title ?? element.title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Large number with a smaller unit.
struct BigValue: View {
    var value: String
    var unit: String = ""
    var size: CGFloat = 30
    var color: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// "Label ……… value" row with an optional color dot.
struct StatRow: View {
    var label: String
    var value: String
    var color: Color?

    var body: some View {
        HStack(spacing: 5) {
            if let color { Circle().fill(color).frame(width: 6, height: 6) }
            Text(label).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(value).fontWeight(.medium).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 11))
    }
}

/// Soft background tinted with the element's color.
public struct WidgetBackground: View {
    var color: Color
    public init(element: WidgetElement) { color = WidgetPalette.color(element) }

    public var body: some View {
        ZStack {
            Rectangle().fill(.background)
            LinearGradient(colors: [color.opacity(0.16), color.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
