import Foundation
import Testing
@testable import OffprintCore

@Suite("Markdown parsing")
struct MarkdownParserTests {

    let parser = MarkdownParser()

    @Test("Headings take their level from the hashes")
    func parsesHeadings() {
        let blocks = parser.parse("# One\n\n### Three")
        #expect(blocks.count == 2)
        guard case .heading(let first) = blocks[0], case .heading(let third) = blocks[1] else {
            Issue.record("expected headings"); return
        }
        #expect(first.level == 1 && first.text == "One")
        #expect(third.level == 3 && third.text == "Three")
    }

    @Test("A hash without a space is text, not a heading")
    func requiresSpaceAfterHashes() {
        // Real case: "#Docs: represents the total number of documents" is a
        // figure caption, and promoting it wrecks the outline.
        let blocks = parser.parse("#Docs: the number of documents")
        guard case .paragraph = blocks.first else {
            Issue.record("expected a paragraph, got \(blocks.first?.typeName ?? "nothing")"); return
        }
    }

    @Test("Tables keep their cells and drop the delimiter row")
    func parsesTables() throws {
        let markdown = """
        | Model | Score |
        | --- | --- |
        | BERT | 84.1 |
        | ModernBERT | 88.4 |
        """
        let blocks = parser.parse(markdown)
        guard case .table(let table) = blocks.first else {
            Issue.record("expected a table"); return
        }
        #expect(table.rows.count == 3)
        #expect(table.rows[0].map(\.text) == ["Model", "Score"])
        #expect(table.rows[2].map(\.text) == ["ModernBERT", "88.4"])
        #expect(!table.structureSuspect)
    }

    @Test("A table whose rows disagree on width is flagged")
    func flagsRaggedTables() {
        let markdown = """
        | a | b |
        | --- | --- |
        | 1 | 2 |
        | 3 |
        """
        guard case .table(let table) = parser.parse(markdown).first else {
            Issue.record("expected a table"); return
        }
        #expect(table.structureSuspect)
    }

    @Test("Escaped pipes stay inside their cell")
    func respectsEscapedPipes() {
        let markdown = "| a\\|b | c |\n| --- | --- |\n| d | e |"
        guard case .table(let table) = parser.parse(markdown).first else {
            Issue.record("expected a table"); return
        }
        #expect(table.rows[0].count == 2)
        #expect(table.rows[0][0].text == "a|b")
    }

    @Test("Lists carry their ordering and nesting")
    func parsesLists() {
        let blocks = parser.parse("1. one\n  1. nested\n2. two")
        guard case .list(let list) = blocks.first else {
            Issue.record("expected a list"); return
        }
        #expect(list.ordered)
        #expect(list.items.map(\.text) == ["one", "nested", "two"])
        #expect(list.items.map(\.depth) == [0, 1, 0])
    }

    @Test("Fenced code and display formulas survive")
    func parsesCodeAndFormulas() {
        let blocks = parser.parse("```swift\nlet x = 1\n```\n\n$$\nE = mc^2\n$$")
        guard case .code(let code) = blocks.first else {
            Issue.record("expected code"); return
        }
        #expect(code.language == "swift" && code.text == "let x = 1")
        guard case .formula(let formula) = blocks.last else {
            Issue.record("expected a formula"); return
        }
        #expect(formula.latex == "E = mc^2" && !formula.isInline)
    }

    @Test("Images become figures with their alt text as the caption")
    func parsesFigures() {
        guard case .figure(let figure) = parser.parse("![Figure 1](images/a.png)").first else {
            Issue.record("expected a figure"); return
        }
        #expect(figure.path == "images/a.png")
        #expect(figure.caption == "Figure 1")
    }

    @Test("Wrapped paragraph lines join into one block")
    func joinsWrappedLines() {
        let blocks = parser.parse("first line\nsecond line\n\nnext paragraph")
        #expect(blocks.count == 2)
        #expect(blocks[0].plainText == "first line second line")
    }

    // MARK: - Round trip

    @Test("Writing then parsing returns the same content")
    func roundTrips() throws {
        // The writer escapes; the parser must unescape, or repeated passes
        // accumulate backslashes.
        let original: [Block] = [
            .heading(.init(level: 2, text: "Results & Discussion")),
            .paragraph(.init(text: "A sentence with * and _ and [brackets].")),
            .list(.init(ordered: false, items: [.init(text: "alpha"), .init(text: "beta", depth: 1)])),
            .table(.init(rows: [
                [.init(text: "Model"), .init(text: "Score")],
                [.init(text: "a|b"), .init(text: "84.1")],
            ])),
            .code(.init(text: "let x = 1", language: "swift")),
            .formula(.init(latex: "e^{i\\pi} + 1 = 0")),
        ]

        let markdown = MarkdownWriter().write(blocks: original)
        let parsed = MarkdownParser().parse(markdown)

        #expect(parsed.map(\.typeName) == original.map(\.typeName))
        for (a, b) in zip(original, parsed) {
            #expect(a.plainText == b.plainText, "mismatch for \(a.typeName)")
        }
    }
}

@Suite("Maths round trip")
struct MathRoundTripTests {

    @Test("LaTeX commands survive parsing")
    func keepsLatexCommands() {
        // A backslash before a letter starts a LaTeX command; only a backslash
        // before punctuation is a Markdown escape. Stripping both turns
        // \mathcal{A} into the word mathcal{A}.
        let blocks = MarkdownParser().parse("The set $\\mathcal{A} = \\{A_1, \\dots\\}$ is fixed.")
        #expect(blocks.first?.plainText.contains("\\mathcal{A}") == true)
        #expect(blocks.first?.plainText.contains("\\dots") == true)
    }

    @Test("Markdown escapes are still removed")
    func stillUnescapesPunctuation() {
        let blocks = MarkdownParser().parse("a \\* b \\_ c")
        #expect(blocks.first?.plainText == "a * b _ c")
    }

    @Test("Maths spans are not escaped on the way out")
    func doesNotEscapeInsideMath() {
        // `$A_{1}$` escaped becomes `$A\_{1}$`, which renders as a literal
        // underscore and breaks the formula.
        let out = MarkdownWriter().write(blocks: [
            .paragraph(.init(text: "Given $A_{1}$ and $\\mathcal{B}$, the value_here is set.")),
        ])
        #expect(out.contains("$A_{1}$"))
        #expect(out.contains("$\\mathcal{B}$"))
        // Outside maths, escaping still happens.
        #expect(out.contains("value\\_here"))
    }

    @Test("A formula survives a full write and re-parse")
    func roundTripsFormula() {
        let original = "Embed $s_{j,1}$ with $\\mathcal{M}$ to get $e_{j}$."
        let markdown = MarkdownWriter().write(blocks: [.paragraph(.init(text: original))])
        let back = MarkdownParser().parse(markdown)
        #expect(back.first?.plainText == original)
    }
}
