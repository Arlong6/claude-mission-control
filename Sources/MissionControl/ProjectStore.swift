import Foundation
import Combine

@MainActor
final class ProjectStore: ObservableObject {
    @Published var projects: [Project] = []
    @Published var selectedID: String?
    @Published var hasAnyError: Bool = false

    private var refreshTask: Task<Void, Never>?
    private var chatVMs: [String: ChatViewModel] = [:]

    /// Returns a long-lived ChatViewModel for the project, surviving any
    /// SwiftUI view tear-down (window close/show, scene rebuild). The vm's
    /// project metadata is kept fresh in place rather than recreated, so a
    /// streaming response is never abandoned mid-flight.
    func chatViewModel(for project: Project) -> ChatViewModel {
        if let existing = chatVMs[project.id] {
            existing.update(project: project)
            return existing
        }
        let new = ChatViewModel(project: project, store: self)
        chatVMs[project.id] = new
        return new
    }

    func startAutoRefresh() {
        refresh()
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
                await self?.refreshAsync()
            }
        }
    }

    func refresh() {
        Task { await refreshAsync() }
    }

    func refreshAsync() async {
        let scanned = await Task.detached(priority: .userInitiated) { ProjectScanner.scan() }.value
        // load metadata in parallel
        let withMeta = await withTaskGroup(of: (String, ProjectMeta).self) { group -> [String: ProjectMeta] in
            for p in scanned {
                group.addTask {
                    let m = MetadataLoader.load(for: p)
                    return (p.id, m)
                }
            }
            var dict: [String: ProjectMeta] = [:]
            for await (id, m) in group { dict[id] = m }
            return dict
        }
        let merged = scanned.map { p -> Project in
            var copy = p
            copy.meta = withMeta[p.id] ?? .empty
            return copy
        }
        self.projects = merged
        self.hasAnyError = merged.contains(where: { $0.meta.hasError })
        if let sel = selectedID, !merged.contains(where: { $0.id == sel }) {
            selectedID = nil
        }
    }

    func hide(_ id: String) {
        var set = ProjectScanner.loadHidden()
        set.insert(id)
        ProjectScanner.saveHidden(set)
        projects.removeAll { $0.id == id }
        chatVMs.removeValue(forKey: id)
        if selectedID == id { selectedID = nil }
    }

    func clearSession(_ id: String) throws {
        let dir = ProjectScanner.projectsRoot.appendingPathComponent(id)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        for f in files where f.pathExtension == "jsonl" {
            try FileManager.default.removeItem(at: f)
        }
        refresh()
    }

    func hardDelete(_ id: String) throws {
        let dir = ProjectScanner.projectsRoot.appendingPathComponent(id)
        // safety: must be inside ~/.claude/projects/
        guard dir.path.hasPrefix(ProjectScanner.projectsRoot.path + "/") else {
            throw NSError(domain: "MC", code: 1, userInfo: [NSLocalizedDescriptionKey: "refusing path outside ~/.claude/projects"])
        }
        try FileManager.default.removeItem(at: dir)
        projects.removeAll { $0.id == id }
        chatVMs.removeValue(forKey: id)
        if selectedID == id { selectedID = nil }
    }

    var selected: Project? {
        guard let id = selectedID else { return nil }
        return projects.first { $0.id == id }
    }
}
