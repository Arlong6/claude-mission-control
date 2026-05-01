import Foundation

enum ProjectScanner {
    static let projectsRoot: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/projects", isDirectory: true)
    }()

    static let hiddenStoreURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude-mission-control/hidden.json")
    }()

    static func scan() -> [Project] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: projectsRoot,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else {
            return []
        }
        let hidden = loadHidden()

        var projects: [Project] = []
        for dir in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let id = dir.lastPathComponent
            if hidden.contains(id) { continue }
            if id == "-Users-arlong" || id == "-Users-arlong-Projects" { continue } // root noise

            let sessions = scanSessions(in: dir)
            // Prefer real cwd from .jsonl (handles paths with hyphens correctly).
            let originalPath = sessions.first.flatMap { extractCwd(from: $0.url) } ?? decodePath(from: id)
            let displayName = originalPath
            let dirMTime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let lastActivity = sessions.first?.modified ?? dirMTime

            projects.append(Project(
                id: id,
                displayName: displayName,
                originalPath: originalPath,
                claudeDir: dir,
                sessions: sessions,
                lastActivity: lastActivity,
                meta: .empty
            ))
        }
        projects.sort { $0.lastActivity > $1.lastActivity }
        return projects
    }

    static func scanSessions(in dir: URL) -> [SessionFile] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                      options: [.skipsHiddenFiles]) else {
            return []
        }
        var out: [SessionFile] = []
        for f in files where f.pathExtension == "jsonl" {
            let attrs = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mod = attrs?.contentModificationDate ?? .distantPast
            let size = Int64(attrs?.fileSize ?? 0)
            out.append(SessionFile(id: f.deletingPathExtension().lastPathComponent,
                                   url: f, modified: mod, sizeBytes: size))
        }
        out.sort { $0.modified > $1.modified }
        return out
    }

    /// Fallback: convert dir name to a path (loses hyphen info — only used if no .jsonl).
    static func decodePath(from id: String) -> String {
        var s = id
        if s.hasPrefix("-") { s.removeFirst() }
        return "/" + s.replacingOccurrences(of: "-", with: "/")
    }

    /// Read the most recent .jsonl line by line until we find a `"cwd":"..."`
    /// entry, or hit a 512 KB cap. Authoritative because Claude Code records
    /// cwd on every user/assistant message — we just need to skip past any
    /// summary/leafUuid header lines new sessions prepend (which can run past
    /// the old 8 KB window for large summaries).
    static func extractCwd(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var pending = Data()
        let chunkSize = 32 * 1024
        let maxBytes = 512 * 1024
        var totalRead = 0

        while totalRead < maxBytes {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            totalRead += chunk.count
            pending.append(chunk)

            while let nlIdx = pending.firstIndex(of: 0x0A) {
                let lineData = pending.subdata(in: pending.startIndex..<nlIdx)
                pending.removeSubrange(pending.startIndex...nlIdx)

                guard let line = String(data: lineData, encoding: .utf8),
                      line.contains("\"cwd\"") else { continue }

                if let r = line.range(of: #""cwd":"([^"]+)""#, options: .regularExpression) {
                    let match = String(line[r])
                    if let start = match.range(of: #":""#)?.upperBound {
                        var s = String(match[start...])
                        if s.hasSuffix("\"") { s.removeLast() }
                        return s
                    }
                }
            }
        }
        return nil
    }

    // MARK: hidden store

    static func loadHidden() -> Set<String> {
        guard let data = try? Data(contentsOf: hiddenStoreURL),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }

    static func saveHidden(_ set: Set<String>) {
        let dir = hiddenStoreURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try? JSONEncoder().encode(Array(set).sorted())
        try? data?.write(to: hiddenStoreURL)
    }
}
