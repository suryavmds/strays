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

    static func image(count: Int, needsAttention: Bool) -> NSImage {
        let text = label(for: count)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = text.map { ($0 as NSString).size(withAttributes: attributes) } ?? .zero
        let width = glyphWidth + (text == nil ? 0 : 2 + ceil(textSize.width))

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            drawPaw()
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

    private static func drawPaw() {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        let size = symbol.size
        symbol.draw(in: CGRect(
            x: (glyphWidth - size.width) / 2,
            y: (height - size.height) / 2,
            width: size.width,
            height: size.height
        ))
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

    var body: some View {
        Image(nsImage: MenuBarIcon.image(count: model.badgeCount, needsAttention: model.needsAttention))
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let count = model.badgeCount
        let base = count == 0 ? "Strays, nothing running" : "Strays, \(count) running"
        return model.needsAttention ? base + ", needs attention" : base
    }
}
