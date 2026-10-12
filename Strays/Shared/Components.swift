import SwiftUI
import StraysCore

/// A port number in a capsule. LAN-visible ports get a red outline, because
/// other machines on the network can reach them.
struct PortChip: View {
    let port: PortSummary
    var tint: Color = Theme.dev

    var body: some View {
        HStack(spacing: 3) {
            if port.isLANVisible {
                Image(systemName: "wifi")
                    .font(.system(size: 8, weight: .bold))
            }
            Text(verbatim: ":\(port.port)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            if port.transport == .udp {
                Text("udp")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.7)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(port.isLANVisible ? Theme.lan : tint)
        .background((port.isLANVisible ? Theme.lan : tint).opacity(0.13), in: shape)
        .overlay {
            if port.isLANVisible {
                shape.strokeBorder(Theme.lan.opacity(0.7), lineWidth: 1)
            }
        }
        .help(help)
        .accessibilityLabel(accessibilityText)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
    }

    private var help: String {
        let addresses = port.addresses.joined(separator: ", ")
        return port.isLANVisible
            ? "Port \(port.port) is reachable from your network (bound to \(addresses))"
            : "Port \(port.port), this Mac only (bound to \(addresses))"
    }

    private var accessibilityText: String {
        "Port \(port.port)" + (port.transport == .udp ? " UDP" : "") + (port.isLANVisible ? ", visible on your network" : "")
    }
}

/// As many of a stray's ports as fit, then a count of the rest.
struct PortChips: View {
    let ports: [PortSummary]
    var limit = 2
    var tint: Color = Theme.dev

    var body: some View {
        let most = min(limit, ports.count)
        if most > 0 {
            ViewThatFits(in: .horizontal) {
                ForEach((1...most).reversed(), id: \.self) { count in
                    row(showing: count)
                }
            }
        }
    }

    private func row(showing count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(ports.prefix(count)) { port in
                PortChip(port: port, tint: tint)
            }
            if ports.count > count {
                Text(verbatim: "+\(ports.count - count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help(ports.dropFirst(count).map { ":\($0.port)" }.joined(separator: "  "))
            }
        }
    }
}

/// The coloured dot at the start of a row. It glows while the process is busy.
struct StatusDot: View {
    let color: Color
    var isBusy = false

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(isBusy ? 0.9 : 0), radius: isBusy ? 4 : 0)
            .accessibilityHidden(true)
    }
}

/// A small round icon button that lights up on hover.
struct IconButton: View {
    let symbol: String
    let label: String
    var tint: Color = .primary
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? tint : .secondary)
                .frame(width: 24, height: 24)
                .background(isHovering ? AnyShapeStyle(tint.opacity(0.16)) : AnyShapeStyle(.quaternary.opacity(0.6)), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Reports whether the window this view lives in is actually on screen, so
/// the monitor can slow down when nobody is looking.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        TrackingView(onChange: onChange)
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: @MainActor (Bool) -> Void
        private var lastReported: Bool?

        init(onChange: @escaping @MainActor (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(visibilityChanged),
                    name: NSWindow.didChangeOcclusionStateNotification,
                    object: window
                )
            }
            visibilityChanged()
        }

        @objc private func visibilityChanged() {
            let isVisible = window?.occlusionState.contains(.visible) ?? false
            guard isVisible != lastReported else { return }
            lastReported = isVisible
            onChange(isVisible)
        }
    }
}
