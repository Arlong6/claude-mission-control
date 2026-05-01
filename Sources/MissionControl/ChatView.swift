import SwiftUI
import UserNotifications
import AppKit
import UniformTypeIdentifiers

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft: String = ""
    @Published var streaming: Bool = false
    @Published var liveAssistant: String = ""
    @Published var errorBanner: String?
    @Published var pendingAttachments: [URL] = []

    private(set) var project: Project
    weak var store: ProjectStore?

    init(project: Project, store: ProjectStore? = nil) {
        self.project = project
        self.store = store
        loadHistory()
    }

    /// Refresh project metadata in place (called when ProjectStore re-scans).
    /// Crucially does NOT reset streaming state or messages — that would lose
    /// any in-flight response if the view tree was just torn down and rebuilt.
    func update(project: Project) {
        self.project = project
    }

    func addPasted(image: NSImage) {
        guard let url = AttachmentStore.save(image: image) else {
            errorBanner = "Failed to save pasted image"
            return
        }
        pendingAttachments.append(url)
    }

    func removePending(_ url: URL) {
        pendingAttachments.removeAll { $0 == url }
        try? FileManager.default.removeItem(at: url)
    }

    func loadHistory() {
        guard let session = project.sessions.first else {
            messages = []
            return
        }
        let loaded = JSONLLoader.load(from: session.url, maxMessages: 200)
        messages = loaded
    }

    /// Re-scan disk for the project's freshest .jsonl and reload (handles claude
    /// having created a forked session file as well as appended-to existing ones).
    func reconcileFromDisk() {
        let updated = ProjectScanner.scanSessions(in: project.claudeDir)
        guard let session = updated.first else { return }
        let loaded = JSONLLoader.load(from: session.url, maxMessages: 200)
        if loaded.count >= messages.count - 1 { // avoid replacing with shorter (truncated) view
            messages = loaded
        }
    }

    var sessionID: String? { project.sessions.first?.id }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentsToSend = pendingAttachments
        guard (!text.isEmpty || !attachmentsToSend.isEmpty), !streaming else { return }
        var parts: [ContentPart] = attachmentsToSend.map { .image($0) }
        if !text.isEmpty { parts.append(.text(text)) }
        let userMsg = ChatMessage(id: UUID().uuidString, role: .user, parts: parts, timestamp: Date(), isError: false)
        messages.append(userMsg)
        draft = ""
        pendingAttachments = []
        streaming = true
        liveAssistant = ""
        errorBanner = nil

        let projectName = project.shortName
        let sid = sessionID
        let promptForClaude = text.isEmpty ? "Please describe the attached image(s)." : text

        ClaudeBackend.shared.send(
            prompt: promptForClaude,
            cwd: project.originalPath,
            sessionId: sid,
            attachments: attachmentsToSend,
            onChunk: { [weak self] chunk in
                Task { @MainActor in
                    self?.liveAssistant += chunk
                }
            },
            onError: { [weak self] errChunk in
                Task { @MainActor in
                    if (self?.errorBanner ?? "").isEmpty { self?.errorBanner = errChunk }
                    else { self?.errorBanner! += errChunk }
                }
            },
            onFinish: { [weak self] fullStdout, fullStderr, code in
                Task { @MainActor in
                    guard let self else { return }
                    let finalText = fullStdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !finalText.isEmpty {
                        self.messages.append(ChatMessage(
                            id: UUID().uuidString,
                            role: .assistant,
                            parts: [.text(finalText)],
                            timestamp: Date(),
                            isError: code != 0))
                    } else if code != 0 {
                        let err = fullStderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.messages.append(ChatMessage(
                            id: UUID().uuidString,
                            role: .assistant,
                            parts: [.text(err.isEmpty ? "claude exited \(code) with no output" : err)],
                            timestamp: Date(),
                            isError: true))
                    }
                    self.liveAssistant = ""
                    self.streaming = false

                    if code == 0 {
                        Notifier.notify(title: "✓ \(projectName)",
                                        body: String(finalText.prefix(140)))
                    } else {
                        Notifier.notify(title: "⚠️ \(projectName) failed",
                                        body: fullStderr.isEmpty ? "exit \(code)" : String(fullStderr.prefix(140)))
                    }

                    // Push sidebar to re-scan (mtime / git / todo / error all could have changed),
                    // and reload chat history from .jsonl so we see what got persisted.
                    self.store?.refresh()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        self.reconcileFromDisk()
                    }
                }
            }
        )
    }

    func cancel() {
        ClaudeBackend.shared.cancel()
        streaming = false
    }
}

struct ChatView: View {
    let project: Project
    @EnvironmentObject var store: ProjectStore
    @ObservedObject var vm: ChatViewModel
    @State private var pasteMonitor: Any?

    init(project: Project, vm: ChatViewModel) {
        self.project = project
        self.vm = vm
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            messagesScroll
                .background(Color(NSColor.textBackgroundColor))
            if let err = vm.errorBanner {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
            }
            inputBar
        }
        .onAppear { installPasteMonitor() }
        .onDisappear { removePasteMonitor() }
    }

    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        // Local NSEvent monitor catches ⌘V before TextField does so we can pull
        // images off the pasteboard. Text-only pastes pass through untouched.
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v" else {
                return event
            }
            guard let img = NSImage(pasteboard: NSPasteboard.general) else {
                return event
            }
            Task { @MainActor in vm.addPasted(image: img) }
            return nil
        }
    }

    private func removePasteMonitor() {
        if let m = pasteMonitor {
            NSEvent.removeMonitor(m)
            pasteMonitor = nil
        }
    }

    var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.shortName)
                    .font(.system(.headline, design: .rounded))
                Text(project.originalPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if vm.streaming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Button {
                        vm.cancel()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                }
            } else {
                Button {
                    vm.loadHistory()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reload history from .jsonl")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }

    var messagesScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(vm.messages) { m in
                        MessageBubble(msg: m).id(m.id)
                    }
                    if vm.streaming && !vm.liveAssistant.isEmpty {
                        MessageBubble(msg: ChatMessage(id: "live", role: .assistant, parts: [.text(vm.liveAssistant)], timestamp: nil, isError: false))
                            .id("live")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .onChange(of: vm.messages.count) { _, _ in
                if let last = vm.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: vm.liveAssistant) { _, _ in
                proxy.scrollTo("live", anchor: .bottom)
            }
            .onAppear {
                if let last = vm.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    var inputBar: some View {
        VStack(spacing: 8) {
            if !vm.pendingAttachments.isEmpty {
                attachmentChips
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    pickImage()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("Attach image")
                TextField("Message Claude… (⌘V to paste image)", text: $vm.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...8)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(NSColor.textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                    )
                    .onSubmit {
                        vm.send()
                    }
                Button {
                    vm.send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle().fill(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send (Enter). Shift+Enter for newline.")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider().opacity(0.6)
        }
    }

    var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.pendingAttachments, id: \.self) { url in
                    AttachmentChip(url: url) {
                        vm.removePending(url)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var canSend: Bool {
        let hasText = !vm.draft.trimmingCharacters(in: .whitespaces).isEmpty
        let hasImages = !vm.pendingAttachments.isEmpty
        return (hasText || hasImages) && !vm.streaming
    }

    func pickImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .png, .jpeg, .tiff, .heic]
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let img = NSImage(contentsOf: url) {
                    vm.addPasted(image: img)
                }
            }
        }
    }
}

struct ImagePartView: View {
    let url: URL

    var body: some View {
        if let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 280, maxHeight: 280, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
                .help(url.lastPathComponent)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1))
            )
        }
    }
}

struct AttachmentChip: View {
    let url: URL
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                    )
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 56, height: 56)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white, .black.opacity(0.65))
            }
            .buttonStyle(.plain)
            .padding(2)
            .opacity(hovering ? 1 : 0.85)
        }
        .onHover { hovering = $0 }
        .help(url.lastPathComponent)
    }
}

struct MessageBubble: View {
    let msg: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            roleIcon
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(msg.parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .text(let s):
                        Text(s)
                            .font(.system(.body))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(bg)
                            )
                    case .tool(let tool):
                        ToolBlockView(tool: tool)
                    case .image(let url):
                        ImagePartView(url: url)
                    case .thinking(let s):
                        ThinkingBlockView(text: s)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var roleIcon: some View {
        Group {
            switch msg.role {
            case .user:
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.blue)
                    )
            case .assistant:
                Circle()
                    .fill(Color.purple.opacity(0.15))
                    .overlay(
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.purple)
                    )
            case .system:
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: 26, height: 26)
    }

    var bg: Color {
        if msg.isError { return Color.red.opacity(0.10) }
        return msg.role == .user ? Color.blue.opacity(0.08) : Color.secondary.opacity(0.10)
    }
}

struct ToolBlockView: View {
    let tool: ToolDisplay
    @State private var isExpanded = false
    private let collapsedLines = 5

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent.opacity(0.6))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(tool.name)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                    if !tool.header.isEmpty {
                        Text(tool.header)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    if tool.isError {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                    if hasMore {
                        Button { isExpanded.toggle() } label: {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                bodyView
            }
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    @ViewBuilder
    var bodyView: some View {
        if isDiff, let oldText = tool.oldText, let newText = tool.body {
            DiffBlockView(oldText: oldText,
                          newText: newText,
                          collapsedLines: collapsedLines,
                          isExpanded: isExpanded)
        } else if let body = tool.body, !body.isEmpty {
            CodeBlockView(text: body,
                          collapsedLines: collapsedLines,
                          isExpanded: isExpanded)
        }
    }

    var isDiff: Bool {
        (tool.name == "Edit" || tool.name == "MultiEdit") && tool.oldText != nil
    }

    var totalLines: Int {
        let bodyLines = (tool.body?.split(separator: "\n", omittingEmptySubsequences: false).count) ?? 0
        let oldLines = (tool.oldText?.split(separator: "\n", omittingEmptySubsequences: false).count) ?? 0
        return isDiff ? bodyLines + oldLines : bodyLines
    }

    var hasMore: Bool { totalLines > collapsedLines }

    var iconName: String {
        switch tool.name {
        case "Edit", "MultiEdit": return "pencil"
        case "Write": return "doc.badge.plus"
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Grep": return "magnifyingglass"
        default: return "wrench.and.screwdriver"
        }
    }

    var accent: Color {
        switch tool.name {
        case "Edit", "MultiEdit": return .orange
        case "Write": return .green
        case "Bash": return .purple
        case "Read", "Grep": return .blue
        default: return .secondary
        }
    }
}

struct CodeBlockView: View {
    let text: String
    let collapsedLines: Int
    let isExpanded: Bool

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = isExpanded ? lines : Array(lines.prefix(collapsedLines))
        let truncated = !isExpanded && lines.count > collapsedLines
        Text(shown.joined(separator: "\n") + (truncated ? "\n…" : ""))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DiffBlockView: View {
    let oldText: String
    let newText: String
    let collapsedLines: Int
    let isExpanded: Bool

    var body: some View {
        let oldLines = oldText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = newText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let oldShown = isExpanded ? oldLines : Array(oldLines.prefix(collapsedLines / 2 + 1))
        let newShown = isExpanded ? newLines : Array(newLines.prefix(collapsedLines / 2 + 1))
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(oldShown.enumerated()), id: \.offset) { _, line in
                diffLine("- \(line)", color: .red)
            }
            if !isExpanded && oldLines.count > oldShown.count {
                diffLine("…", color: .secondary)
            }
            ForEach(Array(newShown.enumerated()), id: \.offset) { _, line in
                diffLine("+ \(line)", color: .green)
            }
            if !isExpanded && newLines.count > newShown.count {
                diffLine("…", color: .secondary)
            }
        }
    }

    func diffLine(_ s: String, color: Color) -> some View {
        Text(s)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(color.opacity(0.85))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ThinkingBlockView: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "brain")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Thinking")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("· \(lineCount) line\(lineCount == 1 ? "" : "s")")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                if isExpanded {
                    Text(text)
                        .font(.system(size: 12).italic())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    var lineCount: Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

enum Notifier {
    static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
