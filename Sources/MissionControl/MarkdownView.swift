import SwiftUI
import AppKit

/// Lightweight Markdown renderer for chat messages — covers the 95% of what
/// Claude actually emits (fenced code blocks, headings, lists, inline bold/
/// italic/code/links) without dragging in a third-party dep. Anything we
/// don't recognize falls through to AttributedString so emphasis still works.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { idx in
                view(for: blocks[idx])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [MarkdownBlock] { MarkdownParser.parse(text) }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let s):
            Text(s)
                .font(.system(size: headingSize(level), weight: .semibold))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .codeBlock(let lang, let code):
            CodeFenceView(language: lang, code: code)
        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(i + 1)." : "•")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        InlineMarkdownText(items[i])
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .quote(let s):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                InlineMarkdownText(s)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .paragraph(let s):
            InlineMarkdownText(s)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 19
        case 2: return 17
        case 3: return 15
        default: return 14
        }
    }
}

/// Renders a single line/paragraph using SwiftUI's built-in markdown parser
/// (handles **bold**, *italic*, `code`, [link](url), ~strike~). Falls back to
/// plain Text if the input fails to parse.
struct InlineMarkdownText: View {
    let raw: String

    init(_ raw: String) { self.raw = raw }

    var body: some View {
        if let attr = try? AttributedString(markdown: raw,
                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attr)
                .font(.system(.body))
                .textSelection(.enabled)
        } else {
            Text(raw)
                .font(.system(.body))
                .textSelection(.enabled)
        }
    }
}

struct CodeFenceView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                HStack {
                    Text(language)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(code, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.black.opacity(0.25))
            }
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }
}

// MARK: - Block model

enum MarkdownBlock {
    case heading(Int, String)
    case codeBlock(String?, String)
    case list([String], ordered: Bool)
    case quote(String)
    case paragraph(String)
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { i += 1; break }
                    body.append(l)
                    i += 1
                }
                blocks.append(.codeBlock(lang.isEmpty ? nil : lang, body.joined(separator: "\n")))
                continue
            }

            // Heading
            if let headingMatch = matchHeading(trimmed) {
                blocks.append(.heading(headingMatch.0, headingMatch.1))
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") {
                var quoteLines: [String] = [String(trimmed.dropFirst(2))]
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("> ") { quoteLines.append(String(t.dropFirst(2))); i += 1 }
                    else { break }
                }
                blocks.append(.quote(quoteLines.joined(separator: " ")))
                continue
            }

            // Unordered list
            if let item = unorderedListItem(trimmed) {
                var items: [String] = [item]
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if let it = unorderedListItem(t) { items.append(it); i += 1 }
                    else { break }
                }
                blocks.append(.list(items, ordered: false))
                continue
            }

            // Ordered list
            if let item = orderedListItem(trimmed) {
                var items: [String] = [item]
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if let it = orderedListItem(t) { items.append(it); i += 1 }
                    else { break }
                }
                blocks.append(.list(items, ordered: true))
                continue
            }

            // Blank line
            if trimmed.isEmpty { i += 1; continue }

            // Paragraph: consume until blank or block-level marker
            var para: [String] = [line]
            i += 1
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty
                    || t.hasPrefix("```")
                    || matchHeading(t) != nil
                    || unorderedListItem(t) != nil
                    || orderedListItem(t) != nil
                    || t.hasPrefix("> ") { break }
                para.append(l); i += 1
            }
            blocks.append(.paragraph(para.joined(separator: "\n")))
        }
        return blocks
    }

    private static func matchHeading(_ s: String) -> (Int, String)? {
        var level = 0
        for ch in s {
            if ch == "#" && level < 6 { level += 1 } else { break }
        }
        guard level > 0 else { return nil }
        let rest = String(s.dropFirst(level))
        guard rest.hasPrefix(" ") else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func unorderedListItem(_ s: String) -> String? {
        if s.hasPrefix("- ") { return String(s.dropFirst(2)) }
        if s.hasPrefix("* ") { return String(s.dropFirst(2)) }
        if s.hasPrefix("+ ") { return String(s.dropFirst(2)) }
        return nil
    }

    private static func orderedListItem(_ s: String) -> String? {
        // Match "N. " or "N) " prefix where N is 1+ digits
        var idx = s.startIndex
        var seenDigit = false
        while idx < s.endIndex, s[idx].isNumber { seenDigit = true; idx = s.index(after: idx) }
        guard seenDigit, idx < s.endIndex else { return nil }
        let mark = s[idx]
        guard mark == "." || mark == ")" else { return nil }
        let after = s.index(after: idx)
        guard after < s.endIndex, s[after] == " " else { return nil }
        return String(s[s.index(after: after)...])
    }
}
