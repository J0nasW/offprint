import CoreGraphics
import Foundation
import PDFKit

/// Extracts a page directly from its embedded text layer.
///
/// Order is rebuilt from per-character geometry rather than taken from
/// `PDFPage.string`, whose ordering is unreliable on some documents. That costs a
/// pass over the characters and buys correct multi-column output.
public struct TextLayerExtractor: Sendable {

    public var displayBox: PDFDisplayBox
    public init(displayBox: PDFDisplayBox = .cropBox) {
        self.displayBox = displayBox
    }

    public func extract(page: PDFPage, pageIndex: Int) -> PageContent {
        let start = Date()
        let bounds = page.bounds(for: displayBox)

        // `lines(of:)` already returns reading order — it resolves columns from
        // glyph geometry, which a later position-based sort would undo by
        // interleaving the columns back together.
        let lines = TextLayerGeometry.lines(of: page, displayBox: displayBox)
        let paragraphs = TextLayerGeometry.paragraphs(from: lines)

        let candidates = paragraphs.map { paragraph in
            HeadingHeuristic.Candidate(
                text: paragraph.text,
                bbox: paragraph.bbox,
                lineCount: paragraph.lines.count,
                fontSize: paragraph.lines.map(\.fontSize).max(),
                isBold: paragraph.lines.allSatisfy(\.isBold)
            )
        }
        let classified = HeadingHeuristic.classify(candidates)

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

        return PageContent(
            index: pageIndex,
            width: Double(bounds.width),
            height: Double(bounds.height),
            blocks: blocks,
            engine: .textLayer,
            duration: Date().timeIntervalSince(start)
        )
    }
}
