import SwiftUI

/// An Agent reply rendered as Markdown the way a terminal agent shows it (omp, Claude Code, Codex; user 2026-09-12,
/// D69): headings at the body's size — bold, the first underlined — `-` and `1.` lists, a thin bar for quotes, code in
/// mono without a box, tables as a thin-lined grid. Foundation's parser marks the blocks (old D9: a PRD full of `#`
/// and `|` is unreadable raw). User bubbles stay plain text.
struct MarkdownText: View {
    let source: String
    /// The accent bar at the end of a reply still streaming in.
    var showsCursor = false
    /// The body's size: 13.5 in a bubble, smaller in 「运行过程」.
    var size: CGFloat = MarkdownBlocks.bodySize
    /// Mono throughout — 「运行过程」, a small terminal (9c, R1).
    var mono = false

    var body: some View {
        // A reply still streaming changes with every token: parsed fresh, not kept.
        let blocks = showsCursor ? MarkdownBlocks.parseFresh(source, size: size, mono: mono) : MarkdownBlocks.parse(source, size: size, mono: mono)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(block, cursor: showsCursor && index == blocks.count - 1)
                    .padding(.top, index == 0 ? 0 : MarkdownBlocks.gap(before: block, after: blocks[index - 1]))
            }
            if showsCursor, blocks.isEmpty || !blocks.last!.takesCursor { Self.cursorText }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        // A link opens only as a web page or a mail (review 2026-09-12): an Agent's words can come from a page it read,
        // and a file:// address or an app's own scheme would open things on this Mac.
        .environment(\.openURL, OpenURLAction { url in Self.opens(url) ? .systemAction : .discarded })
    }

    static func opens(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    private static var cursorText: Text {
        Text(AttributedString("▍", attributes: AttributeContainer().foregroundColor(Palette.accent.color)))
    }

    private func text(_ string: AttributedString, cursor: Bool) -> Text {
        cursor ? Text(string) + Self.cursorText : Text(string)
    }

    @ViewBuilder
    private func view(_ block: MarkdownBlock, cursor: Bool) -> some View {
        switch block {
        case .paragraph(let string):
            text(string, cursor: cursor).foregroundStyle(Palette.ink.color).lineSpacing(5)
        case let .heading(level, string):
            // Third level and below: bold in the muted ink, a step under the two above.
            text(string, cursor: cursor).foregroundStyle(level >= 3 ? Palette.inkMuted.color : Palette.ink.color).lineSpacing(5)
        case let .listItem(marker, depth, string):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).font(mono ? FormoraFont.mono(size) : FormoraFont.ui(size)).foregroundStyle(Palette.inkFaint.color)
                    .frame(minWidth: 10, alignment: .leading)
                text(string, cursor: cursor).foregroundStyle(Palette.ink.color).lineSpacing(5)
            }
            .padding(.leading, CGFloat(max(0, depth - 1)) * 16)
        case .quote(let string):
            text(string, cursor: cursor)
                .foregroundStyle(Palette.inkMuted.color)
                .lineSpacing(5)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Palette.lineStrong.color).frame(width: 2) }
        case .code(let code):
            // Indented mono, no box: a terminal's code block.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(FormoraFont.mono(size - 1)).foregroundStyle(Palette.ink.color).lineSpacing(3).fixedSize()
            }
            .padding(.leading, 12)
        case let .table(header, rows):
            MarkdownTable(header: header, rows: rows)
        case .rule:
            Rectangle().fill(Palette.line.color).frame(height: 1).padding(.vertical, 4)
        }
    }
}

/// A table the way a terminal draws one: thin lines around every cell, no fills, the header bold.
private struct MarkdownTable: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]

    var body: some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columns, id: \.self) { column in
                    cell(column < header.count ? header[column] : AttributedString(), lastRow: rows.isEmpty, lastColumn: column == columns - 1)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        cell(column < row.count ? row[column] : AttributedString(), lastRow: index == rows.count - 1,
                             lastColumn: column == columns - 1)
                    }
                }
            }
        }
        .overlay(Rectangle().strokeBorder(Palette.lineStrong.color, lineWidth: 1))
    }

    private func cell(_ string: AttributedString, lastRow: Bool, lastColumn: Bool) -> some View {
        Text(string)
            .foregroundStyle(Palette.ink.color)
            .lineSpacing(3)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .trailing) { if !lastColumn { Rectangle().fill(Palette.lineStrong.color).frame(width: 1) } }
            .overlay(alignment: .bottom) { if !lastRow { Rectangle().fill(Palette.lineStrong.color).frame(height: 1) } }
    }
}

enum MarkdownBlock: Equatable {
    case paragraph(AttributedString)
    case heading(Int, AttributedString)
    case listItem(marker: String, depth: Int, AttributedString)
    case quote(AttributedString)
    case code(String)
    case table(header: [AttributedString], rows: [[AttributedString]])
    case rule

    /// Blocks whose last line can carry the streaming cursor inline.
    var takesCursor: Bool {
        switch self {
        case .paragraph, .heading, .listItem, .quote: true
        case .code, .table, .rule: false
        }
    }

    var isListItem: Bool {
        if case .listItem = self { return true }
        return false
    }
}

enum MarkdownBlocks {
    static let bodySize: CGFloat = 13.5

    /// List items sit close together; everything else breathes.
    static func gap(before block: MarkdownBlock, after previous: MarkdownBlock) -> CGFloat {
        if block.isListItem, previous.isListItem { return 4 }
        if case .heading = block { return 14 }
        return 10
    }

    /// Parsed blocks by size and source (9a): a thread redraws its replies often, and parsing is the costly part.
    private final class Parsed {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, Parsed> = {
        let cache = NSCache<NSString, Parsed>()
        cache.totalCostLimit = 8_000_000
        return cache
    }()

    static func parse(_ source: String, size: CGFloat = bodySize, mono: Bool = false) -> [MarkdownBlock] {
        let key = "\(size)|\(mono)|\(source)" as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = parseFresh(source, size: size, mono: mono)
        cache.setObject(Parsed(blocks), forKey: key, cost: source.utf16.count)
        return blocks
    }

    static func parseFresh(_ source: String, size: CGFloat = bodySize, mono: Bool = false) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true, interpretedSyntax: .full,
                                                               failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: keepLineBreaks(source), options: options) else {
            return [.paragraph(styled(AttributedString(source), inline: nil, link: nil, size: size, mono: mono))]
        }
        var builder = Builder(size: size, mono: mono)
        var current: PresentationIntent?
        var buffer = AttributedString()
        var started = false
        for run in parsed.runs {
            let piece = styled(AttributedString(parsed[run.range].characters), inline: run.inlinePresentationIntent, link: run.link, size: size, mono: mono)
            if started, run.presentationIntent != current {
                builder.add(current, buffer)
                buffer = AttributedString()
            }
            current = run.presentationIntent
            started = true
            buffer += piece
        }
        if started { builder.add(current, buffer) }
        return builder.finish()
    }

    /// Models write single line breaks inside paragraphs and expect them kept; Markdown would fold them into
    /// spaces (old app 2026-09-06). Two trailing spaces make them hard breaks — never inside code fences or
    /// tables, and never before a line that starts a block of its own.
    static func keepLineBreaks(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        var inFence = false
        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence, index + 1 < lines.count else { continue }
            let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
            if line.isEmpty || next.isEmpty || line.hasPrefix("|") || line.hasPrefix("#") || startsBlock(next) { continue }
            lines[index] += "  "
        }
        return lines.joined(separator: "\n")
    }

    private static func startsBlock(_ line: String) -> Bool {
        for prefix in ["#", ">", "- ", "* ", "+ ", "```", "~~~", "|", "---", "***"] where line.hasPrefix(prefix) { return true }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, let after = line.dropFirst(digits.count).first, after == "." || after == ")" { return true }
        return false
    }

    private static func styled(_ text: AttributedString, inline: InlinePresentationIntent?, link: URL?, size: CGFloat, mono: Bool) -> AttributedString {
        var out = text
        let inline = inline ?? []
        if inline.contains(.code) {
            // A terminal colours inline code rather than boxing it.
            out.font = FormoraFont.mono(size - 1)
            out.foregroundColor = Palette.accent.color
        } else {
            out.font = font(size, weight: inline.contains(.stronglyEmphasized) ? 600 : 400, mono: mono)
        }
        if inline.contains(.strikethrough) { out.strikethroughStyle = .single }
        if let link {
            out.link = link
            out.foregroundColor = Palette.accent.color
            out.underlineStyle = .single
        }
        return out
    }

    static func font(_ size: CGFloat, weight: Int, mono: Bool) -> Font {
        mono ? FormoraFont.mono(size, weight: weight) : FormoraFont.ui(size, weight: weight)
    }

    /// Collects runs into blocks; table cells are gathered until the table ends.
    private struct Builder {
        let size: CGFloat
        let mono: Bool
        var blocks: [MarkdownBlock] = []
        var tableHeader: [AttributedString] = []
        var tableRows: [[AttributedString]] = []
        var rowKey: String?
        var inTable = false

        init(size: CGFloat, mono: Bool) {
            self.size = size
            self.mono = mono
        }

        mutating func add(_ intent: PresentationIntent?, _ text: AttributedString) {
            let kinds = intent?.components.map(\.kind) ?? []
            var isHeaderRow = false
            var rowIndex: Int?
            var isCell = false
            for kind in kinds {
                switch kind {
                case .tableCell: isCell = true
                case .tableHeaderRow: isHeaderRow = true
                case .tableRow(let index): rowIndex = index
                default: break
                }
            }
            if isCell {
                inTable = true
                if isHeaderRow {
                    var bold = text
                    bold.font = MarkdownBlocks.font(size, weight: 600, mono: mono)
                    tableHeader.append(bold)
                } else {
                    let key = "\(rowIndex ?? -1)"
                    if key != rowKey {
                        tableRows.append([])
                        rowKey = key
                    }
                    tableRows[tableRows.count - 1].append(text)
                }
                return
            }
            closeTable()
            blocks.append(block(kinds, text))
        }

        mutating func finish() -> [MarkdownBlock] {
            closeTable()
            return blocks
        }

        private mutating func closeTable() {
            guard inTable else { return }
            blocks.append(.table(header: tableHeader, rows: tableRows))
            tableHeader = []
            tableRows = []
            rowKey = nil
            inTable = false
        }

        private func block(_ kinds: [PresentationIntent.Kind], _ text: AttributedString) -> MarkdownBlock {
            for kind in kinds {
                switch kind {
                case .codeBlock:
                    var code = String(text.characters)
                    while code.hasSuffix("\n") { code.removeLast() }
                    return .code(code)
                case .header(let level):
                    // A terminal can't make a line bigger (D69): bold says it's a heading, the first is underlined.
                    var heading = text
                    heading.font = MarkdownBlocks.font(size, weight: 700, mono: mono)
                    if level == 1 { heading.underlineStyle = .single }
                    return .heading(level, heading)
                case .thematicBreak:
                    return .rule
                default:
                    continue
                }
            }
            let depth = kinds.filter { if case .orderedList = $0 { true } else if case .unorderedList = $0 { true } else { false } }.count
            if depth > 0 {
                var ordinal: Int?
                var ordered = false
                for kind in kinds {
                    if case .listItem(let number) = kind, ordinal == nil { ordinal = number }
                    if case .orderedList = kind { ordered = true; break }
                    if case .unorderedList = kind { break }
                }
                return .listItem(marker: ordered ? "\(ordinal ?? 1)." : "-", depth: depth, text)
            }
            if kinds.contains(where: { if case .blockQuote = $0 { true } else { false } }) { return .quote(text) }
            return .paragraph(text)
        }
    }
}
