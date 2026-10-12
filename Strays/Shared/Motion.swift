import SwiftUI
import StraysCore

// MARK: - Dissolve

/// Strays' compiled Metal shaders, if this build has them.
///
/// The shader library is built by a script phase that is skipped when the
/// Metal toolchain is not installed, so its absence is a normal condition
/// and every use has a fallback.
enum Shaders {
    static let library: ShaderLibrary? = {
        guard let url = Bundle.main.url(forResource: "Strays", withExtension: "metallib") else { return nil }
        return ShaderLibrary(url: url)
    }()

    static var isAvailable: Bool { library != nil }
}

/// Breaks a view up with the dissolve shader. `progress` runs from 0 (the
/// untouched view) to 1 (nothing left).
///
/// `@preconcurrency Animatable`: a view modifier lives on the main actor
/// and SwiftUI only ever animates it there, but the protocol does not say so.
private struct ShaderDissolve: ViewModifier, @preconcurrency Animatable {
    var progress: Double
    let library: ShaderLibrary

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let progress = progress
        let library = library
        content.visualEffect { view, proxy in
            view.layerEffect(
                library.dissolve(.float2(proxy.size), .float(progress)),
                maxSampleOffset: .zero,
                isEnabled: progress > 0
            )
        }
    }
}

/// The same idea without a shader: the view lifts, blurs, and fades.
private struct EvaporateDissolve: ViewModifier, @preconcurrency Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .blur(radius: progress * 9)
            .opacity(1 - progress)
            .scaleEffect(1 - progress * 0.06)
            .offset(y: -progress * 6)
    }
}

extension AnyTransition {
    /// How a card arrives and, above all, how it leaves when something is
    /// stopped: it dissolves. With Reduce Motion it simply fades.
    static func strayCard(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let insertion = AnyTransition.scale(scale: 0.94).combined(with: .opacity)
        let removal: AnyTransition
        if let library = Shaders.library {
            removal = .modifier(
                active: ShaderDissolve(progress: 1, library: library),
                identity: ShaderDissolve(progress: 0, library: library)
            )
        } else {
            removal = .modifier(active: EvaporateDissolve(progress: 1), identity: EvaporateDissolve(progress: 0))
        }
        return .asymmetric(insertion: insertion, removal: removal.animation(.easeIn(duration: 0.65)))
    }

    /// The compact version, for rows in the menu bar popover.
    static func strayRow(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)),
            removal: .modifier(active: EvaporateDissolve(progress: 1), identity: EvaporateDissolve(progress: 0))
                .animation(.easeIn(duration: 0.4))
        )
    }
}

#if DEBUG
extension View {
    /// The dissolve frozen at one point, for the snapshot renderer: a
    /// transition cannot be photographed, but a single frame of it can.
    @ViewBuilder
    func dissolveFrame(_ progress: Double) -> some View {
        if let library = Shaders.library {
            modifier(ShaderDissolve(progress: progress, library: library))
        } else {
            modifier(EvaporateDissolve(progress: progress))
        }
    }
}
#endif

// MARK: - Heartbeat

/// A soft, slow pulse of light behind something that is busy. Still when
/// Reduce Motion is on, and absent when the thing is idle, so nothing
/// animates unless a process is actually working.
struct HeartbeatGlow: ViewModifier {
    let color: Color
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if !isActive {
            content
        } else if reduceMotion {
            content.shadow(color: color.opacity(0.55), radius: 6)
        } else {
            content.phaseAnimator([false, true]) { view, isBright in
                view.shadow(color: color.opacity(isBright ? 0.8 : 0.22), radius: isBright ? 9 : 3)
            } animation: { _ in
                .easeInOut(duration: 0.95)
            }
        }
    }
}

extension View {
    func heartbeat(_ color: Color, isActive: Bool) -> some View {
        modifier(HeartbeatGlow(color: color, isActive: isActive))
    }
}

// MARK: - Empty states

/// A trail of paw prints that walks across, pauses, and fades: the small
/// illustration shown when there is nothing to list.
struct PawTrail: View {
    var tint: Color = .secondary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let steps = 4

    var body: some View {
        Group {
            if reduceMotion {
                trail(visible: Self.steps, fade: 1)
            } else {
                PhaseAnimator(Array(0...(Self.steps + 2))) { phase in
                    // Phases 1...steps place one print each; the last two fade and rest.
                    trail(visible: min(phase, Self.steps), fade: phase > Self.steps ? 0 : 1)
                } animation: { phase in
                    phase == 0 ? .easeOut(duration: 0.5).delay(0.6) : .spring(response: 0.34, dampingFraction: 0.6)
                }
            }
        }
        .frame(width: 132, height: 56)
        .accessibilityHidden(true)
    }

    private func trail(visible: Int, fade: Double) -> some View {
        HStack(spacing: 10) {
            ForEach(0..<Self.steps, id: \.self) { index in
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(tint.opacity(0.35 + Double(index) * 0.15))
                    .rotationEffect(.degrees(index.isMultiple(of: 2) ? -16 : 14))
                    .offset(y: index.isMultiple(of: 2) ? -7 : 7)
                    .scaleEffect(index < visible ? 1 : 0.4)
                    .opacity(index < visible ? fade : 0)
            }
        }
    }
}

/// An empty state with the paw trail above its message.
struct EmptyStateView<Actions: View>: View {
    let title: String
    let message: String
    var tint: Color = .secondary
    @ViewBuilder var actions: Actions

    init(_ title: String, message: String, tint: Color = .secondary, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.message = message
        self.tint = tint
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 10) {
            PawTrail(tint: tint)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            actions
                .padding(.top, 4)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Surfaces

/// The translucent fill behind a card. With Reduce Transparency it becomes
/// a solid control colour; the content on top is unchanged.
struct CardSurface: View {
    let accent: Color
    var intensity: Double = 0.07
    var cornerRadius: CGFloat = 14
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if reduceTransparency {
                shape.fill(Color(nsColor: .controlBackgroundColor))
            } else {
                shape.fill(.ultraThinMaterial)
            }
            shape.fill(LinearGradient(
                colors: [accent.opacity(intensity), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        }
    }
}

/// The window backdrop: see-through, unless Reduce Transparency is on.
struct WindowBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            VisualEffectBackground()
        }
    }
}
