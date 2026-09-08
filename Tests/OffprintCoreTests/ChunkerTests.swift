import Foundation
import Testing
@testable import OffprintCore

@Suite("Chunking")
struct ChunkerTests {

    func document(_ blocks: [Block]) -> OffprintDocument {
        OffprintDocument(
            source: .init(filename: "a.pdf", pages: 1),
            engine: .init(tier: .fast, appVersion: "0.1.0"),
            pages: [PageContent(index: 0, width: 600, height: 800,
                                blocks: blocks, engine: .textLayer)])
    }

    func paragraph(_ words: Int) -> Block {
        .paragraph(.init(text: String(repeating: "word ", count: words)))
    }

    @Test("A chunk carries the breadcrumb of its own section")
    func carriesHeadingPath() throws {
        let chunks = Chunker(options: .init(targetTokens: 120)).chunk(document([
            .heading(.init(level: 1, text: "Methods")),
            .heading(.init(level: 2, text: "Datasets")),
            paragraph(200),
        ]))
        let last = try #require(chunks.last)
        #expect(last.headingPath == ["Methods", "Datasets"])
        #expect(last.contextualText.hasPrefix("Methods › Datasets"))
    }

    @Test("No chunk spans a section boundary")
    func neverSpansSections() {
        // A chunk straddling two sections answers questions about neither.
        let chunks = Chunker(options: .init(targetTokens: 4000)).chunk(document([
            .heading(.init(level: 1, text: "One")),
            paragraph(10),
            .heading(.init(level: 1, text: "Two")),
            paragraph(10),
        ]))
        #expect(chunks.count == 2)
        #expect(chunks[0].headingPath == ["One"])
        #expect(chunks[1].headingPath == ["Two"])
    }

    @Test("A deeper heading nests, a sibling replaces")
    func maintainsHeadingStack() {
        let chunks = Chunker(options: .init(targetTokens: 4000)).chunk(document([
            .heading(.init(level: 1, text: "One")),
            .heading(.init(level: 2, text: "One A")),
            paragraph(10),
            .heading(.init(level: 2, text: "One B")),
            paragraph(10),
        ]))
        let paths = chunks.map(\.headingPath)
        #expect(paths.contains(["One", "One A"]))
        #expect(paths.contains(["One", "One B"]))
        // "One A" must not leak into "One B"'s trail.
        #expect(!paths.contains(["One", "One A", "One B"]))
    }

    @Test("Section addresses number siblings and nest children")
    func assignsSectionAddresses() {
        let chunks = Chunker(options: .init(targetTokens: 4000)).chunk(document([
            .heading(.init(level: 1, text: "One")), paragraph(5),
            .heading(.init(level: 2, text: "One A")), paragraph(5),
            .heading(.init(level: 2, text: "One B")), paragraph(5),
            .heading(.init(level: 1, text: "Two")), paragraph(5),
        ]))
        #expect(chunks.map(\.sectionID) == ["1", "1.1", "1.2", "2"])
    }

    @Test("A long section splits into numbered parts")
    func numbersPartsWithinSection() throws {
        let blocks: [Block] = [.heading(.init(level: 1, text: "Long"))]
            + (0..<10).map { _ in paragraph(60) }
        let chunks = Chunker(options: .init(targetTokens: 200)).chunk(document(blocks))
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.partCount == chunks.count })
        #expect(chunks.map(\.partIndex) == Array(1...chunks.count))
        // The reader is told it is holding a fragment.
        #expect(chunks[0].contextualText.contains("part 1 of"))
    }

    @Test("Chunks link to their neighbours so a hit can be widened")
    func linksNeighbours() {
        let blocks: [Block] = (0..<8).map { _ in paragraph(60) }
        let chunks = Chunker(options: .init(targetTokens: 150)).chunk(document(blocks))
        #expect(chunks.first?.previousID == nil)
        #expect(chunks.last?.nextID == nil)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            #expect(a.nextID == b.id)
            #expect(b.previousID == a.id)
        }
    }

    @Test("A table is never split across chunks")
    func keepsTablesWhole() {
        let rows = (0..<40).map { i in
            [Block.Table.Cell(text: "row \(i)"), Block.Table.Cell(text: "value \(i)")]
        }
        let chunks = Chunker(options: .init(targetTokens: 50, minimumTokens: 10)).chunk(document([
            paragraph(40), .table(.init(rows: rows)), paragraph(40),
        ]))
        #expect(chunks.filter { $0.blockTypes.contains("table") }.count == 1)
    }

    @Test("The outline mirrors the section tree")
    func buildsOutline() throws {
        let chunker = Chunker(options: .init(targetTokens: 4000))
        let doc = document([
            .heading(.init(level: 1, text: "One")), paragraph(5),
            .heading(.init(level: 2, text: "One A")), paragraph(5),
            .heading(.init(level: 1, text: "Two")), paragraph(5),
        ])
        let chunks = chunker.chunk(doc)
        let outline = chunker.outline(doc, chunks: chunks)
        #expect(outline.sections.count == 2)
        #expect(outline.sections[0].title == "One")
        #expect(outline.sections[0].children.count == 1)
        #expect(outline.sections[0].children[0].title == "One A")
        #expect(outline.totalChunks == chunks.count)
    }

    @Test("Pages each chunk draws from are recorded")
    func recordsPages() {
        let doc = OffprintDocument(
            source: .init(filename: "a.pdf", pages: 2),
            engine: .init(tier: .fast, appVersion: "0.1.0"),
            pages: [
                PageContent(index: 0, width: 600, height: 800, blocks: [paragraph(20)], engine: .textLayer),
                PageContent(index: 1, width: 600, height: 800, blocks: [paragraph(20)], engine: .textLayer),
            ])
        let chunks = Chunker(options: .init(targetTokens: 4000)).chunk(doc)
        #expect(chunks.count == 1)
        #expect(chunks[0].pages == [0, 1])
    }

    @Test("Output is one JSON object per line")
    func writesJSONLines() throws {
        let chunks = Chunker().chunk(document([paragraph(10)]))
        let data = try Chunker().jsonLines(chunks)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == chunks.count)
        for line in lines {
            _ = try JSONDecoder().decode(DocumentChunk.self, from: Data(line.utf8))
        }
    }

    @Test("Empty documents produce no chunks")
    func handlesEmpty() {
        #expect(Chunker().chunk(document([])).isEmpty)
    }
}
