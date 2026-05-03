import SwiftUI

@MainActor
final class SearchModel: ObservableObject {
    @Published var query: String = ""
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

        task = Task.detached(priority: .userInitiated) { [weak self] in
            // TaskGroup fans every (project, session) out so the Swift runtime
            // can schedule them across all available cores at once.
            let hits = await withTaskGroup(of: [SearchHit].self) { group -> [SearchHit] in
                for t in targets {
                    if Task.isCancelled { break }
                    group.addTask {
                        SessionGrep.search(needle: q,
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
    /// Scan a .jsonl, returning up to `limit` hits per file. Bails on files
    /// larger than 50 MB so a giant session can't dominate one search.
    /// Case-insensitive search uses ICU via String.range without per-line
    /// allocation, so a 100 MB file is one big-string scan, not 10k mallocs.
    static func search(needle: String,
                       in url: URL,
                       projectID: String,
                       projectShortName: String,
                       sessionID: String,
                       limit: Int) -> [SearchHit]? {
        let attrs = try? url.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(attrs?.fileSize ?? 0)
        if size > 50 * 1024 * 1024 { return nil }
        // Memory-mapped read avoids paging the whole file into RSS for huge
        // sessions; falls back to in-memory if the file system can't map it.
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        let text = String(decoding: data, as: UTF8.self)

        // Cheap pre-filter: if needle isn't anywhere in the whole file, skip
        // the per-line iteration entirely.
        guard text.range(of: needle, options: [.caseInsensitive]) != nil else { return [] }

        var out: [SearchHit] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.range(of: needle, options: [.caseInsensitive]) != nil else { continue }
            let raw = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            let role = raw?["type"] as? String ?? "?"
            let snippet = extractSnippet(from: raw, needle: needle) ?? String(line.prefix(160))
            out.append(SearchHit(projectID: projectID,
                                 projectShortName: projectShortName,
                                 sessionID: sessionID,
                                 role: role,
                                 snippet: snippet))
            if out.count >= limit { break }
        }
        return out
    }

    private static func extractSnippet(from raw: [String: Any]?, needle: String) -> String? {
        guard let raw, let msg = raw["message"] as? [String: Any] else { return nil }
        if let s = msg["content"] as? String { return contextWindow(s, needle: needle) }
        if let blocks = msg["content"] as? [[String: Any]] {
            for b in blocks {
                if let s = b["text"] as? String,
                   s.range(of: needle, options: [.caseInsensitive]) != nil {
                    return contextWindow(s, needle: needle)
                }
            }
        }
        return nil
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
            .padding(14)
            .background(.regularMaterial)

            Divider()

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
                            SearchHitRow(hit: hit) {
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
                Text(hit.snippet)
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
}
