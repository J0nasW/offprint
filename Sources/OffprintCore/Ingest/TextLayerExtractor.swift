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

        let candidates = TableDetector.detect(lines: lines, glyphBoxes: layout.glyphBoxes,
                                              configuration: tableConfiguration)

        // Everything becomes prose here, including the tabular runs. If Vision
        // later returns a real table for a region it replaces these blocks; if it
        // does not, the text survives as paragraphs rather than vanishing.
        let paragraphs = TextLayerGeometry.paragraphs(from: lines)
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

        var blocks: [Block] = []
        for (index, paragraph) in paragraphs.enumerated() {
            let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch classified[index] {
            case .heading(let level):
                blocks.append(.heading(.init(level: level, text: text, bbox: paragraph.bbox,
                                             fontSize: paragraph.lines.map(\.fontSize).max())))
            case .paragraph:
                blocks.append(.paragraph(.init(text: text, bbox: paragraph.bbox)))
            }
        }

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
