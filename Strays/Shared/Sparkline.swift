import Charts
import SwiftUI
import StraysCore

/// A tiny line for a card: cheap to draw, no axes, no labels.
struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.dev
    /// Values at or below this draw as a flat line at the bottom.
    var floor: Double = 0

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let top = max(values.max() ?? 0, floor + 1)
            let step = size.width / CGFloat(values.count - 1)
            func point(_ index: Int) -> CGPoint {
                let normalized = (values[index] - floor) / (top - floor)
                return CGPoint(x: CGFloat(index) * step, y: size.height - 1 - CGFloat(normalized) * (size.height - 2))
            }

            var line = Path()
            line.move(to: point(0))
            for index in 1..<values.count { line.addLine(to: point(index)) }

            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()

            context.fill(area, with: .linearGradient(
                Gradient(colors: [color.opacity(0.28), color.opacity(0)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// A labelled live chart for the inspector, drawn with Swift Charts.
struct MetricChart: View {
    let title: String
    let value: String
    let samples: [MetricsHistory.Sample]
    let color: Color
    /// CPU reads best against zero; memory reads best zoomed to its range.
    var includesZero = true
    let reading: (MetricsHistory.Sample) -> Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .contentTransition(.numericText())
            }
            Chart(samples) { sample in
                AreaMark(x: .value("Time", sample.date), y: .value(title, reading(sample)))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.3), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", sample.date), y: .value(title, reading(sample)))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(.secondary.opacity(0.35))
                }
            }
            .chartYScale(domain: .automatic(includesZero: includesZero))
            .frame(height: 44)
        }
        .padding(10)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value)")
    }
}

/// A translucent backdrop that shows the desktop through the window.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}
