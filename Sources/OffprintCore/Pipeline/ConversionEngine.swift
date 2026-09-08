import CoreGraphics
import CryptoKit
import Foundation
import PDFKit

public enum ConversionError: Error, Sendable, LocalizedError {
    case cannotOpenPDF(URL)
    case pageUnavailable(Int)
    case engineUnavailable(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cannotOpenPDF(let url):
            return "Could not open \(url.lastPathComponent). It may not be a PDF, or it may be password-protected."
        case .pageUnavailable(let index):
            return "Page \(index + 1) could not be read."
        case .engineUnavailable(let name):
            return "The \(name) engine is not available."
        case .cancelled:
            return "Conversion was cancelled."
        }
    }
}

public enum ConversionEvent: Sendable {
    case started(pageCount: Int)
    case page(PageContent)
    case finished(OffprintDocument)
    case failed(ConversionError)
}

/// Converts a PDF to a block tree, one page at a time.
///
/// Pages are routed individually: a page with a trustworthy text layer never
/// reaches the OCR engine, which is most of why the Fast tier is fast and why
/// the model tiers do not waste seconds re-reading text that is already present.
public actor ConversionEngine {

    public struct Options: Sendable {
        public var tier: QualityTier
        public var extractFigures: Bool
        public var displayBox: PDFDisplayBox
        public var appVersion: String
        /// Forces every page through the OCR engine, ignoring the text layer.
        public var forceOCR: Bool
        /// Zero-based page range to convert. `nil` converts the whole document.
        public var pageRange: Range<Int>?

        public init(tier: QualityTier = .fast,
                    extractFigures: Bool = true,
                    displayBox: PDFDisplayBox = .cropBox,
                    appVersion: String = "0.1.0",
                    forceOCR: Bool = false,
                    pageRange: Range<Int>? = nil) {
            self.pageRange = pageRange
            self.tier = tier
            self.extractFigures = extractFigures
            self.displayBox = displayBox
            self.appVersion = appVersion
            self.forceOCR = forceOCR
        }
    }

    private let ocrEngine: any PageOCREngine
    private let classifier: PageClassifier
    private let figureDetector: FigureDetector

    public init(ocrEngine: any PageOCREngine = VisionExtractor(),
                classifier: PageClassifier = .init(),
                figureDetector: FigureDetector = .init()) {
        self.ocrEngine = ocrEngine
        self.classifier = classifier
        self.figureDetector = figureDetector
    }

    /// Streams pages as they complete so the UI can show output while the rest of
    /// the document is still being read.
    public func convert(url: URL, options: Options) -> AsyncStream<ConversionEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let document = try await self.run(url: url, options: options) { event in
                        continuation.yield(event)
                    }
                    continuation.yield(.finished(document))
                } catch let error as ConversionError {
                    continuation.yield(.failed(error))
                } catch is CancellationError {
                    continuation.yield(.failed(.cancelled))
                } catch {
                    continuation.yield(.failed(.engineUnavailable(String(describing: error))))
                }
                continuation.finish()
            }
            // Without this, breaking out of the consuming `for await` leaves the
            // conversion running in the background burning CPU and memory.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Converts without streaming. Used by the harness and by tests.
    public func document(for url: URL, options: Options) async throws -> OffprintDocument {
        try await run(url: url, options: options) { _ in }
    }

    private func run(url: URL,
                     options: Options,
                     emit: (ConversionEvent) -> Void) async throws -> OffprintDocument {
        guard let pdf = PDFDocument(url: url) else { throw ConversionError.cannotOpenPDF(url) }
        let range = (options.pageRange ?? 0..<pdf.pageCount)
            .clamped(to: 0..<pdf.pageCount)
        let pageCount = range.count
        emit(.started(pageCount: pageCount))

        let renderer = PDFRenderer(dpi: ocrEngine.preferredDPI, displayBox: options.displayBox)
        let textExtractor = TextLayerExtractor(displayBox: options.displayBox)
        var pages: [PageContent] = []

        for index in range {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index) else { throw ConversionError.pageUnavailable(index) }

            let classification = classifier.classify(page)
            let useTextLayer = !options.forceOCR
                && classification.route == .textLayer
                && options.tier != .best   // Best re-reads everything with the model.

            var content: PageContent
            if useTextLayer {
                let result = textExtractor.extract(page: page, pageIndex: index)
                content = result.content
                // A text layer that yields nothing is worse than no text layer;
                // fall through to OCR rather than emitting an empty page.
                if content.blocks.isEmpty {
                    content = try await ocr(page: page, index: index, renderer: renderer)
                } else if !result.tableCandidates.isEmpty {
                    content = try await addTables(to: content, candidates: result.tableCandidates,
                                                  page: page, index: index, renderer: renderer,
                                                  displayBox: options.displayBox)
                }
            } else {
                content = try await ocr(page: page, index: index, renderer: renderer)
            }

            if options.extractFigures {
                content.blocks = try figures(for: page, content: content, options: options)
            }
            content.blocks = BlockNormalizer.normalize(content.blocks)

            pages.append(content)
            emit(.page(content))
        }

        // Heading depth is a whole-document property; see `normalizeLevels`.
        pages = HeadingHeuristic.normalizeLevels(pages)

        var document = OffprintDocument(
            source: .init(filename: url.lastPathComponent, pages: pages.count,
                          sha256: try? Self.sha256(of: url)),
            engine: .init(tier: options.tier,
                          model: options.tier == .fast ? nil : ocrEngine.engineID.rawValue,
                          appVersion: options.appVersion),
            pages: pages
        )
        document.statistics = DocumentStatistics(document)
        return document
    }

    /// Replaces tabular prose with real tables read by Vision.
    ///
    /// The text layer knows exactly where every glyph sits but has no concept of
    /// a cell, and reconstructing one from whitespace alone gets dense numeric
    /// tables wrong. Vision has a trained table model, so the cheap geometric
    /// detector is used only to decide *which pages are worth showing it* —
    /// tables are rare, and this is the only thing that costs a render.
    private func addTables(to content: PageContent, candidates: [TableDetector.Candidate],
                           page: PDFPage, index: Int, renderer: PDFRenderer,
                           displayBox: PDFDisplayBox) async throws -> PageContent {
        // Rendered at the engine's normal density. Denser is measurably worse:
        // at 220 dpi Vision found no tables at all on documents where 150 dpi
        // found six, so the table model clearly expects roughly this scale.
        let image = try renderer.render(page)
        let size = CGSize(width: content.width, height: content.height)
        let vision = try await VisionExtractor().extract(image: image, pageSize: size,
                                                         pageIndex: index)

        let visionTables = vision.blocks.filter { block in
            if case .table = block, block.bbox != nil { return true }
            return false
        }

        // One table per suspected region: Vision's if it found one there, the
        // geometric grid otherwise.
        let bounds = page.bounds(for: displayBox)
        var tables: [Block] = []
        for candidate in candidates {
            let match = visionTables.first { table in
                guard let box = table.bbox else { return false }
                return candidate.bbox.coverage(by: box) > 0.3 || box.coverage(by: candidate.bbox) > 0.3
            }
            if let match {
                tables.append(match)
            } else {
                let rows = candidate.cells.map { row in
                    row.map { cell in
                        Block.Table.Cell(
                            text: TextLayerGeometry.text(in: cell, of: page, bounds: bounds))
                    }
                }
                guard rows.contains(where: { $0.contains { !$0.text.isEmpty } }) else { continue }
                // Flagged: this grid came from whitespace alone, with no table
                // model confirming it.
                tables.append(.table(.init(rows: rows, bbox: candidate.bbox,
                                           structureSuspect: true)))
            }
        }
        guard !tables.isEmpty else { return content }

        let claimed = tables.compactMap(\.bbox)
        var blocks = content.blocks.filter { block in
            guard let box = block.bbox else { return true }
            return !claimed.contains { box.coverage(by: $0) > 0.5 }
        }
        blocks += tables

        var content = content
        content.blocks = ReadingOrder.sort(blocks, pageWidth: content.width) { $0.bbox }
        content.engine = .vision
        return content
    }

    private func ocr(page: PDFPage, index: Int, renderer: PDFRenderer) async throws -> PageContent {
        let image = try renderer.render(page)
        return try await ocrEngine.extract(image: image,
                                           pageSize: renderer.pageSize(page),
                                           pageIndex: index)
    }

    /// Detects figures and splices them into the block list in reading order.
    private func figures(for page: PDFPage,
                         content: PageContent,
                         options: Options) throws -> [Block] {
        let pageSize = CGSize(width: content.width, height: content.height)
        // Figures are detected on a low-resolution render; only the final crop
        // needs to be sharp.
        let probe = PDFRenderer(dpi: 72, displayBox: options.displayBox)
        guard let image = try? probe.render(page) else { return content.blocks }

        let occupied = content.blocks.compactMap(\.bbox)
        let regions = figureDetector.detect(image: image, pageSize: pageSize, occupied: occupied)
        guard !regions.isEmpty else { return content.blocks }

        var blocks = content.blocks
        for (n, region) in regions.enumerated() {
            let name = String(format: "p%03d-fig%02d.png", content.index + 1, n + 1)
            blocks.append(.figure(.init(
                path: "images/\(name)",
                caption: Self.caption(near: region.bbox, in: content.blocks),
                bbox: region.bbox
            )))
        }
        return ReadingOrder.sort(blocks, pageWidth: content.width) { $0.bbox }
    }

    /// A short line of text directly beneath a figure is almost always its caption.
    static func caption(near box: BoundingBox, in blocks: [Block]) -> String? {
        var best: (text: String, distance: Double)?
        for block in blocks {
            guard case .paragraph(let paragraph) = block, let candidate = paragraph.bbox else { continue }
            let gap = candidate.minY - box.maxY
            guard gap >= -2, gap < 24 else { continue }
            // Must sit under the figure, not beside it.
            guard candidate.midX > box.minX, candidate.midX < box.maxX else { continue }
            let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count <= 300 else { continue }
            if best == nil || gap < best!.distance { best = (text, gap) }
        }
        return best?.text
    }

    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
