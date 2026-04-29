import Foundation

struct ChatMessage: Identifiable, Hashable {
    enum Role: String { case user, assistant, system }
    let id: String
    let role: Role
    let text: String
    let timestamp: Date?
    let isError: Bool
}

enum JSONLLoader {
    /// Load up to `maxMessages` from the end of `url`, parsed in display order (oldest → newest).
    static func load(from url: URL, maxMessages: Int = 200) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var out: [ChatMessage] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // Walk from end backwards until we have maxMessages relevant
        for line in lines.suffix(maxMessages * 4) {
            if let msg = parseLine(String(line)) {
                out.append(msg)
            }
        }
        if out.count > maxMessages {
            out = Array(out.suffix(maxMessages))
        }
        return out
    }

    static func parseLine(_ line: String) -> ChatMessage? {
        guard let data = line.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        guard let topType = raw["type"] as? String else { return nil }
        guard topType == "user" || topType == "assistant" else { return nil }

        let id = (raw["uuid"] as? String) ?? (raw["promptId"] as? String) ?? UUID().uuidString
        let timestamp = (raw["timestamp"] as? String).flatMap(parseISO)

        let role: ChatMessage.Role = (topType == "user") ? .user : .assistant
        var text = ""
        var isError = false

        if let msg = raw["message"] as? [String: Any] {
            // content can be string or array of blocks
            if let s = msg["content"] as? String {
                text = s
            } else if let blocks = msg["content"] as? [[String: Any]] {
                var parts: [String] = []
                for b in blocks {
                    let bt = b["type"] as? String ?? ""
                    switch bt {
                    case "text":
                        if let s = b["text"] as? String { parts.append(s) }
                    case "tool_use":
                        let name = b["name"] as? String ?? "tool"
                        parts.append("⚙︎ \(name)")
                    case "tool_result":
                        if let s = b["content"] as? String {
                            let snippet = s.prefix(300)
                            parts.append("↳ \(snippet)")
                        } else if let arr = b["content"] as? [[String: Any]] {
                            for sub in arr {
                                if let s = sub["text"] as? String {
                                    parts.append("↳ \(s.prefix(300))")
                                }
                            }
                        }
                        if (b["is_error"] as? Bool) == true { isError = true }
                    case "thinking":
                        break // skip
                    default:
                        break
                    }
                }
                text = parts.joined(separator: "\n\n")
            }
        }
        if text.isEmpty { return nil }
        return ChatMessage(id: id, role: role, text: text, timestamp: timestamp, isError: isError)
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseISO(_ s: String) -> Date? {
        isoFormatter.date(from: s) ?? isoNoFrac.date(from: s)
    }
}
