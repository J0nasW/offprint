import Foundation

/// Parses Markdown back into the block tree.
///
/// The model tiers emit Markdown text rather than structure, but Offprint's JSON
/// export, its preview, and its table warnings all work on blocks. Rather than
/// treat the model's output as an opaque string, it is parsed once here so both
/// exports keep coming from the same tree — a model-read page and a text-layer
/// page then behave identically everywhere downstream.
///
/// This is deliberately not a general CommonMark implementation: it covers what
/// document OCR models actually produce.
public struct MarkdownParser: Sendable {

    public init() {}

    public func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { index += 1; continue }

            if let fence = Self.codeFence(trimmed) {
                let (block, next) = parseCode(lines, from: index, fence: fence)
                if let block { blocks.append(block) }
                index = next
                continue
            }

            if trimmed == "$$" {
                let (block, next) = parseDisplayFormula(lines, from: index)
                if let block { blocks.append(block) }
                index = next
                continue
            }

            if let heading = Self.heading(trimmed) {
                blocks.append(.heading(heading))
                index += 1
                continue
            }

            if Self.isTableRow(trimmed), index + 1 < lines.count,
               Self.isTableDelimiter(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
                let (block, next) = parseTable(lines, from: index)
                if let block { blocks.append(block) }
                index = next
                continue
            }

            if Self.listMarker(trimmed) != nil {
                let (block, next) = parseList(lines, from: index)
                if let block { blocks.append(block) }
                index = next
                continue
            }

            if let figure = Self.figure(trimmed) {
                blocks.append(.figure(figure))
                index += 1
                continue
            }

            let (block, next) = parseParagraph(lines, from: index)
            if let block { blocks.append(block) }
            index = next
        }
        return blocks
    }

    // MARK: - Blocks

    static func heading(_ line: String) -> Block.Heading? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }
        // A heading needs a space after its hashes; `#Docs` is ordinary text.
        guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
        let text = unescape(String(line[index...]).trimmingCharacters(in: .whitespaces))
        guard !text.isEmpty else { return nil }
        return .init(level: level, text: text)
    }

    static func codeFence(_ line: String) -> String? {
        let ticks = line.prefix { $0 == "`" }
        return ticks.count >= 3 ? String(ticks) : nil
    }

    func parseCode(_ lines: [String], from start: Int, fence: String) -> (Block?, Int) {
        let opener = lines[start].trimmingCharacters(in: .whitespaces)
        let language = String(opener.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
        var body: [String] = []
        var index = start + 1
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                index += 1
                break
            }
            body.append(lines[index])
            index += 1
        }
        guard !body.isEmpty else { return (nil, index) }
        return (.code(.init(text: body.joined(separator: "\n"),
                            language: language.isEmpty ? nil : language)), index)
    }

    func parseDisplayFormula(_ lines: [String], from start: Int) -> (Block?, Int) {
        var body: [String] = []
        var index = start + 1
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "$$" {
            body.append(lines[index])
            index += 1
        }
        if index < lines.count { index += 1 }
        let latex = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !latex.isEmpty else { return (nil, index) }
        return (.formula(.init(latex: latex, isInline: false)), index)
    }

    static func isTableRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.count > 1
    }

    /// The `| --- | --- |` line that turns the row above it into a header.
    static func isTableDelimiter(_ line: String) -> Bool {
        guard isTableRow(line) else { return false }
        let cells = splitRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let stripped = cell.trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { return false }
            return stripped.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    func parseTable(_ lines: [String], from start: Int) -> (Block?, Int) {
        var rows: [[Block.Table.Cell]] = []
        var index = start
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard Self.isTableRow(line) else { break }
            index += 1
            if Self.isTableDelimiter(line) { continue }
            rows.append(Self.splitRow(line).map {
                .init(text: Self.unescape($0.trimmingCharacters(in: .whitespaces))
                    .replacingOccurrences(of: "<br>", with: "\n"))
            })
        }
        guard !rows.isEmpty else { return (nil, max(index, start + 1)) }
        // Ragged rows mean the model lost the column count part way through.
        let widths = Set(rows.map(\.count))
        return (.table(.init(rows: rows, structureSuspect: widths.count > 1)), index)
    }

    /// Splits a row on unescaped pipes.
    static func splitRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line.dropFirst() {   // leading pipe
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" { escaped = true; current.append(character); continue }
            if character == "|" { cells.append(current); current = ""; continue }
            current.append(character)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { cells.append(current) }
        return cells
    }

    /// Returns the indent depth and whether the marker is ordered.
    static func listMarker(_ line: String) -> (ordered: Bool, content: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return (false, String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (true, String(rest.dropFirst(2)))
    }

    func parseList(_ lines: [String], from start: Int) -> (Block?, Int) {
        var items: [Block.List.Item] = []
        var ordered = false
        var index = start

        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let marker = Self.listMarker(trimmed) else { break }
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            if marker.ordered { ordered = true }
            items.append(.init(text: Self.unescape(marker.content.trimmingCharacters(in: .whitespaces)),
                               depth: indent / 2))
            index += 1
        }
        guard !items.isEmpty else { return (nil, start + 1) }
        return (.list(.init(ordered: ordered, items: items)), index)
    }

    static func figure(_ line: String) -> Block.Figure? {
        guard line.hasPrefix("!["), let close = line.firstIndex(of: "]"),
              line[line.index(after: close)...].hasPrefix("(") ,
              let end = line.lastIndex(of: ")") else { return nil }
        let altStart = line.index(line.startIndex, offsetBy: 2)
        let alt = String(line[altStart..<close])
        let pathStart = line.index(close, offsetBy: 2)
        guard pathStart < end else { return nil }
        let path = String(line[pathStart..<end])
        return .init(path: path, caption: alt.isEmpty ? nil : unescape(alt))
    }

    func parseParagraph(_ lines: [String], from start: Int) -> (Block?, Int) {
        var body: [String] = []
        var index = start
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            // Anything that begins another kind of block ends the paragraph.
            if Self.heading(trimmed) != nil || Self.isTableRow(trimmed)
                || Self.listMarker(trimmed) != nil || Self.codeFence(trimmed) != nil
                || trimmed == "$$" || Self.figure(trimmed) != nil {
                break
            }
            body.append(trimmed)
            index += 1
        }
        guard !body.isEmpty else { return (nil, start + 1) }
        let text = Self.unescape(body.joined(separator: " "))
        return (.paragraph(.init(text: text)), max(index, start + 1))
    }

    /// Removes backslash escapes, so a round trip through the writer and back
    /// returns the original text rather than accumulating backslashes.
    ///
    /// Only a backslash before punctuation is an escape. A backslash before a
    /// letter starts a LaTeX command, and stripping those turns the formula a
    /// model just read — `\mathcal{A}` — into the word `mathcal{A}`.
    static func unescape(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\\", next < text.endIndex, text[next].isASCIIPunctuation {
                out.append(text[next])
                index = text.index(after: next)
                continue
            }
            out.append(character)
            index = next
        }
        return out
    }
}
