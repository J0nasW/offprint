import Foundation

/// Renders a block tree to GitHub-flavored Markdown.
public struct MarkdownWriter: Sendable {
    public struct Options: Sendable {
        /// Insert `<!-- page N -->` comments between pages.
        public var pageMarkers: Bool
        /// Emit a `> ⚠︎` note above tables whose structure the engine doubts.
        public var flagSuspectTables: Bool
        public init(pageMarkers: Bool = false, flagSuspectTables: Bool = true) {
            self.pageMarkers = pageMarkers
            self.flagSuspectTables = flagSuspectTables
        }
    }

    public var options: Options
    public init(options: Options = .init()) { self.options = options }

    public func write(_ document: OffprintDocument) -> String {
        var parts: [String] = []
        for page in document.pages {
            if options.pageMarkers {
                parts.append("<!-- page \(page.index + 1) -->")
            }
            let body = write(blocks: page.blocks)
            if !body.isEmpty { parts.append(body) }
        }
        return parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    public func write(blocks: [Block]) -> String {
        blocks.map(render).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: - Blocks

    private func render(_ block: Block) -> String {
        switch block {
        case .heading(let b):
            let text = Self.escapeInline(b.text).trimmed
            return text.isEmpty ? "" : String(repeating: "#", count: b.level) + " " + text

        case .paragraph(let b):
            return Self.escapeInline(b.text).trimmed

        case .list(let b):
            return renderList(b)

        case .table(let b):
            return renderTable(b)

        case .figure(let b):
            let alt = Self.escapeInline(b.caption ?? "").trimmed
            let image = "![\(alt)](\(Self.encodePath(b.path)))"
            // A caption is worth repeating below the image: alt text is invisible
            // in every rendered view of the document.
            guard let caption = b.caption?.trimmed, !caption.isEmpty else { return image }
            return image + "\n\n*" + Self.escapeInline(caption) + "*"

        case .formula(let b):
            let latex = b.latex.trimmed
            guard !latex.isEmpty else { return "" }
            return b.isInline ? "$\(latex)$" : "$$\n\(latex)\n$$"

        case .code(let b):
            let fence = Self.fence(for: b.text)
            return fence + (b.language ?? "") + "\n" + b.text.trimmedTrailingNewlines + "\n" + fence
        }
    }

    private func renderList(_ list: Block.List) -> String {
        var counters: [Int: Int] = [:]
        return list.items.map { item -> String in
            let depth = max(0, item.depth)
            let indent = String(repeating: "  ", count: depth)
            // Restart numbering whenever we come back out to a shallower level.
            for d in counters.keys where d > depth { counters[d] = nil }
            let marker: String
            if list.ordered {
                let n = (counters[depth] ?? 0) + 1
                counters[depth] = n
                marker = "\(n)."
            } else {
                marker = "-"
            }
            let text = Self.escapeInline(item.text).trimmed
            return indent + marker + " " + text
        }.joined(separator: "\n")
    }

    private func renderTable(_ table: Block.Table) -> String {
        let grid = Self.flatten(table)
        guard let header = grid.first, !header.isEmpty else { return "" }

        var lines: [String] = []
        if options.flagSuspectTables && table.structureSuspect {
            lines.append("> ⚠︎ Table structure is uncertain; verify against the source page.")
            lines.append("")
        }
        lines.append("| " + header.joined(separator: " | ") + " |")
        lines.append("|" + String(repeating: " --- |", count: header.count))
        for row in grid.dropFirst() {
            lines.append("| " + row.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Table flattening

    /// Expands row/column spans into a dense rectangular grid of escaped strings.
    ///
    /// Markdown has no way to express a spanning cell, so a spanned region
    /// carries its text in the top-left slot and leaves the covered slots empty.
    /// That is lossy, but it is lossy *visibly* — and the full span survives in
    /// the JSON export, which is the format that cares.
    public static func flatten(_ table: Block.Table) -> [[String]] {
        let width = table.columnCount
        guard width > 0 else { return [] }

        var grid: [[String?]] = []
        func ensureRow(_ r: Int) {
            while grid.count <= r { grid.append(Array(repeating: nil, count: width)) }
        }

        for (r, row) in table.rows.enumerated() {
            ensureRow(r)
            var col = 0
            for cell in row {
                // Skip past slots already claimed by a cell spanning down from above.
                while col < width, grid[r][col] != nil { col += 1 }
                guard col < width else { break }
                let text = escapeCell(cell.text)
                for dr in 0..<cell.rowSpan {
                    ensureRow(r + dr)
                    for dc in 0..<cell.colSpan where col + dc < width {
                        // Only the top-left slot of a span carries the text.
                        grid[r + dr][col + dc] = (dr == 0 && dc == 0) ? text : ""
                    }
                }
                col += cell.colSpan
            }
        }
        return grid.map { $0.map { $0 ?? "" } }
    }

    // MARK: - Escaping

    static func escapeCell(_ s: String) -> String {
        // A literal pipe would end the cell; newlines would end the row.
        escapeInline(s)
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .trimmed
    }

    /// Escapes only what would actually change the rendering. Over-escaping makes
    /// extracted prose unreadable in source form, which is half of why anyone
    /// wants Markdown instead of JSON.
    static func escapeInline(_ s: String) -> String {
        // Characters that always change the rendering, wherever they appear.
        let alwaysEscaped: Set<Character> = ["\\", "`", "*", "_", "[", "]", "<"]
        // Characters that only matter as the first thing on a line, and even then
        // only when followed by a space — otherwise they are ordinary punctuation
        // (a hyphenated word, a plus sign in a formula) and escaping them makes
        // extracted prose unreadable in source form.
        let lineStartMarkers: Set<Character> = ["#", "-", "+", ">"]

        var out = ""
        out.reserveCapacity(s.count)
        var atLineStart = true
        var index = s.startIndex

        while index < s.endIndex {
            let ch = s[index]
            let next = s.index(after: index)

            if alwaysEscaped.contains(ch) {
                out.append("\\")
                out.append(ch)
            } else if atLineStart, lineStartMarkers.contains(ch),
                      next == s.endIndex || s[next] == " " {
                out.append("\\")
                out.append(ch)
            } else if atLineStart, ch.isNumber, let dot = Self.orderedListMarkerEnd(s, from: index) {
                // "1. " at line start would become an ordered list item.
                out.append(contentsOf: s[index..<dot])
                out.append("\\.")
                index = s.index(after: dot)
                atLineStart = false
                continue
            } else {
                out.append(ch)
            }

            atLineStart = ch.isNewline
            index = next
        }
        return out
    }

    /// If the text at `from` looks like an ordered-list marker (`digits` + `.` + space),
    /// returns the index of the `.`; otherwise nil.
    private static func orderedListMarkerEnd(_ s: String, from: String.Index) -> String.Index? {
        var i = from
        while i < s.endIndex, s[i].isNumber { i = s.index(after: i) }
        guard i > from, i < s.endIndex, s[i] == "." else { return nil }
        let after = s.index(after: i)
        guard after == s.endIndex || s[after] == " " else { return nil }
        return i
    }

    static func encodePath(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }

    /// Picks a fence long enough to survive backticks inside the code itself.
    static func fence(for code: String) -> String {
        var longest = 0, run = 0
        for ch in code {
            run = (ch == "`") ? run + 1 : 0
            longest = max(longest, run)
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedTrailingNewlines: String {
        var s = self
        while let last = s.last, last.isNewline { s.removeLast() }
        return s
    }
}
