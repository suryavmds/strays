import AppKit
import SwiftUI

/// Draws the menu bar icon: a paw, a live count beside it, and a dot at the
/// paw's shoulder when something needs attention.
///
/// The result is a template image, so macOS tints it for light and dark
/// menu bars and for the highlighted state.
@MainActor
enum MenuBarIcon {
    static let height: CGFloat = 18
    private static let glyphWidth: CGFloat = 18
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

    /// - Parameter pawScale: 1 at rest. The pulse that greets a new stray
    ///   is a few frames of this image at slightly larger scales.
    static func image(count: Int, needsAttention: Bool, pawScale: CGFloat = 1) -> NSImage {
        let text = label(for: count)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = text.map { ($0 as NSString).size(withAttributes: attributes) } ?? .zero
        let width = glyphWidth + (text == nil ? 0 : 2 + ceil(textSize.width))

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            drawPaw(scale: pawScale)
            if needsAttention { drawAttentionDot() }
            if let text {
                let origin = CGPoint(x: glyphWidth + 2, y: (height - textSize.height) / 2)
                (text as NSString).draw(at: origin, withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Strays"
        return image
    }

    static func label(for count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    private static func drawPaw(scale: CGFloat) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        // Scaled about its centre, and never past the icon's own bounds.
        let width = min(symbol.size.width * scale, glyphWidth)
        let height = min(symbol.size.height * scale, Self.height)
        symbol.draw(in: CGRect(x: (glyphWidth - width) / 2, y: (Self.height - height) / 2, width: width, height: height))
    }

    /// A dot at the top-right of the paw, with a clear ring punched around it
    /// so it reads as separate from the glyph.
    private static func drawAttentionDot() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let center = CGPoint(x: glyphWidth - 3.2, y: height - 3.6)
        context.saveGState()
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(x: center.x - 4.2, y: center.y - 4.2, width: 8.4, height: 8.4))
        context.restoreGState()
        NSColor.black.setFill()
        context.fillEllipse(in: CGRect(x: center.x - 2.7, y: center.y - 2.7, width: 5.4, height: 5.4))
    }
}

struct MenuBarLabel: View {
    let model: AppModel
    @State private var pawScale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    /// A short swell and settle. A status item cannot be animated, so the
    /// pulse is a handful of redrawn frames.
    private static let pulse: [CGFloat] = [1.12, 1.24, 1.3, 1.2, 1.06, 0.97, 1]

    var body: some View {
        Image(nsImage: MenuBarIcon.image(count: model.badgeCount, needsAttention: model.needsAttention, pawScale: pawScale))
            .accessibilityLabel(accessibilityText)
            .task {
                // The label is the one view that exists from launch, so it
                // is where a launch-time request to open a window is served.
                if LaunchOptions.opensDashboard {
                    openWindow(id: WindowID.dashboard)
                }
            }
            .onChange(of: model.badgeCount) { old, new in
                // Only when something new appears, never when one goes away.
                guard new > old, model.hasLoaded, !reduceMotion else { return }
                Task {
                    for scale in Self.pulse {
                        pawScale = scale
                        try? await Task.sleep(for: .milliseconds(65))
                    }
                }
            }
    }

    private var accessibilityText: String {
        let count = model.badgeCount
        let base = count == 0 ? "Strays, nothing running" : "Strays, \(count) running"
        return model.needsAttention ? base + ", needs attention" : base
    }
}
