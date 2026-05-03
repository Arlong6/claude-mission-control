import SwiftUI

enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case topic       // user messages + assistant text + thinking
    case userOnly    // user messages only
    case assistantOnly // assistant text + thinking only

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topic: return "主題"
        case .userOnly: return "我講的"
        case .assistantOnly: return "Claude 講的"
        }
    }
}

@MainActor
final class SearchModel: ObservableObject {
    @Published var query: String = ""
    @Published var scope: SearchScope = .topic {
        didSet { runSearch() }
    }
    @Published var results: [SearchHit] = []
    @Published var searching: Bool = false

    private var task: Task<Void, Never>?
    private weak var store: ProjectStore?

    init(store: ProjectStore) {
        self.store = store
    }

    func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        task?.cancel()
        guard q.count >= 2 else {
            results = []
            searching = false
            return
        }
        guard let projects = store?.projects else { return }
        searching = true

        // Snapshot file targets outside the actor so the detached fan-out
        // doesn't keep hopping back to MainActor for project metadata.
        struct Target: Sendable {
            let url: URL
            let projectID: String
            let projectShortName: String
            let sessionID: String
        }
        var targets: [Target] = []
        for p in projects {
            for s in p.sessions {
                targets.append(.init(url: s.url,
                                     projectID: p.id,
                                     projectShortName: p.shortName,
                                     sessionID: s.id))
            }
        }

        let activeScope = scope
        task = Task.detached(priority: .userInitiated) { [weak self] in
            // TaskGroup fans every (project, session) out so the Swift runtime
            // can schedule them across all available cores at once.
            let hits = await withTaskGroup(of: [SearchHit].self) { group -> [SearchHit] in
                for t in targets {
                    if Task.isCancelled { break }
                    group.addTask {
                        SessionGrep.search(needle: q,
                                           scope: activeScope,
                                           in: t.url,
                                           projectID: t.projectID,
                                           projectShortName: t.projectShortName,
                                           sessionID: t.sessionID,
                                           limit: 5) ?? []
                    }
                }
                var all: [SearchHit] = []
                for await batch in group {
                    all.append(contentsOf: batch)
                    if all.count > 200 {
                        group.cancelAll()
                        break
                    }
                }
                return all
            }
            let final = Array(hits.prefix(150))
            await MainActor.run { [weak self] in
                self?.results = final
                self?.searching = false
            }
        }
    }
}

struct SearchHit: Identifiable, Hashable {
    let id = UUID()
    let projectID: String
    let projectShortName: String
    let sessionID: String
    let role: String
    let snippet: String
}

enum SessionGrep {
    /// Scan a .jsonl for the needle within scope-restricted content. Skips
    /// files >50 MB so one giant session can't dominate one search.
    ///
    /// The pipeline is:
    ///   1. mmap the file
    ///   2. cheap whole-file pre-filter — if needle isn't in the raw bytes
    ///      anywhere, this file is done
    ///   3. per-line: filter by `type` (user/assistant), then parse JSON,
    ///      extract only the clean text fields the scope cares about, and
    ///      run the actual case-insensitive match against that clean text
    ///
    /// This means tool params, tool output, and JSON metadata never produce
    /// hits even though the raw bytes contain them.
    static func search(needle: String,
                       scope: SearchScope,
                       in url: URL,
                       projectID: String,
                       projectShortName: String,
                       sessionID: String,
                       limit: Int) -> [SearchHit]? {
        let attrs = try? url.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(attrs?.fileSize ?? 0)
        if size > 50 * 1024 * 1024 { return nil }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard text.range(of: needle, options: [.caseInsensitive]) != nil else { return [] }

        var out: [SearchHit] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Cheap type pre-filter without parsing JSON. Skips lines that
            // can't possibly produce a hit for the active scope.
            guard couldMatchScope(line: line, scope: scope) else { continue }
            // Even with the right type, the raw line might not contain the
            // needle anywhere — drop those before paying for JSON parse.
            guard line.range(of: needle, options: [.caseInsensitive]) != nil else { continue }
            guard let raw = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }

            if let (role, snippet) = match(raw: raw, scope: scope, needle: needle) {
                out.append(SearchHit(projectID: projectID,
                                     projectShortName: projectShortName,
                                     sessionID: sessionID,
                                     role: role,
                                     snippet: snippet))
                if out.count >= limit { break }
            }
        }
        return out
    }

    private static func couldMatchScope(line: Substring, scope: SearchScope) -> Bool {
        switch scope {
        case .userOnly:
            return line.contains("\"type\":\"user\"")
        case .assistantOnly:
            return line.contains("\"type\":\"assistant\"")
        case .topic:
            return line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"")
        }
    }

    /// Pull out only the clean human/assistant text the scope cares about, and
    /// return the first piece that contains the needle. Returns nil if the
    /// match was only in metadata or tool params.
    private static func match(raw: [String: Any],
                              scope: SearchScope,
                              needle: String) -> (role: String, snippet: String)? {
        guard let type = raw["type"] as? String,
              let msg = raw["message"] as? [String: Any] else { return nil }

        let wantUser = scope == .topic || scope == .userOnly
        let wantAsst = scope == .topic || scope == .assistantOnly

        if type == "user", wantUser {
            for text in userTexts(in: msg) {
                if let snip = matchAndContext(text, needle: needle) {
                    return ("user", snip)
                }
            }
        }
        if type == "assistant", wantAsst {
            for text in assistantTexts(in: msg) {
                if let snip = matchAndContext(text, needle: needle) {
                    return ("assistant", snip)
                }
            }
        }
        return nil
    }

    /// User-typed content. Skips tool_result blocks (those are system noise
    /// the user never wrote).
    private static func userTexts(in msg: [String: Any]) -> [String] {
        if let s = msg["content"] as? String { return [s] }
        guard let blocks = msg["content"] as? [[String: Any]] else { return [] }
        var out: [String] = []
        for b in blocks {
            let bt = b["type"] as? String
            // Some user blocks omit "type" and just carry "text"
            if (bt == nil || bt == "text"), let s = b["text"] as? String, !s.isEmpty {
                out.append(s)
            }
        }
        return out
    }

    /// Assistant content: real prose + thinking. Skips tool_use because its
    /// `input` JSON would otherwise produce noisy "look I matched a curly
    /// brace" hits.
    private static func assistantTexts(in msg: [String: Any]) -> [String] {
        guard let blocks = msg["content"] as? [[String: Any]] else { return [] }
        var out: [String] = []
        for b in blocks {
            let bt = b["type"] as? String
            if bt == "text", let s = b["text"] as? String, !s.isEmpty { out.append(s) }
            if bt == "thinking", let s = b["thinking"] as? String, !s.isEmpty { out.append(s) }
        }
        return out
    }

    private static func matchAndContext(_ s: String, needle: String) -> String? {
        guard s.range(of: needle, options: [.caseInsensitive]) != nil else { return nil }
        return contextWindow(s, needle: needle)
    }

    /// Return ~160 chars centred around the first match for context.
    private static func contextWindow(_ s: String, needle: String) -> String {
        guard let r = s.range(of: needle, options: [.caseInsensitive]) else {
            return String(s.prefix(160))
        }
        let start = s.index(r.lowerBound, offsetBy: -50, limitedBy: s.startIndex) ?? s.startIndex
        let end = s.index(r.upperBound, offsetBy: 110, limitedBy: s.endIndex) ?? s.endIndex
        var snip = String(s[start..<end])
        snip = snip.replacingOccurrences(of: "\n", with: " ")
        if start != s.startIndex { snip = "…" + snip }
        if end != s.endIndex { snip += "…" }
        return snip
    }
}

struct SearchSheet: View {
    @StateObject private var model: SearchModel
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var queryFocus: Bool

    init(store: ProjectStore) {
        _model = StateObject(wrappedValue: SearchModel(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search across all projects…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($queryFocus)
                    .onSubmit { model.runSearch() }
                    .onChange(of: model.query) { _, _ in
                        // debounce-ish: just re-run; cancellation in model handles bursts
                        model.runSearch()
                    }
                if model.searching {
                    ProgressView().controlSize(.small)
                }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .background(.regularMaterial)

            Picker("Scope", selection: $model.scope) {
                ForEach(SearchScope.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial)

            Divider()

            // Snapshot the query for the row views so changes after results
            // are computed don't trigger highlighting against a different
            // string than the snippet was built around.
            let activeQuery = model.query.trimmingCharacters(in: .whitespacesAndNewlines)

            if model.results.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(model.query.count < 2
                         ? "Type 2+ characters to search"
                         : (model.searching ? "Searching…" : "No matches"))
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.results) { hit in
                            SearchHitRow(hit: hit, query: activeQuery) {
                                store.selectedID = hit.projectID
                                dismiss()
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { queryFocus = true }
    }
}

struct SearchHitRow: View {
    let hit: SearchHit
    let query: String
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(hit.projectShortName)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(hit.role)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(hit.role == "assistant" ? .purple : .blue)
                    Spacer()
                    Text(String(hit.sessionID.prefix(8)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(highlightedSnippet)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    /// Walk the snippet looking for case-insensitive matches of `query`,
    /// painting each match with a yellow background and bumping primary
    /// foreground so it pops against the secondary-styled body text.
    private var highlightedSnippet: AttributedString {
        var attr = AttributedString(hit.snippet)
        guard !query.isEmpty else { return attr }
        var cursor = attr.startIndex
        while cursor < attr.endIndex {
            let slice = attr[cursor..<attr.endIndex]
            guard let range = slice.range(of: query, options: [.caseInsensitive]) else { break }
            attr[range].backgroundColor = Color.yellow.opacity(0.45)
            attr[range].foregroundColor = .primary
            attr[range].inlinePresentationIntent = .stronglyEmphasized
            cursor = range.upperBound
        }
        return attr
    }
}
