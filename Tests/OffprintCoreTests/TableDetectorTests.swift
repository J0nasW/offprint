import Foundation
import Testing
@testable import OffprintCore

@Suite("Table detection")
struct TableDetectorTests {

    /// Builds a line whose glyphs sit at the given x-ranges.
    func line(y: Double, spans: [(Double, Double)], fontSize: Double = 10)
        -> (TextLayerGeometry.Line, [BoundingBox]) {
        let boxes = spans.map {
            BoundingBox(x: $0.0, y: y, width: $0.1 - $0.0, height: fontSize)
        }
        let bbox = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
        return (TextLayerGeometry.Line(text: "row", bbox: bbox, column: 0, fontSize: fontSize), boxes)
    }

    func detect(_ rows: [(TextLayerGeometry.Line, [BoundingBox])]) -> [TableDetector.Candidate] {
        TableDetector.detect(lines: rows.map(\.0), glyphBoxes: rows.map(\.1))
    }

    @Test("A grid with clear column corridors is a table")
    func findsGrid() throws {
        // Three columns at 0–50, 70–120, 140–190; corridors of 20pt.
        let rows = (0..<4).map { i in
            line(y: Double(i) * 14, spans: [(0, 50), (70, 120), (140, 190)])
        }
        let found = detect(rows)
        #expect(found.count == 1)
        let table = try #require(found.first)
        #expect(table.cells.count == 4)
        #expect(table.cells[0].count == 3)
        #expect(table.lineIndices == 0..<4)
    }

    @Test("Justified prose is not a table")
    func rejectsProse() {
        // Wide gaps on every line, but at different x each time — which is
        // exactly what justified text does and what a table never does.
        let rows = [
            line(y: 0,  spans: [(0, 60), (80, 190)]),
            line(y: 14, spans: [(0, 110), (130, 190)]),
            line(y: 28, spans: [(0, 40), (60, 190)]),
            line(y: 42, spans: [(0, 150), (170, 190)]),
        ]
        #expect(detect(rows).isEmpty)
    }

    @Test("Two rows and two columns is too weak a signal")
    func rejectsTinyGrid() {
        // A heading above a short indented line makes this shape by accident.
        let rows = [
            line(y: 0,  spans: [(0, 50), (70, 120)]),
            line(y: 14, spans: [(0, 50), (70, 120)]),
        ]
        #expect(detect(rows).isEmpty)

        // Three rows of the same shape is enough.
        let taller = rows + [line(y: 28, spans: [(0, 50), (70, 120)])]
        #expect(detect(taller).count == 1)
    }

    @Test("A gap narrower than a word space is not a column boundary")
    func rejectsNarrowGaps() {
        // 2pt gaps at 10pt type: ordinary letter spacing, not a column.
        let rows = (0..<4).map { i in
            line(y: Double(i) * 14, spans: [(0, 50), (52, 100), (102, 150)])
        }
        #expect(detect(rows).isEmpty)
    }

    @Test("Rows separated by a large vertical gap are different blocks")
    func splitsOnVerticalGap() {
        var rows = (0..<3).map { i in line(y: Double(i) * 14, spans: [(0, 50), (70, 120), (140, 190)]) }
        // A gap far larger than the type size ends the table.
        rows += (0..<3).map { i in line(y: 200 + Double(i) * 14, spans: [(0, 190)]) }
        let found = detect(rows)
        #expect(found.count == 1)
        #expect(found.first?.lineIndices.upperBound == 3)
    }

    @Test("A caption above the grid is excluded from the table")
    func excludesSurroundingProse() throws {
        // A full-width caption covers the corridors, so including it would hide
        // the table entirely. The scan has to find the run that works.
        var rows = [line(y: 0, spans: [(0, 190)])]
        rows += (0..<4).map { i in
            line(y: 14 + Double(i) * 14, spans: [(0, 50), (70, 120), (140, 190)])
        }
        let found = detect(rows)
        let table = try #require(found.first)
        #expect(table.lineIndices.lowerBound == 1)
        #expect(table.cells.count == 4)
    }

    @Test("Corridors are the empty x-intervals between glyph runs")
    func findsCorridors() {
        let boxes = [
            BoundingBox(x: 0, y: 0, width: 50, height: 10),
            BoundingBox(x: 70, y: 0, width: 50, height: 10),
        ]
        let corridors = TableDetector.corridors(in: boxes, from: 0, to: 120, minimumWidth: 5)
        #expect(corridors.count == 1)
        #expect(corridors[0].low == 50)
        #expect(corridors[0].high == 70)
    }
}
