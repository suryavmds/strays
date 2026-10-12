import SwiftUI
import StraysCore

/// One thing the palette can do.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let symbol: String
    var tint: Color = .secondary
    let run: @MainActor () -> Void

    /// What the query is matched against.
    var searchText: String { subtitle.map { "\(title) \($0)" } ?? title }
}

/// ⌘K: type a few letters, press Return. Everything the dashboard can do.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: DashboardState

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFieldFocused: Bool

    private var results: [PaletteCommand] {
        Array(FuzzyMatcher.rank(commands, query: query, by: \.searchText).prefix(40))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                field
                Divider()
                list
            }
            .frame(width: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.4), radius: 32, y: 14)
            .padding(.top, 90)
        }
        .onAppear { isFieldFocused = true }
        .onChange(of: query) { highlighted = 0 }
        .onExitCommand(perform: close)
        .accessibilityAddTraits(.isModal)
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "command")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Stop, open, copy, or go to…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($isFieldFocused)
                .onSubmit(runHighlighted)
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .accessibilityLabel("Command")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    let results = results
                    if results.isEmpty {
                        Text("No matching command")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 22)
                    }
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                        PaletteRow(command: command, isHighlighted: index == highlighted)
                            .id(command.id)
                            .onTapGesture { run(command) }
                            .onHover { if $0 { highlighted = index } }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 340)
            .onChange(of: highlighted) {
                let results = results
                if results.indices.contains(highlighted) {
                    proxy.scrollTo(results[highlighted].id)
                }
            }
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let count = results.count
        guard count > 0 else { return .handled }
        highlighted = (highlighted + delta + count) % count
        return .handled
    }

    private func runHighlighted() {
        let results = results
        guard results.indices.contains(highlighted) else { return }
        run(results[highlighted])
    }

    private func run(_ command: PaletteCommand) {
        close()
        command.run()
    }

    private func close() {
        state.isPaletteOpen = false
    }

    // MARK: - Commands

    private var commands: [PaletteCommand] {
        var commands: [PaletteCommand] = []

        for stray in model.snapshot.strays {
            let context = stray.project?.name ?? stray.subtitle
            let accent = Theme.accent(for: stray)
            if let port = stray.primaryPort, port.transport == .tcp {
                commands.append(PaletteCommand(id: "open:\(stray.id)", title: "Open localhost:\(port.port)", subtitle: stray.title, symbol: "safari", tint: accent) {
                    model.open(port)
                })
            }
            commands.append(PaletteCommand(id: "show:\(stray.id)", title: "Inspect \(stray.title)", subtitle: context, symbol: "sidebar.trailing", tint: accent) {
                state.select(stray)
            })
            if stray.canBeStopped {
                commands.append(PaletteCommand(id: "stop:\(stray.id)", title: "Stop \(stray.title)", subtitle: context, symbol: "stop.fill", tint: Theme.lan) {
                    state.select(stray)
                    model.requestStop(stray)
                })
            }
            if let port = stray.primaryPort, port.transport == .tcp {
                commands.append(PaletteCommand(id: "copy:\(stray.id)", title: "Copy URL of \(stray.title)", subtitle: "localhost:\(port.port)", symbol: "doc.on.doc") {
                    model.copyURL(of: port)
                })
            }
        }

        commands.append(PaletteCommand(id: "go:all", title: "Go to All", subtitle: nil, symbol: "square.grid.2x2") { state.sidebar = .all })
        commands.append(PaletteCommand(id: "go:ports", title: "Go to Listening Ports", subtitle: nil, symbol: "point.3.connected.trianglepath.dotted") { state.sidebar = .ports })
        commands.append(PaletteCommand(id: "go:others", title: "Go to Apps & System", subtitle: nil, symbol: "macwindow.on.rectangle") { state.sidebar = .others })
        for group in model.projectGroups {
            commands.append(PaletteCommand(id: "go:\(group.id)", title: "Go to \(group.title)", subtitle: "Project", symbol: "folder") {
                state.sidebar = .project(group.id)
            })
            if let project = group.project {
                commands.append(PaletteCommand(id: "reveal:\(group.id)", title: "Reveal \(project.name) in Finder", subtitle: nil, symbol: "arrow.up.forward.app") {
                    model.reveal(project)
                })
            }
        }
        for mode in DashboardViewMode.allCases {
            commands.append(PaletteCommand(id: "view:\(mode.rawValue)", title: "View as \(mode.title)", subtitle: nil, symbol: mode.symbol) {
                state.viewMode = mode
            })
        }
        commands.append(PaletteCommand(id: "inspector", title: "Toggle Inspector", subtitle: nil, symbol: "sidebar.trailing") {
            state.isInspectorOpen.toggle()
        })
        commands.append(PaletteCommand(id: "refresh", title: "Refresh Now", subtitle: nil, symbol: "arrow.clockwise") { model.refresh() })
        return commands
    }
}

private struct PaletteRow: View {
    let command: PaletteCommand
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(command.tint))
                .frame(width: 22)
            Text(command.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            if let subtitle = command.subtitle {
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isHighlighted {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .foregroundStyle(isHighlighted ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isHighlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }
}
