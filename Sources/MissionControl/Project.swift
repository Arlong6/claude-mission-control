import Foundation

struct Project: Identifiable, Hashable {
    let id: String              // dir name, e.g. "-Users-arlong-Projects-AIvideo"
    let displayName: String     // "AIvideo" or "~/Projects/AIvideo"
    let originalPath: String    // "/Users/arlong/Projects/AIvideo"
    let claudeDir: URL          // ~/.claude/projects/<id>/
    var sessions: [SessionFile] // *.jsonl files inside, newest first
    var lastActivity: Date
    var meta: ProjectMeta
}

struct SessionFile: Identifiable, Hashable {
    let id: String              // sessionId (filename without .jsonl)
    let url: URL
    let modified: Date
    let sizeBytes: Int64
}

struct ProjectMeta: Hashable {
    var gitDirty: Int           // # of dirty files; -1 = not a git repo
    var todoOpen: Int           // # of "- [ ]" in tasks/todo.md; -1 = no file
    var hasError: Bool          // last 50 lines of newest .jsonl contain isError
    static let empty = ProjectMeta(gitDirty: -1, todoOpen: -1, hasError: false)
}

extension Project {
    var shortName: String {
        displayName.replacingOccurrences(of: "/Users/arlong/Projects/", with: "")
                   .replacingOccurrences(of: "/Users/arlong", with: "~")
    }

    var relativeActivityString: String {
        let interval = Date().timeIntervalSince(lastActivity)
        switch interval {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(interval/60))m ago"
        case ..<86400: return "\(Int(interval/3600))h ago"
        default: return "\(Int(interval/86400))d ago"
        }
    }
}
