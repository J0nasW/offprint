import CoreGraphics
import Foundation
import Vision

/// The Fast tier's OCR engine: Apple's `RecognizeDocumentsRequest`.
///
/// Runs on the Neural Engine, needs no download, and — unlike plain text
/// recognition — returns tables with merged-cell ranges, lists with marker types,
/// and paragraph grouping. That is enough structure to build real Markdown from.
public struct VisionExtractor: Sendable {

    public struct Configuration: Sendable {
        /// Fraction of a paragraph that must fall inside a table or list before
        /// we treat it as a duplicate of that structure's own text.
        public var containmentThreshold: Double
        /// Languages to recognise. Empty means let Vision detect them, which is
        /// the right default for mixed-language documents.
        public var languages: [Locale.Language]
        /// Barcodes are detected for free but Offprint emits no block for them,
        /// so the work is skipped unless something asks for it.
        public var detectBarcodes: Bool

        public init(containmentThreshold: Double = 0.6,
                    languages: [Locale.Language] = [],
                    detectBarcodes: Bool = false) {
            self.containmentThreshold = containmentThreshold
            self.languages = languages
            self.detectBarcodes = detectBarcodes
        }
    }

    public var configuration: Configuration
    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public func extract(image: CGImage, pageSize: CGSize, pageIndex: Int) async throws -> PageContent {
        let start = Date()
        var request = RecognizeDocumentsRequest()
        // There is no speed/accuracy switch on this request — document
        // recognition is always the accurate path.
        request.textRecognitionOptions.useLanguageCorrection = true
        if configuration.languages.isEmpty {
            request.textRecognitionOptions.automaticallyDetectLanguage = true
        } else {
            request.textRecognitionOptions.recognitionLanguages = configuration.languages
        }
        request.barcodeDetectionOptions.enabled = configuration.detectBarcodes

        let observations = try await request.perform(on: image)
        var blocks: [Block] = []

        if let container = observations.first?.document {
            blocks = Self.blocks(from: container, pageSize: pageSize,
                                 threshold: configuration.containmentThreshold)
        }

        blocks = ReadingOrder.sort(blocks, pageWidth: Double(pageSize.width)) { $0.bbox }

        return PageContent(
            index: pageIndex,
            width: Double(pageSize.width),
            height: Double(pageSize.height),
            blocks: blocks,
            engine: .vision,
            duration: Date().timeIntervalSince(start)
        )
    }

    // MARK: - Container → blocks

    static func blocks(from container: DocumentObservation.Container,
                       pageSize: CGSize,
                       threshold: Double) -> [Block] {
        var blocks: [Block] = []

        // Tables and lists first: they own their text, and the paragraph list
        // repeats it, so their geometry is what lets us drop the duplicates.
        var claimed: [BoundingBox] = []

        for table in container.tables {
            let box = rect(table.boundingRegion, pageSize)
            claimed.append(box)
            if let block = self.table(table, pageSize: pageSize) {
                blocks.append(.table(block))
            }
        }

        for list in container.lists {
            let box = rect(list.boundingRegion, pageSize)
            claimed.append(box)
            blocks.append(.list(self.list(list, pageSize: pageSize)))
        }

        // Paragraphs that survive de-duplication become headings or body text.
        var candidates: [(HeadingHeuristic.Candidate, BoundingBox)] = []
        let titleBox = container.title.map { rect($0.boundingRegion, pageSize) }

        for paragraph in container.paragraphs {
            let box = rect(paragraph.boundingRegion, pageSize)
            let text = paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard !claimed.contains(where: { box.coverage(by: $0) >= threshold }) else { continue }
            // The title is emitted separately; don't emit it twice.
            if let titleBox, box.coverage(by: titleBox) >= 0.9 { continue }
            candidates.append((
                HeadingHeuristic.Candidate(text: text, bbox: box, lineCount: max(1, paragraph.lines.count)),
                box
            ))
        }

        let classified = HeadingHeuristic.classify(candidates.map(\.0))
        for (index, candidate) in candidates.enumerated() {
            let (heuristicInput, box) = candidate
            switch classified[index] {
            case .heading(let level):
                // Vision's own title outranks anything the size heuristic finds,
                // so everything it promotes starts one level below it.
                let adjusted = titleBox == nil ? level : min(level + 1, 6)
                blocks.append(.heading(.init(level: adjusted, text: heuristicInput.text,
                                             bbox: box, fontSize: heuristicInput.fontSize)))
            case .paragraph:
                blocks.append(.paragraph(.init(text: heuristicInput.text, bbox: box)))
            }
        }

        if let title = container.title {
            let text = title.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let size = (titleBox?.height ?? 0) / Double(max(1, title.lines.count))
                blocks.append(.heading(.init(level: 1, text: text, bbox: titleBox,
                                             fontSize: size > 0 ? size : nil)))
            }
        }

        return blocks
    }

    static func table(_ table: DocumentObservation.Container.Table, pageSize: CGSize) -> Block.Table? {
        let rows: [[Block.Table.Cell]] = table.rows.map { row in
            row.map { cell in
                Block.Table.Cell(
                    text: cell.content.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                    rowSpan: cell.rowRange.count,
                    colSpan: cell.columnRange.count
                )
            }
        }
        guard !rows.isEmpty, rows.contains(where: { !$0.isEmpty }) else { return nil }

        return Block.Table(
            rows: rows,
            bbox: rect(table.boundingRegion, pageSize),
            structureSuspect: isStructureSuspect(rows)
        )
    }

    /// Flags tables we have reason to distrust.
    ///
    /// The dangerous failure here is silent: a table split down the wrong axis
    /// still serialises to perfectly valid Markdown, so nothing downstream — and
    /// no reader skimming the output — can tell it went wrong. Better to say so.
    static func isStructureSuspect(_ rows: [[Block.Table.Cell]]) -> Bool {
        guard !rows.isEmpty else { return true }
        let widths = rows.map { $0.reduce(0) { $0 + $1.colSpan } }
        guard let maxWidth = widths.max(), maxWidth > 0 else { return true }
        // A one-column "table" is almost always a shredded multi-column one.
        if maxWidth == 1 { return true }
        // Rows disagreeing about how many columns exist means the split is unstable.
        let ragged = widths.filter { $0 != maxWidth }.count
        return Double(ragged) / Double(widths.count) > 0.34
    }

    static func list(_ list: DocumentObservation.Container.List, pageSize: CGSize) -> Block.List {
        var ordered = false
        var items: [Block.List.Item] = []

        for item in list.items {
            if let marker = item.markerType, Self.isOrdered(marker) { ordered = true }
            let text = item.itemString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                items.append(.init(text: text, depth: 0))
            }
            // One level of nesting covers essentially every real document.
            for nested in item.content.lists {
                for sub in nested.items {
                    let subText = sub.itemString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !subText.isEmpty { items.append(.init(text: subText, depth: 1)) }
                }
            }
        }

        return Block.List(ordered: ordered, items: items, bbox: rect(list.boundingRegion, pageSize))
    }

    static func isOrdered(_ marker: DocumentObservation.Container.List.Marker) -> Bool {
        switch marker {
        case .bullet, .hyphen:
            return false
        case .lowercaseLatin, .uppercaseLatin, .decimal, .decorativeDecimal, .compositeDecimal:
            return true
        @unknown default:
            return false
        }
    }

    // MARK: - Geometry

    /// Vision reports normalised regions with a lower-left origin; the rest of
    /// Offprint works in page points with an upper-left origin.
    static func rect(_ region: NormalizedRegion, _ pageSize: CGSize) -> BoundingBox {
        let r = region.boundingBox.toImageCoordinates(pageSize, origin: .upperLeft)
        // Clipped to the paper. Vision occasionally reports a region reaching
        // past the page edge, and a box starting at x = -226 throws off reading
        // order, figure cropping and the coordinates in the JSON export.
        return BoundingBox(x: Double(r.origin.x), y: Double(r.origin.y),
                           width: Double(r.width), height: Double(r.height))
            .clamped(to: pageSize)
    }
}
