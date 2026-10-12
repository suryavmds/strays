import Charts
import SwiftUI
import StraysCore

/// When each thing started today: one bar per stray, from its start until now.
struct StrayTimelineView: View {
    @Bindable var state: DashboardState
    let strays: [Stray]

    private let now = Date()

    private var dayStart: Date { Calendar.current.startOfDay(for: now) }

    /// The oldest first, so the chart reads top to bottom in start order.
    private var ordered: [Stray] {
        strays.sorted { $0.startDate < $1.startDate }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                legend
                Chart(ordered) { stray in
                    // A faint lane across the whole day ties each label to its bar.
                    BarMark(
                        xStart: .value("Day start", dayStart),
                        xEnd: .value("Now", now),
                        y: .value("Name", label(for: stray)),
                        height: .fixed(16)
                    )
                    .foregroundStyle(.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityHidden(true)

                    BarMark(
                        xStart: .value("Started", max(stray.startDate, dayStart)),
                        xEnd: .value("Now", now),
                        y: .value("Name", label(for: stray)),
                        height: .fixed(16)
                    )
                    .foregroundStyle(barStyle(for: stray))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .opacity(state.selection == nil || state.selection == stray.id ? 1 : 0.45)
                    .annotation(position: .overlay, alignment: .leading) {
                        if stray.startDate < dayStart {
                            Text("since \(stray.startDate.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.leading, 6)
                        }
                    }
                }
                .chartXScale(domain: dayStart...max(now, dayStart.addingTimeInterval(3_600)))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.secondary.opacity(0.25))
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisValueLabel()
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                guard let plot = proxy.plotFrame else { return }
                                let y = location.y - geometry[plot].origin.y
                                if let name: String = proxy.value(atY: y),
                                   let stray = ordered.first(where: { label(for: $0) == name }) {
                                    state.select(stray)
                                }
                            }
                    }
                }
                .frame(height: CGFloat(max(ordered.count, 1)) * 34 + 36)
                .accessibilityLabel("Timeline of when each item started today")
            }
            .padding(20)
        }
    }

    private var legend: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
            Text("Today, \(dayStart.formatted(.dateTime.month(.wide).day()))")
                .font(.system(size: 13, weight: .semibold))
            Text("Bars run from when each thing started until now.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .foregroundStyle(.primary)
    }

    /// Chart categories must be unique; two strays can share a title.
    private func label(for stray: Stray) -> String {
        let duplicates = strays.filter { $0.title == stray.title }.count > 1
        return duplicates && stray.rootPID != 0 ? "\(stray.title) (\(stray.rootPID))" : stray.title
    }

    private func barStyle(for stray: Stray) -> AnyShapeStyle {
        if stray.isLANVisible { return AnyShapeStyle(Theme.lan.gradient) }
        let accent = Theme.accent(for: stray)
        return accent == Theme.neutral ? AnyShapeStyle(Color.secondary.opacity(0.55).gradient) : AnyShapeStyle(accent.gradient)
    }
}
