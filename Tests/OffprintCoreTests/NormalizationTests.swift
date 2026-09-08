import Foundation
import Testing
@testable import OffprintCore

@Suite("Table of contents")
struct ContentsDetectorTests {

    func line(_ text: String, y: Double = 0) -> TextLayerGeometry.Line {
        .init(text: text, bbox: .init(x: 0, y: y, width: 400, height: 11), column: 0, fontSize: 11)
    }

    @Test("Entries are parsed into title, page and depth")
    func parsesEntries() throws {
        let entry = try #require(ContentsDetector.entry(from: "1.4 International Organisations ......... 81"))
        #expect(entry.title == "1.4 International Organisations")
        #expect(entry.page == "81")
        #expect(entry.depth == 2)
    }

    @Test("Roman page numbers are accepted for front matter")
    func acceptsRomanNumerals() throws {
        let entry = try #require(ContentsDetector.entry(from: "Foreword .................... iv"))
        #expect(entry.page == "iv")
        #expect(entry.title == "Foreword")
    }

    @Test("Prose that happens to end in a number is not an entry")
    func rejectsProse() {
        // No leader before the number.
        #expect(ContentsDetector.entry(from: "the figure rose to 2019") == nil)
        // A sentence fragment.
        #expect(ContentsDetector.entry(from: "as discussed above, ... 12") == nil)
        #expect(ContentsDetector.entry(from: "12") == nil)
    }

    @Test("A numbered entry counts even when the leader was lost in extraction")
    func acceptsNumberedWithoutLeader() throws {
        let entry = try #require(ContentsDetector.entry(from: "3.2 Model introduction 42"))
        #expect(entry.title == "3.2 Model introduction")
        #expect(entry.page == "42")
    }

    @Test("A run of entries becomes a nested list, not a table")
    func buildsNestedList() throws {
        // The failure this exists to prevent: a contents page is two columns of
        // text, so a table detector claims it and then cannot verify it.
        let lines = [
            line("1 Policy perspective ................ 10", y: 0),
            line("1.1 European level ................. 12", y: 20),
            line("1.1.1 Commission, 2021 ............. 13", y: 40),
            line("2 Research perspective ............. 91", y: 60),
        ]
        let found = ContentsDetector.detect(in: lines)
        #expect(found.count == 1)
        let list = try #require(found.first?.list)
        #expect(list.items.map(\.depth) == [0, 1, 2, 0])
        #expect(list.items[0].text == "1 Policy perspective · p. 10")
    }

    @Test("Two stray entries are not a contents section")
    func requiresARun() {
        let lines = [line("Something ..... 3", y: 0), line("Other ..... 4", y: 20)]
        #expect(ContentsDetector.detect(in: lines).isEmpty)
    }
}

@Suite("Block normalization")
struct BlockNormalizerTests {

    @Test("A bullet column becomes a list")
    func convertsBulletTables() throws {
        // Both engines produce this: a bulleted list sets its markers in a
        // consistent column, which is exactly what column detection looks for.
        let table = Block.Table(rows: [
            [.init(text: "●"), .init(text: "First aim")],
            [.init(text: "●"), .init(text: "Second aim")],
        ])
        let out = BlockNormalizer.normalize([.table(table)])
        guard case .list(let list) = out.first else {
            Issue.record("expected a list, got \(out.first?.typeName ?? "nothing")"); return
        }
        #expect(!list.ordered)
        #expect(list.items.map(\.text) == ["First aim", "Second aim"])
    }

    @Test("A row with no marker continues the item above it")
    func mergesWrappedRows() throws {
        let table = Block.Table(rows: [
            [.init(text: "●"), .init(text: "A long aim that wraps")],
            [.init(text: ""), .init(text: "onto a second line")],
            [.init(text: "●"), .init(text: "Another aim")],
        ])
        guard case .list(let list) = BlockNormalizer.normalize([.table(table)]).first else {
            Issue.record("expected a list"); return
        }
        #expect(list.items.count == 2)
        #expect(list.items[0].text == "A long aim that wraps onto a second line")
    }

    @Test("A real table is left alone")
    func keepsRealTables() {
        let table = Block.Table(rows: [
            [.init(text: "Model"), .init(text: "Score")],
            [.init(text: "BERT"), .init(text: "84.1")],
        ])
        guard case .table = BlockNormalizer.normalize([.table(table)]).first else {
            Issue.record("expected the table to survive"); return
        }
    }

    @Test("The uncertainty flag is cleared for tables that look sound")
    func clearsUnearnedWarnings() {
        // Flagging every geometrically-derived table trains readers to ignore
        // the warning, which defeats its purpose.
        let sound = Block.Table(rows: [
            [.init(text: "a"), .init(text: "b")],
            [.init(text: "c"), .init(text: "d")],
        ], structureSuspect: true)
        guard case .table(let out) = BlockNormalizer.normalize([.table(sound)]).first else {
            Issue.record("expected a table"); return
        }
        #expect(!out.structureSuspect)
    }

    @Test("A grid full of sentences keeps its warning")
    func keepsEarnedWarnings() {
        let sentence = String(repeating: "word ", count: 20)
        let prose = Block.Table(rows: [
            [.init(text: sentence), .init(text: sentence)],
            [.init(text: sentence), .init(text: sentence)],
        ], structureSuspect: true)
        guard case .table(let out) = BlockNormalizer.normalize([.table(prose)]).first else {
            Issue.record("expected a table"); return
        }
        #expect(out.structureSuspect)
    }

    @Test("A mostly-empty grid keeps its warning")
    func flagsSparseGrids() {
        let sparse = Block.Table(rows: [
            [.init(text: "a"), .init(text: ""), .init(text: "")],
            [.init(text: ""), .init(text: ""), .init(text: "")],
            [.init(text: "b"), .init(text: ""), .init(text: "")],
        ], structureSuspect: true)
        guard case .table(let out) = BlockNormalizer.normalize([.table(sparse)]).first else {
            Issue.record("expected a table"); return
        }
        #expect(out.structureSuspect)
    }
}

@Suite("Document statistics")
struct DocumentStatisticsTests {

    @Test("Counts come from the block text")
    func countsText() {
        let document = OffprintDocument(
            source: .init(filename: "a.pdf", pages: 1),
            engine: .init(tier: .fast, appVersion: "0.1.0"),
            pages: [PageContent(index: 0, width: 600, height: 800, blocks: [
                .heading(.init(level: 1, text: "Title here")),
                .paragraph(.init(text: "Four words in this.")),
                .table(.init(rows: [[.init(text: "a")]], structureSuspect: true)),
            ], engine: .textLayer)])

        let stats = document.computedStatistics
        #expect(stats.pages == 1)
        #expect(stats.headings == 1)
        #expect(stats.tables == 1)
        #expect(stats.uncertainTables == 1)
        #expect(stats.words == 7)   // "Title here" + "Four words in this." + "a"
    }

    @Test("CJK text is estimated more densely than Latin")
    func weightsScripts() {
        // A token covers roughly four Latin characters but around one CJK
        // character, so a fixed ratio would badly under-count Japanese.
        let latin = DocumentStatistics.estimateTokens(in: String(repeating: "a", count: 400))
        let cjk = DocumentStatistics.estimateTokens(in: String(repeating: "文", count: 400))
        #expect(latin < cjk)
        #expect(latin > 80 && latin < 130)
    }
}
