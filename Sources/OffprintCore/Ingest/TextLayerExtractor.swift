import CoreGraphics
import Foundation
import PDFKit

/// Extracts a page directly from its embedded text layer.
///
/// Order is rebuilt from per-character geometry rather than taken from
/// `PDFPage.string`, whose ordering is unreliable on some documents. That costs a
/// pass over the glyphs and buys correct multi-column output.
public struct TextLayerExtractor: Sendable {

    public struct Result: Sendable {
        public var content: PageContent
        /// Regions that look tabular, with their geometric cell grid.
        ///
        /// Vision has a trained table model and beats this reconstruction when it
        /// fires, so the caller prefers Vision's answer. But a genuinely tabular
        /// region that Vision declines to call a table must not fall back to one
        /// giant paragraph, so the geometric grid is carried along as a floor.
        public var tableCandidates: [TableDetector.Candidate]
    }

    public var displayBox: PDFDisplayBox
    public var tableConfiguration: TableDetector.Configuration

    public init(displayBox: PDFDisplayBox = .cropBox,
                tableConfiguration: TableDetector.Configuration = .init()) {
        self.displayBox = displayBox
        self.tableConfiguration = tableConfiguration
    }

    public func extract(page: PDFPage, pageIndex: Int) -> Result {
        let start = Date()
        let bounds = page.bounds(for: displayBox)

        // `layout(of:)` already returns reading order — it resolves columns from
        // glyph geometry, which a later position-based sort would undo by
        // interleaving the columns back together.
        let layout = TextLayerGeometry.layout(of: page, displayBox: displayBox)
        let lines = layout.lines

        // Contents first. A contents page is two columns of text and a table
        // detector will claim it, so it has to be taken out of the running
        // before tables are looked for at all.
        let contents = ContentsDetector.detect(in: lines)
        var consumed = Set<Int>()
        for section in contents { consumed.formUnion(section.lineIndices) }

        let candidates = TableDetector.detect(lines: lines, glyphBoxes: layout.glyphBoxes,
                                              configuration: tableConfiguration)
            .filter { candidate in
                // Never offer a contents section to the table pass.
                !candidate.lineIndices.contains { consumed.contains($0) }
            }

        // Everything else becomes prose, including the tabular runs. If Vision
        // later returns a real table for a region it replaces these blocks; if it
        // does not, the text survives as paragraphs rather than vanishing.
        let remainingIndices = lines.indices.filter { !consumed.contains($0) }
        let paragraphs = TextLayerGeometry.paragraphs(from: remainingIndices.map { lines[$0] })
        let headingCandidates = paragraphs.map { paragraph in
            HeadingHeuristic.Candidate(
                text: paragraph.text,
                bbox: paragraph.bbox,
                lineCount: paragraph.lines.count,
                fontSize: paragraph.lines.map(\.fontSize).max(),
                isBold: paragraph.lines.allSatisfy(\.isBold)
            )
        }
        let classified = HeadingHeuristic.classify(headingCandidates)

        var keyed: [(line: Int, block: Block)] = contents.map {
            ($0.lineIndices.lowerBound, .list($0.list))
        }

        // Paragraphs partition the surviving lines in order, so walking a cursor
        // recovers each one's original line index and keeps everything in
        // reading order without a position sort.
        var cursor = 0
        for (index, paragraph) in paragraphs.enumerated() {
            let key = remainingIndices.indices.contains(cursor)
                ? remainingIndices[cursor] : lines.count
            cursor += paragraph.lines.count

            let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch classified[index] {
            case .heading(let level):
                keyed.append((key, .heading(.init(level: level, text: text, bbox: paragraph.bbox,
                                                  fontSize: paragraph.lines.map(\.fontSize).max()))))
            case .paragraph:
                keyed.append((key, .paragraph(.init(text: text, bbox: paragraph.bbox))))
            }
        }

        let blocks = keyed
            .enumerated()
            .sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }
            .map(\.element.block)

        let content = PageContent(
            index: pageIndex,
            width: Double(bounds.width),
            height: Double(bounds.height),
            blocks: blocks,
            engine: .textLayer,
            duration: Date().timeIntervalSince(start)
        )
        return Result(content: content, tableCandidates: candidates)
    }
}
