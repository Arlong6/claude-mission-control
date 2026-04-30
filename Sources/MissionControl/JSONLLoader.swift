import Foundation

struct ChatMessage: Identifiable, Hashable {
    enum Role: String { case user, assistant, system }
    let id: String
    let role: Role
    let parts: [ContentPart]
    let timestamp: Date?
    let isError: Bool
}

enum ContentPart: Hashable {
    case text(String)
    case tool(ToolDisplay)
    case image(URL)
}

struct ToolDisplay: Hashable {
    let name: String         // "Edit", "Write", "Bash", or other tool name
    let header: String       // short summary line: file path or command
    let body: String?        // multi-line detail (snippet / output), or nil
    let isError: Bool
}

enum JSONLLoader {
    /// Two-pass: collect tool_use_id → output map, then build messages with output attached.
    static func load(from url: URL, maxMessages: Int = 200) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // Take only the tail we'll display, but expand the window since each message
        // may span multiple lines (assistant + matching user-tool_result).
        let window = lines.suffix(maxMessages * 6)

        // Pass 1: collect tool_use_id -> result text (for Bash output, etc.)
        var toolOutputs: [String: (text: String, isError: Bool)] = [:]
        for line in window {
            guard let raw = parseRaw(String(line)),
                  let topType = raw["type"] as? String,
                  topType == "user",
                  let msg = raw["message"] as? [String: Any],
                  let blocks = msg["content"] as? [[String: Any]] else { continue }
            for b in blocks where (b["type"] as? String) == "tool_result" {
                guard let useId = b["tool_use_id"] as? String else { continue }
                let isErr = (b["is_error"] as? Bool) == true
                if let s = b["content"] as? String {
                    toolOutputs[useId] = (s, isErr)
                } else if let arr = b["content"] as? [[String: Any]] {
                    var parts: [String] = []
                    for sub in arr {
                        if let s = sub["text"] as? String { parts.append(s) }
                    }
                    toolOutputs[useId] = (parts.joined(separator: "\n"), isErr)
                }
            }
        }

        // Pass 2: build display messages
        var out: [ChatMessage] = []
        for line in window {
            guard let msg = parseLine(String(line), toolOutputs: toolOutputs) else { continue }
            out.append(msg)
        }
        if out.count > maxMessages { out = Array(out.suffix(maxMessages)) }
        return out
    }

    static func parseRaw(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func parseLine(_ line: String, toolOutputs: [String: (text: String, isError: Bool)]) -> ChatMessage? {
        guard let raw = parseRaw(line) else { return nil }
        guard let topType = raw["type"] as? String else { return nil }
        guard topType == "user" || topType == "assistant" else { return nil }

        let id = (raw["uuid"] as? String) ?? (raw["promptId"] as? String) ?? UUID().uuidString
        let timestamp = (raw["timestamp"] as? String).flatMap(parseISO)
        let role: ChatMessage.Role = (topType == "user") ? .user : .assistant

        guard let msg = raw["message"] as? [String: Any] else { return nil }
        var parts: [ContentPart] = []
        var anyError = false

        if let s = msg["content"] as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append(contentsOf: extractParts(from: s, isUser: topType == "user"))
            }
        } else if let blocks = msg["content"] as? [[String: Any]] {
            // Skip user messages that ONLY contain tool_results — they're attached to assistant tool_use.
            let onlyToolResults = blocks.allSatisfy { ($0["type"] as? String) == "tool_result" }
            if topType == "user" && onlyToolResults { return nil }

            for b in blocks {
                let bt = b["type"] as? String ?? ""
                switch bt {
                case "text":
                    if let s = b["text"] as? String, !s.isEmpty {
                        parts.append(contentsOf: extractParts(from: s, isUser: topType == "user"))
                    }
                case "thinking":
                    break
                case "tool_use":
                    let name = b["name"] as? String ?? "tool"
                    let useId = b["id"] as? String ?? ""
                    let input = b["input"] as? [String: Any] ?? [:]
                    let display = renderToolUse(name: name, input: input, output: toolOutputs[useId])
                    if display.isError { anyError = true }
                    parts.append(.tool(display))
                case "tool_result":
                    // already collected for assistant tool_use; ignore here
                    break
                default:
                    break
                }
            }
        }
        if parts.isEmpty { return nil }
        return ChatMessage(id: id, role: role, parts: parts, timestamp: timestamp, isError: anyError)
    }

    // MARK: - Image extraction

    private static let attachedImageRegex: NSRegularExpression = {
        // Tolerant of either bracket style we've shipped.
        try! NSRegularExpression(pattern: #"\[attached image: ([^\]]+)\]"#)
    }()

    /// For user messages, peel off our `[attached image: <path>]` markers into
    /// dedicated image parts so the bubble shows a thumbnail instead of a raw
    /// /Users/... path. Assistant text is returned as-is.
    static func extractParts(from raw: String, isUser: Bool) -> [ContentPart] {
        guard isUser else { return [.text(raw)] }
        let nsRange = NSRange(raw.startIndex..., in: raw)
        let matches = attachedImageRegex.matches(in: raw, range: nsRange)
        guard !matches.isEmpty else { return [.text(raw)] }
        var parts: [ContentPart] = []
        for m in matches {
            if let r = Range(m.range(at: 1), in: raw) {
                let path = String(raw[r]).trimmingCharacters(in: .whitespaces)
                parts.append(.image(URL(fileURLWithPath: path)))
            }
        }
        let cleaned = attachedImageRegex
            .stringByReplacingMatches(in: raw, range: nsRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { parts.append(.text(cleaned)) }
        return parts
    }

    // MARK: - Tool rendering

    static func renderToolUse(name: String, input: [String: Any], output: (text: String, isError: Bool)?) -> ToolDisplay {
        switch name {
        case "Edit", "MultiEdit":
            let path = (input["file_path"] as? String) ?? "?"
            let newStr = (input["new_string"] as? String) ?? ""
            let snippet = firstLines(newStr, lines: 5)
            return ToolDisplay(name: name,
                               header: shortPath(path),
                               body: snippet.isEmpty ? nil : snippet,
                               isError: output?.isError ?? false)

        case "Write":
            let path = (input["file_path"] as? String) ?? "?"
            let content = (input["content"] as? String) ?? ""
            let snippet = firstLines(content, lines: 5)
            return ToolDisplay(name: name,
                               header: shortPath(path),
                               body: snippet.isEmpty ? nil : snippet,
                               isError: output?.isError ?? false)

        case "Bash":
            let cmd = (input["command"] as? String) ?? ""
            let outBody: String? = {
                guard let out = output?.text else { return nil }
                let lines = firstLines(out, lines: 10)
                return lines.isEmpty ? nil : lines
            }()
            return ToolDisplay(name: name,
                               header: firstLines(cmd, lines: 1).trimmingCharacters(in: .whitespaces),
                               body: outBody,
                               isError: output?.isError ?? false)

        default:
            // Other tools: just show a one-liner with a hint of the input
            let hint = inputHint(for: name, input: input)
            return ToolDisplay(name: name,
                               header: hint,
                               body: nil,
                               isError: output?.isError ?? false)
        }
    }

    static func firstLines(_ s: String, lines: Int) -> String {
        let split = s.split(separator: "\n", omittingEmptySubsequences: false)
        let take = split.prefix(lines).joined(separator: "\n")
        if split.count > lines {
            return take + "\n…"
        }
        return take
    }

    static func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: "/Users/arlong/Projects/", with: "")
            .replacingOccurrences(of: "/Users/arlong/", with: "~/")
    }

    static func inputHint(for name: String, input: [String: Any]) -> String {
        if let p = input["file_path"] as? String { return shortPath(p) }
        if let p = input["path"] as? String { return shortPath(p) }
        if let p = input["pattern"] as? String { return p }
        if let p = input["query"] as? String { return p }
        if let p = input["url"] as? String { return p }
        return ""
    }

    // MARK: - Time

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
