import Foundation

// Mirrors mc-pocket/Sources/Shared/NotificationRules.swift verbatim. Keep
// the two in sync — the iOS client sends this JSON via POST /rules. If you
// change one, change the other.
struct NotificationRules: Codable, Equatable {
    var globalEnabled: Bool
    var quietHours: QuietHours?
    var perProject: [String: ProjectRule]
    var keywords: [KeywordRule]

    init(
        globalEnabled: Bool = true,
        quietHours: QuietHours? = nil,
        perProject: [String: ProjectRule] = [:],
        keywords: [KeywordRule] = []
    ) {
        self.globalEnabled = globalEnabled
        self.quietHours = quietHours
        self.perProject = perProject
        self.keywords = keywords
    }

    static let `default` = NotificationRules()

    struct QuietHours: Codable, Equatable {
        var startMinute: Int
        var endMinute: Int
        var timeZoneIdentifier: String

        func isActive(at date: Date = Date()) -> Bool {
            var cal = Calendar(identifier: .gregorian)
            if let tz = TimeZone(identifier: timeZoneIdentifier) { cal.timeZone = tz }
            let c = cal.dateComponents([.hour, .minute], from: date)
            let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            if startMinute <= endMinute {
                return m >= startMinute && m < endMinute
            } else {
                return m >= startMinute || m < endMinute
            }
        }
    }

    struct ProjectRule: Codable, Equatable {
        var level: Level
        enum Level: String, Codable {
            case all
            case importantOnly
            case errorsOnly
            case none
        }
    }

    struct KeywordRule: Codable, Equatable, Identifiable {
        var id: UUID
        var pattern: String
        var action: Action
        enum Action: String, Codable {
            case alwaysPush
            case suppress
        }
    }

    func shouldPush(projectId: String, kind: String, bodyPreview: String = "", now: Date = Date()) -> Bool {
        for rule in keywords {
            let p = rule.pattern.lowercased()
            guard !p.isEmpty else { continue }
            if bodyPreview.lowercased().contains(p) {
                switch rule.action {
                case .alwaysPush: return true
                case .suppress: return false
                }
            }
        }

        guard globalEnabled else { return false }
        if let q = quietHours, q.isActive(at: now) { return false }

        let level = perProject[projectId]?.level ?? .importantOnly
        switch level {
        case .none: return false
        case .errorsOnly: return kind == "error"
        case .importantOnly: return kind == "waitingForInput" || kind == "error"
        case .all: return true
        }
    }
}
