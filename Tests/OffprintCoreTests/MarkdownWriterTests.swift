import Testing
@testable import OffprintCore

@Suite("Markdown serialisation")
struct MarkdownWriterTests {

    let writer = MarkdownWriter()

    // MARK: - Escaping

    @Test("Emphasis and link characters are escaped")
    func escapesInlineMarkup() {
        let out = writer.write(blocks: [.paragraph(.init(text: "a * b _ c [d] <e>"))])
        // `<` opens raw HTML anywhere, so it is always escaped; `>` only means
        // anything at the start of a line, where the line-start rule covers it.
        #expect(out == "a \\* b \\_ c \\[d\\] \\<e>")
        #expect(writer.write(blocks: [.paragraph(.init(text: "> quote"))]) == "\\> quote")
    }

    @Test("List and heading markers are escaped only where they would take effect")
    func escapesLineStartMarkersOnly() {
        // Would start a list / heading.
        #expect(writer.write(blocks: [.paragraph(.init(text: "- item"))]) == "\\- item")
        #expect(writer.write(blocks: [.paragraph(.init(text: "# title"))]) == "\\# title")
        #expect(writer.write(blocks: [.paragraph(.init(text: "1. first"))]) == "1\\. first")
        // Ordinary punctuation mid-sentence must survive untouched: escaping every
        // hyphen makes extracted prose unreadable in source form.
        #expect(writer.write(blocks: [.paragraph(.init(text: "well-known 1.5 kg"))])
                == "well-known 1.5 kg")
    }

    @Test("Pipes and newlines inside cells cannot break the table")
    func escapesCellContent() {
        let table = Block.Table(rows: [
            [.init(text: "head"), .init(text: "cols")],
            [.init(text: "a|b"), .init(text: "line1\nline2")],
        ])
        let out = writer.write(blocks: [.table(table)])
        #expect(out.contains("a\\|b"))
        #expect(out.contains("line1<br>line2"))
        // Every row must present the same number of cells as the header, or the
        // table stops rendering as a table.
        let rows = out.split(separator: "\n").filter { $0.hasPrefix("|") }
        #expect(rows.count == 3)   // header, separator, one body row
        let cellCounts = Set(rows.map { Self.unescapedPipes(in: String($0)) })
        #expect(cellCounts.count == 1)
    }

    // MARK: - Tables

    @Test("Spanning cells expand into a dense grid")
    func flattensSpans() {
        // A 2x2 table whose first cell spans both columns of the first row.
        let table = Block.Table(rows: [
            [.init(text: "wide", rowSpan: 1, colSpan: 2)],
            [.init(text: "a"), .init(text: "b")],
        ])
        let grid = MarkdownWriter.flatten(table)
        #expect(grid.count == 2)
        #expect(grid[0] == ["wide", ""])
        #expect(grid[1] == ["a", "b"])
    }

    @Test("A cell spanning rows leaves the covered slot empty, not duplicated")
    func flattensRowSpans() {
        let table = Block.Table(rows: [
            [.init(text: "tall", rowSpan: 2), .init(text: "x")],
            [.init(text: "y")],
        ])
        let grid = MarkdownWriter.flatten(table)
        #expect(grid[0] == ["tall", "x"])
        // "y" must land in column 1, because column 0 is still occupied by "tall".
        #expect(grid[1] == ["", "y"])
    }

    @Test("Suspect tables are flagged in the output")
    func flagsSuspectTables() {
        let table = Block.Table(rows: [[.init(text: "a"), .init(text: "b")]],
                                structureSuspect: true)
        #expect(writer.write(blocks: [.table(table)]).contains("⚠︎"))
        let clean = Block.Table(rows: [[.init(text: "a"), .init(text: "b")]])
        #expect(!writer.write(blocks: [.table(clean)]).contains("⚠︎"))
    }

    // MARK: - Other blocks

    @Test("Nested list items indent and ordered lists renumber per level")
    func rendersNestedLists() {
        let list = Block.List(ordered: true, items: [
            .init(text: "one", depth: 0),
            .init(text: "one a", depth: 1),
            .init(text: "one b", depth: 1),
            .init(text: "two", depth: 0),
        ])
        let out = writer.write(blocks: [.list(list)])
        #expect(out == "1. one\n  1. one a\n  2. one b\n2. two")
    }

    @Test("Code fences grow to survive backticks in the code")
    func choosesSafeFence() {
        #expect(MarkdownWriter.fence(for: "plain") == "```")
        #expect(MarkdownWriter.fence(for: "a ``` b") == "````")
    }

    @Test("Figures render as an image with the caption repeated below")
    func rendersFigures() {
        let out = writer.write(blocks: [
            .figure(.init(path: "images/p001-fig01.png", caption: "Figure 1: results")),
        ])
        #expect(out.contains("![Figure 1: results](images/p001-fig01.png)"))
        #expect(out.contains("*Figure 1: results*"))
    }

    /// Counts `|` delimiters, ignoring ones escaped as `\|` inside cell text.
    static func unescapedPipes(in row: String) -> Int {
        var count = 0
        var escaped = false
        for character in row {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "|" { count += 1 }
        }
        return count
    }

    @Test("Paths with spaces are percent-encoded so the link resolves")
    func encodesFigurePaths() {
        let out = writer.write(blocks: [.figure(.init(path: "images/my figure.png"))])
        #expect(out.contains("(images/my%20figure.png)"))
    }
}
