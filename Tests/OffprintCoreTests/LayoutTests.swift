import Foundation
import Testing
@testable import OffprintCore

@Suite("Geometry")
struct GeometryTests {

    @Test("Coverage reports how much of a box another one hides")
    func coverage() {
        let outer = BoundingBox(x: 0, y: 0, width: 100, height: 100)
        let half = BoundingBox(x: 0, y: 0, width: 100, height: 50)
        #expect(half.coverage(by: outer) == 1.0)
        #expect(outer.coverage(by: half) == 0.5)
        let apart = BoundingBox(x: 500, y: 500, width: 10, height: 10)
        #expect(outer.coverage(by: apart) == 0)
    }

    @Test("Union of an empty box is the other box")
    func unionWithEmpty() {
        let empty = BoundingBox(x: 0, y: 0, width: 0, height: 0)
        let box = BoundingBox(x: 5, y: 5, width: 10, height: 10)
        #expect(empty.union(box) == box)
        #expect(box.union(empty) == box)
    }

    @Test("Boxes encode as a compact [x, y, w, h] array and round-trip")
    func codableRoundTrip() throws {
        let box = BoundingBox(x: 1.234, y: 2, width: 3, height: 4)
        let data = try JSONEncoder().encode(box)
        #expect(String(decoding: data, as: UTF8.self) == "[1.23,2,3,4]")
        let back = try JSONDecoder().decode(BoundingBox.self, from: data)
        #expect(back.y == 2 && back.width == 3)
    }
}

@Suite("Reading order")
struct ReadingOrderTests {

    /// Builds boxes for `count` stacked lines in a column.
    func column(x: Double, count: Int, startY: Double = 0) -> [BoundingBox] {
        (0..<count).map { BoundingBox(x: x, y: startY + Double($0) * 14, width: 200, height: 10) }
    }

    @Test("A single-column page reports no gutter")
    func singleColumnHasNoGutter() {
        // Lines spanning the page centre: nothing can be a gutter.
        let boxes = (0..<12).map {
            BoundingBox(x: 50, y: Double($0) * 14, width: 500, height: 10)
        }
        #expect(ReadingOrder.findGutter(boxes, pageWidth: 600) == nil)
    }

    @Test("A two-column page finds the gutter between the columns")
    func twoColumnsFindGutter() throws {
        let boxes = column(x: 50, count: 10) + column(x: 320, count: 10)
        let gutter = try #require(ReadingOrder.findGutter(boxes, pageWidth: 600))
        #expect(gutter > 250 && gutter < 320)
    }

    @Test("Content is ordered down the left column before the right")
    func ordersColumns() throws {
        struct Item { var name: String; var box: BoundingBox }
        var items: [Item] = []
        for (i, box) in column(x: 50, count: 6).enumerated() {
            items.append(Item(name: "L\(i)", box: box))
        }
        for (i, box) in column(x: 320, count: 6).enumerated() {
            items.append(Item(name: "R\(i)", box: box))
        }
        // Shuffle deterministically so the result cannot come from input order.
        items.shuffle()

        let sorted = ReadingOrder.sort(items, pageWidth: 600) { $0.box }
        let names = sorted.map(\.name)
        #expect(names.prefix(6) == ["L0", "L1", "L2", "L3", "L4", "L5"])
        #expect(names.suffix(6) == ["R0", "R1", "R2", "R3", "R4", "R5"])
    }

    @Test("Items without geometry are kept rather than dropped")
    func keepsUnplacedItems() {
        struct Item { var name: String; var box: BoundingBox? }
        let items = [Item(name: "a", box: BoundingBox(x: 0, y: 0, width: 10, height: 10)),
                     Item(name: "ghost", box: nil)]
        let sorted = ReadingOrder.sort(items, pageWidth: 600) { $0.box }
        #expect(sorted.count == 2)
        #expect(sorted.map(\.name).contains("ghost"))
    }
}

@Suite("Heading detection")
struct HeadingHeuristicTests {

    func candidate(_ text: String, size: Double, lines: Int = 1, bold: Bool = false)
        -> HeadingHeuristic.Candidate {
        HeadingHeuristic.Candidate(
            text: text,
            bbox: BoundingBox(x: 0, y: 0, width: 300, height: size * Double(lines)),
            lineCount: lines, fontSize: size, isBold: bold)
    }

    @Test("Larger short text becomes a heading, body text does not")
    func detectsBySize() {
        let result = HeadingHeuristic.classify([
            candidate("The Title", size: 20),
            candidate("Body text that runs on for a while and keeps going.", size: 10, lines: 4),
        ])
        #expect(result[0] != .paragraph)
        #expect(result[1] == .paragraph)
    }

    @Test("Bold text at body size is still a heading")
    func detectsByWeight() {
        // Academic styles set section headings barely above body size; weight is
        // what actually distinguishes them.
        let result = HeadingHeuristic.classify([
            candidate("1 Introduction", size: 10, bold: true),
            candidate("Ordinary paragraph text here.", size: 10, lines: 3),
        ])
        #expect(result[0] == .heading(level: 1))
        #expect(result[1] == .paragraph)
    }

    @Test("Page numbers and rules are never headings")
    func rejectsNonTextCandidates() {
        let result = HeadingHeuristic.classify([
            candidate("2536", size: 20),          // a margin line number
            candidate("—", size: 20),             // a rule
            candidate("Real Heading", size: 20),
            candidate("Body text for scale.", size: 10, lines: 4),
        ])
        #expect(result[0] == .paragraph)
        #expect(result[1] == .paragraph)
        #expect(result[2] != .paragraph)
        #expect(result[3] == .paragraph)
    }

    @Test("A long sentence set large is prose, not a heading")
    func rejectsLargeProse() {
        let long = String(repeating: "word ", count: 40) + "."
        let result = HeadingHeuristic.classify([
            candidate(long, size: 20, lines: 2),
            candidate("Body", size: 10, lines: 3),
        ])
        #expect(result[0] == .paragraph)
    }

    @Test("Near-equal sizes collapse into one heading level")
    func clustersJitteryySizes() {
        // Vision estimates size from box heights, which vary a few percent for
        // the same heading. Without clustering each becomes its own level.
        let tiers = HeadingHeuristic.clusterSizes([20.0, 19.6, 19.9, 12.0, 11.8])
        #expect(tiers.count == 2)
        #expect(HeadingHeuristic.level(for: 19.6, in: tiers) == 1)
        #expect(HeadingHeuristic.level(for: 11.8, in: tiers) == 2)
    }

    @Test("Heading levels are ranked across the whole document")
    func normalizesLevelsAcrossPages() throws {
        // Page 1 has the title and a section; page 2 has only sections. Judged
        // per page, page 2's sections would be promoted to h1.
        let page1 = PageContent(index: 0, width: 600, height: 800, blocks: [
            .heading(.init(level: 1, text: "Title", fontSize: 20)),
            .heading(.init(level: 2, text: "1 Intro", fontSize: 12)),
        ], engine: .textLayer)
        let page2 = PageContent(index: 1, width: 600, height: 800, blocks: [
            .heading(.init(level: 1, text: "2 Methods", fontSize: 12)),
        ], engine: .textLayer)

        let out = HeadingHeuristic.normalizeLevels([page1, page2])
        guard case .heading(let methods) = out[1].blocks[0] else {
            Issue.record("expected a heading"); return
        }
        #expect(methods.level == 2)
    }
}

@Suite("JSON export")
struct JSONWriterTests {

    @Test("Documents round-trip through the public schema")
    func roundTrip() throws {
        let document = OffprintDocument(
            source: .init(filename: "a.pdf", pages: 1, sha256: "abc"),
            engine: .init(tier: .balanced, model: "glmOCR", appVersion: "0.1.0"),
            pages: [PageContent(index: 0, width: 612, height: 792, blocks: [
                .heading(.init(level: 2, text: "Results", bbox: .init(x: 1, y: 2, width: 3, height: 4))),
                .table(.init(rows: [[.init(text: "a", colSpan: 2)]], structureSuspect: true)),
                .list(.init(ordered: true, items: [.init(text: "one")])),
                .figure(.init(path: "images/f.png", caption: "c")),
                .formula(.init(latex: "e^{i\\pi}")),
                .code(.init(text: "let x = 1", language: "swift")),
                .paragraph(.init(text: "body")),
            ], engine: .vision, duration: 0.5)])

        let data = try JSONWriter().data(for: document)
        let back = try JSONWriter.decode(data)
        #expect(back == document)
        // Column spans must survive: the Markdown export loses them, so JSON is
        // the only place that carries the real table structure.
        guard case .table(let table) = back.pages[0].blocks[1] else {
            Issue.record("expected a table"); return
        }
        #expect(table.rows[0][0].colSpan == 2)
        #expect(table.structureSuspect)
    }

    @Test("Block type is written as a discriminator field")
    func writesTypeDiscriminator() throws {
        let document = OffprintDocument(
            source: .init(filename: "a.pdf", pages: 1),
            engine: .init(tier: .fast, appVersion: "0.1.0"),
            pages: [PageContent(index: 0, width: 1, height: 1,
                                blocks: [.paragraph(.init(text: "x"))], engine: .vision)])
        let json = try JSONWriter().string(for: document)
        #expect(json.contains("\"type\" : \"paragraph\""))
    }
}

@Suite("Table structure confidence")
struct TableSuspicionTests {

    @Test("A single-column table is treated as suspect")
    func flagsSingleColumn() {
        // Vision's classic failure is splitting a table down the wrong axis. The
        // result is still valid Markdown, so it must be flagged explicitly.
        let rows = [[Block.Table.Cell(text: "a")], [Block.Table.Cell(text: "b")]]
        #expect(VisionExtractor.isStructureSuspect(rows))
    }

    @Test("A rectangular table is not suspect")
    func acceptsRectangular() {
        let rows = (0..<4).map { r in
            (0..<3).map { c in Block.Table.Cell(text: "\(r)\(c)") }
        }
        #expect(!VisionExtractor.isStructureSuspect(rows))
    }

    @Test("Mostly-ragged rows are suspect, one short row is not")
    func toleratesOneRaggedRow() {
        var rows = (0..<4).map { _ in (0..<3).map { _ in Block.Table.Cell(text: "x") } }
        rows[3] = [Block.Table.Cell(text: "note", colSpan: 1)]
        #expect(!VisionExtractor.isStructureSuspect(rows))

        let ragged = [
            (0..<3).map { _ in Block.Table.Cell(text: "x") },
            [Block.Table.Cell(text: "x")],
            [Block.Table.Cell(text: "x")],
        ]
        #expect(VisionExtractor.isStructureSuspect(ragged))
    }
}

@Suite("Section numbering")
struct SectionNumberingTests {

    @Test("Numbered section titles report their depth")
    func readsDepth() {
        #expect(HeadingHeuristic.sectionDepth(of: "1 Introduction") == 1)
        #expect(HeadingHeuristic.sectionDepth(of: "3.1 Task definition") == 2)
        #expect(HeadingHeuristic.sectionDepth(of: "3.2.1 Embedding layer") == 3)
        #expect(HeadingHeuristic.sectionDepth(of: "2. Related work") == 1)
        // Appendices.
        #expect(HeadingHeuristic.sectionDepth(of: "A Training Settings") == 1)
        #expect(HeadingHeuristic.sectionDepth(of: "B.2 Ablations") == 2)
    }

    @Test("Prose that merely starts with a number is not a section")
    func rejectsProse() {
        // A bibliography year.
        #expect(HeadingHeuristic.sectionDepth(of: "2024 Smith et al. report that") == nil)
        // A bare number is a page number.
        #expect(HeadingHeuristic.sectionDepth(of: "2536") == nil)
        // Nothing after the number.
        #expect(HeadingHeuristic.sectionDepth(of: "3.1 ") == nil)
        // Too deep to be a real section.
        #expect(HeadingHeuristic.sectionDepth(of: "1.2.3.4.5 Something") == nil)
        #expect(HeadingHeuristic.sectionDepth(of: "Introduction") == nil)
    }

    @Test("A numbered subsection is a heading even at body size and weight")
    func detectsUnstyledSubsections() {
        // The case that motivates this: styles that mark a subsection with the
        // number alone, where every size- and weight-based test fails.
        let body = HeadingHeuristic.Candidate(
            text: "Ordinary paragraph text that continues for a while.",
            bbox: .init(x: 0, y: 0, width: 300, height: 40), lineCount: 4, fontSize: 10)
        let subsection = HeadingHeuristic.Candidate(
            text: "3.1 Task definition",
            bbox: .init(x: 0, y: 0, width: 100, height: 10), lineCount: 1, fontSize: 10)

        let result = HeadingHeuristic.classify([subsection, body])
        #expect(result[0] != .paragraph)
        #expect(result[1] == .paragraph)
    }

    @Test("Numbering sets the level, so the outline nests consistently")
    func numberingDrivesLevels() throws {
        let pages = [PageContent(index: 0, width: 600, height: 800, blocks: [
            .heading(.init(level: 1, text: "Paper Title", fontSize: 20)),
            .heading(.init(level: 1, text: "3 Methodology", fontSize: 12)),
            .heading(.init(level: 1, text: "3.1 Task definition", fontSize: 10)),
            .heading(.init(level: 1, text: "3.2.1 Embedding layer", fontSize: 10)),
        ], engine: .textLayer)]

        let out = HeadingHeuristic.normalizeLevels(pages)
        let levels = out[0].blocks.compactMap { block -> Int? in
            guard case .heading(let heading) = block else { return nil }
            return heading.level
        }
        // Title stays on top; numbered sections nest one level beneath it.
        #expect(levels == [1, 2, 3, 4])
    }
}
