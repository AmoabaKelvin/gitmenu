import SwiftUI

/// Small block-level markdown renderer for comments. Inline syntax goes through AttributedString;
/// @mentions become links to the user's profile.
struct MarkdownText: View {
    let source: String
    var lineLimit: Int? = nil

    private enum Block {
        case paragraph(String), code(String), quote(String), list([String], ordered: Bool), heading(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .paragraph(let t):
                    inline(t)
                case .heading(let t):
                    inline(t).font(.system(size: 13, weight: .semibold))
                case .code(let t):
                    Text(t)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                case .quote(let t):
                    inline(t)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(.primary.opacity(0.15)).frame(width: 2) }
                case .list(let items, let ordered):
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(ordered ? "\(i + 1)." : "•").foregroundStyle(.secondary).frame(width: 14, alignment: .trailing)
                                inline(item)
                            }
                        }
                    }
                }
            }
        }
        .font(.system(size: 13))
        .lineLimit(lineLimit)
        .tint(.accentColor)
    }

    private func inline(_ text: String) -> Text {
        let linked = Self.linkMentions(text)
        if let a = try? AttributedString(markdown: linked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            var styled = a
            for run in styled.runs where run.inlinePresentationIntent?.contains(.code) == true {
                styled[run.range].font = .system(size: 12, design: .monospaced)
                styled[run.range].backgroundColor = .primary.opacity(0.06)
            }
            return Text(styled)
        }
        return Text(text)
    }

    private static let mention = try! NSRegularExpression(pattern: #"(?<![\w/`@])@([A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)\b"#)

    static func linkMentions(_ s: String) -> String {
        mention.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "[@$1](https://github.com/$1)")
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]? = nil
        var quote: [String] = []
        var list: [String] = []
        var ordered = false
        func flushPara() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] } }
        func flushQuote() { if !quote.isEmpty { out.append(.quote(quote.joined(separator: " "))); quote = [] } }
        func flushList() { if !list.isEmpty { out.append(.list(list, ordered: ordered)); list = [] } }
        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var c = code {
                if line.hasPrefix("```") { out.append(.code(c.joined(separator: "\n"))); code = nil } else { c.append(raw); code = c }
                continue
            }
            if line.hasPrefix("```") { flushPara(); flushQuote(); flushList(); code = []; continue }
            if line.isEmpty { flushPara(); flushQuote(); flushList(); continue }
            if line.hasPrefix("> ") || line == ">" { flushPara(); flushList(); quote.append(String(line.dropFirst(2))); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushPara(); flushQuote(); if !list.isEmpty && ordered { flushList() }
                ordered = false; list.append(String(line.dropFirst(2))); continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty, line[line.index(after: dot)...].hasPrefix(" ") {
                flushPara(); flushQuote(); if !list.isEmpty && !ordered { flushList() }
                ordered = true; list.append(String(line[line.index(dot, offsetBy: 2)...])); continue
            }
            if line.hasPrefix("#") {
                flushPara(); flushQuote(); flushList()
                out.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))); continue
            }
            flushQuote(); flushList(); para.append(line)
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flushPara(); flushQuote(); flushList()
        return out
    }
}
