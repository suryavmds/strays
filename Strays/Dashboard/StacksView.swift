import SwiftUI
import StraysCore

/// Stacks: named groups of things that are started and stopped together.
struct StacksView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.stacks.isEmpty {
            EmptyStateView(
                "No stacks yet",
                message: "A stack is everything one project needs, started and stopped with one click: a dev server, a worker, a compose project, a Homebrew service.",
                tint: Theme.dev
            ) {
                Button("New Stack") { model.addStack(named: "New Stack") }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.stacks) { stack in
                        StackCard(stack: stack)
                    }
                    Button {
                        model.addStack(named: "New Stack")
                    } label: {
                        Label("New Stack", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    Text("Stacks are saved in \(Text(verbatim: "~/Library/Application Support/Strays/stacks.json").font(.system(size: 10.5, design: .monospaced))).")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(Theme.listSpring, value: model.stacks)
            }
        }
    }
}

private struct StackCard: View {
    let stack: Stack
    @Environment(AppModel.self) private var model
    @State private var name: String
    @State private var isRenaming = false
    @State private var isAddingCommand = false
    @State private var isConfirmingDelete = false
    @FocusState private var isNameFocused: Bool

    init(stack: Stack) {
        self.stack = stack
        _name = State(initialValue: stack.name)
    }

    private var runningCount: Int { stack.items.filter { model.status(of: $0).isRunning }.count }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if stack.items.isEmpty {
                Text("Nothing in this stack yet. Add a command, or something that is running now.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 2) {
                    ForEach(stack.items) { item in
                        StackItemRow(item: item, stack: stack)
                    }
                }
            }
            if isAddingCommand {
                CommandForm { command, directory in
                    model.add(.command(command, in: directory), to: stack)
                    isAddingCommand = false
                } onCancel: {
                    isAddingCommand = false
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            addMenu
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardSurface(accent: Theme.dev) }
        .overlay { shape.strokeBorder(.primary.opacity(0.08)) }
        .animation(Theme.hoverSpring, value: isAddingCommand)
        .confirmationDialog("Delete the stack “\(stack.name)”?", isPresented: $isConfirmingDelete) {
            Button("Delete Stack", role: .destructive) { model.delete(stack) }
        } message: {
            Text("Nothing that is running will be stopped. Only the stack itself is removed.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.dev)
                .frame(width: 34, height: 34)
                .background(Theme.dev.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("Stack name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .focused($isNameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { isRenaming = false }
                        .onChange(of: isNameFocused) { if !isNameFocused { commitRename() } }
                        .accessibilityLabel("Stack name")
                } else {
                    Text(stack.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .onTapGesture(count: 2, perform: beginRename)
                        .help("Double-click to rename")
                }
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 8)

            Button {
                model.start(stack)
            } label: {
                Label("Start All", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .tint(.green)
            .disabled(stack.items.isEmpty || runningCount == stack.items.count)

            Button {
                model.stop(stack)
            } label: {
                Label("Stop All", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .tint(Theme.lan)
            .disabled(runningCount == 0)

            Menu {
                Button("Rename") { beginRename() }
                Button("Delete Stack…", role: .destructive) { isConfirmingDelete = true }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 16, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
    }

    private func beginRename() {
        name = stack.name
        isRenaming = true
        isNameFocused = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != stack.name { model.rename(stack, to: trimmed) }
    }

    private var summary: String {
        if stack.items.isEmpty { return "Empty" }
        return "\(runningCount) of \(stack.items.count) running"
    }

    /// Things that can be added: a new command, something running right
    /// now, or a compose project, service, or container that exists.
    private var addMenu: some View {
        Menu {
            Button {
                isAddingCommand = true
            } label: {
                Label("Command…", systemImage: "terminal")
            }

            let running = model.activeStrays.compactMap { stray in StackItem(recreating: stray).map { (stray, $0) } }
            if !running.isEmpty {
                Section("Running now") {
                    ForEach(running, id: \.0.id) { stray, item in
                        Button {
                            model.add(item, to: stack)
                        } label: {
                            Label(stray.title, systemImage: item.symbol)
                        }
                    }
                }
            }

            let stopped = (model.containers + model.brewServices).filter { !$0.isRunning }.compactMap { stray in
                StackItem(recreating: stray).map { (stray, $0) }
            }
            if !stopped.isEmpty {
                Section("Stopped") {
                    ForEach(stopped, id: \.0.id) { stray, item in
                        Button {
                            model.add(item, to: stack)
                        } label: {
                            Label(item.title, systemImage: item.symbol)
                        }
                    }
                }
            }
        } label: {
            Label("Add", systemImage: "plus")
                .font(.system(size: 11.5, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct StackItemRow: View {
    let item: StackItem
    let stack: Stack
    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    private var status: StackItemStatus { model.status(of: item) }
    private var isBusy: Bool { model.busyStackItems.contains(item.id) }

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(statusColor.gradient)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Image(systemName: item.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.value)
                    .font(.system(size: 12, weight: .medium, design: item.kind == .command ? .monospaced : .default))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                if isHovering {
                    IconButton(symbol: "minus", label: "Remove from stack") { model.remove(item, from: stack) }
                        .transition(.opacity)
                }
                if status == .missing {
                    Text("Missing")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.brew)
                } else if status == .running {
                    IconButton(symbol: "stop.fill", label: "Stop \(item.value)", tint: Theme.lan) { model.stop(item) }
                } else {
                    IconButton(symbol: "play.fill", label: "Start \(item.value)", tint: .green) { model.start(item) }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.primary.opacity(isHovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(Theme.hoverSpring) { isHovering = hovering }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.kindLabel) \(item.value), \(statusText)")
    }

    private var statusColor: Color {
        switch status {
        case .running: .green
        case .partial: Theme.brew
        case .stopped: .secondary.opacity(0.5)
        case .missing: Theme.brew.opacity(0.6)
        }
    }

    private var statusText: String {
        switch status {
        case .running: "running"
        case let .partial(running, total): "\(running) of \(total) running"
        case .stopped: "stopped"
        case .missing: "does not exist"
        }
    }

    private var detail: String {
        var parts = [item.kindLabel]
        if case let .partial(running, total) = status { parts.append("\(running) of \(total) containers up") }
        if status == .missing { parts.append("not found on this Mac") }
        if let directory = item.directory { parts.append((directory as NSString).abbreviatingWithTildeInPath) }
        return parts.joined(separator: " · ")
    }
}

/// A command and the folder to run it in.
private struct CommandForm: View {
    let onAdd: (String, String) -> Void
    let onCancel: () -> Void

    @State private var command = ""
    @State private var directory = ""
    @FocusState private var isCommandFocused: Bool

    private var isValid: Bool {
        !command.trimmingCharacters(in: .whitespaces).isEmpty && FileManager.default.fileExists(atPath: expandedDirectory)
    }

    private var expandedDirectory: String {
        (directory.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Command, such as npm run dev", text: $command)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($isCommandFocused)
                .onSubmit(add)
            HStack(spacing: 6) {
                TextField("Folder to run it in", text: $directory)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(add)
                Button("Choose…", action: chooseFolder)
            }
            HStack(spacing: 8) {
                Button("Add Command", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
                Button("Cancel", action: onCancel)
                Text("Runs through your login shell, so it sees the same PATH as in a terminal.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { isCommandFocused = true }
    }

    private func add() {
        guard isValid else { return }
        onAdd(command.trimmingCharacters(in: .whitespaces), expandedDirectory)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            directory = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}
