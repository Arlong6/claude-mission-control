import SwiftUI
import UserNotifications

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft: String = ""
    @Published var streaming: Bool = false
    @Published var liveAssistant: String = ""
    @Published var errorBanner: String?

    let project: Project
    weak var store: ProjectStore?

    init(project: Project, store: ProjectStore? = nil) {
        self.project = project
        self.store = store
        loadHistory()
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
        guard !text.isEmpty, !streaming else { return }
        let userMsg = ChatMessage(id: UUID().uuidString, role: .user, parts: [.text(text)], timestamp: Date(), isError: false)
        messages.append(userMsg)
        draft = ""
        streaming = true
        liveAssistant = ""
        errorBanner = nil

        let projectName = project.shortName
        let sid = sessionID

        ClaudeBackend.shared.send(
            prompt: text,
            cwd: project.originalPath,
            sessionId: sid,
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
    @StateObject var vm: ChatViewModel

    init(project: Project, store: ProjectStore) {
        self.project = project
        _vm = StateObject(wrappedValue: ChatViewModel(project: project, store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagesScroll
            if let err = vm.errorBanner {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.red.opacity(0.08))
            }
            Divider()
            inputBar
        }
    }

    var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(project.shortName).font(.headline)
                Text(project.originalPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if vm.streaming {
                ProgressView().controlSize(.small)
                Button("Stop") { vm.cancel() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
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
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    var messagesScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(vm.messages) { m in
                        MessageBubble(msg: m).id(m.id)
                    }
                    if vm.streaming && !vm.liveAssistant.isEmpty {
                        MessageBubble(msg: ChatMessage(id: "live", role: .assistant, parts: [.text(vm.liveAssistant)], timestamp: nil, isError: false))
                            .id("live")
                    }
                }
                .padding(12)
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
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message…", text: $vm.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...8)
                .padding(8)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)
                .onSubmit {
                    vm.send()
                }
            Button {
                vm.send()
            } label: {
                Image(systemName: "paperplane.fill")
                    .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .disabled(vm.draft.trimmingCharacters(in: .whitespaces).isEmpty || vm.streaming)
            .help("Send (Enter). Shift+Enter for newline.")
        }
        .padding(10)
    }
}

struct MessageBubble: View {
    let msg: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            roleIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(roleLabel).font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(msg.parts.enumerated()), id: \.offset) { _, part in
                        switch part {
                        case .text(let s):
                            Text(s)
                                .font(.system(.body))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .tool(let tool):
                            ToolBlockView(tool: tool)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(bg)
                .cornerRadius(6)
            }
        }
    }

    var roleLabel: String {
        switch msg.role {
        case .user: return "You"
        case .assistant: return "Claude"
        case .system: return "System"
        }
    }

    var roleIcon: some View {
        Image(systemName: msg.role == .user ? "person.circle.fill" : "sparkles")
            .foregroundStyle(msg.role == .user ? .blue : .purple)
            .font(.title3)
            .frame(width: 22)
    }

    var bg: Color {
        if msg.isError { return Color.red.opacity(0.1) }
        return msg.role == .user ? Color.blue.opacity(0.08) : Color.secondary.opacity(0.08)
    }
}

struct ToolBlockView: View {
    let tool: ToolDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            }
            if let body = tool.body, !body.isEmpty {
                Text(body)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 16)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.18))
                    .cornerRadius(4)
            }
        }
        .padding(6)
        .background(Color.secondary.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .cornerRadius(5)
    }

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
        default: return .secondary
        }
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
