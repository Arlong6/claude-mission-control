import Foundation

enum MetadataLoader {
    static func load(for project: Project) -> ProjectMeta {
        let git = gitDirty(at: project.originalPath)
        let todo = todoCount(at: project.originalPath)
        let err = hasError(in: project.sessions.first?.url)
        return ProjectMeta(gitDirty: git, todoOpen: todo, hasError: err)
    }

    static func gitDirty(at path: String) -> Int {
        let fm = FileManager.default
        let gitDir = (path as NSString).appendingPathComponent(".git")
        guard fm.fileExists(atPath: gitDir) else { return -1 }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", path, "status", "--porcelain"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let str = String(data: data, encoding: .utf8) ?? ""
            return str.split(separator: "\n").count
        } catch {
            return -1
        }
    }

    static func todoCount(at path: String) -> Int {
        let todoPath = (path as NSString).appendingPathComponent("tasks/todo.md")
        guard let s = try? String(contentsOfFile: todoPath, encoding: .utf8) else { return -1 }
        return s.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("* [ ]")
        }.count
    }

    static func hasError(in url: URL?) -> Bool {
        guard let url else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // tail-ish: read last 64KB
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let chunk: Int64 = 64 * 1024
        let offset = max(0, size - chunk)
        try? handle.seek(toOffset: UInt64(offset))
        let data = (try? handle.readToEnd()) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lines = text.split(separator: "\n").suffix(80)
        for line in lines {
            if line.contains("\"isError\":true") || line.contains("\"is_error\":true") {
                return true
            }
        }
        return false
    }
}
