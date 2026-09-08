import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Writes a converted document to disk: Markdown, JSON, and cropped figures.
public struct DocumentExporter: Sendable {

    public struct Options: Sendable {
        public var writeMarkdown: Bool
        public var writeJSON: Bool
        /// Writes `<name>.chunks.jsonl` for retrieval pipelines.
        public var writeChunks: Bool
        public var chunking: Chunker.Options
        public var writeFigures: Bool
        public var figureDPI: Double
        public var markdown: MarkdownWriter.Options

        public init(writeMarkdown: Bool = true,
                    writeJSON: Bool = false,
                    writeChunks: Bool = false,
                    chunking: Chunker.Options = .init(),
                    writeFigures: Bool = true,
                    figureDPI: Double = PDFRenderer.figureDPI,
                    markdown: MarkdownWriter.Options = .init()) {
            self.writeMarkdown = writeMarkdown
            self.writeJSON = writeJSON
            self.writeChunks = writeChunks
            self.chunking = chunking
            self.writeFigures = writeFigures
            self.figureDPI = figureDPI
            self.markdown = markdown
        }
    }

    public struct Result: Sendable {
        public var markdownURL: URL?
        public var jsonURL: URL?
        public var chunksURL: URL?
        public var outlineURL: URL?
        public var figureURLs: [URL]
    }

    public var options: Options
    public init(options: Options = .init()) { self.options = options }

    /// - Parameters:
    ///   - document: the converted document.
    ///   - source: the original PDF, needed to re-render figure crops sharply.
    ///   - directory: destination directory; created if missing.
    ///   - basename: output filename stem, defaulting to the source's.
    @discardableResult
    public func export(_ document: OffprintDocument,
                       source: URL?,
                       to directory: URL,
                       basename: String? = nil) throws -> Result {
        let stem = basename ?? (source?.deletingPathExtension().lastPathComponent
                                ?? (document.source.filename as NSString).deletingPathExtension)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var figureURLs: [URL] = []
        if options.writeFigures, let source, document.allBlocks.contains(where: { $0.typeName == "figure" }) {
            figureURLs = try writeFigures(document, source: source, into: directory)
        }

        var markdownURL: URL?
        if options.writeMarkdown {
            let url = directory.appending(path: "\(stem).md")
            let text = MarkdownWriter(options: options.markdown).write(document)
            try Data(text.utf8).write(to: url, options: .atomic)
            markdownURL = url
        }

        var jsonURL: URL?
        if options.writeJSON {
            let url = directory.appending(path: "\(stem).json")
            try JSONWriter().data(for: document).write(to: url, options: .atomic)
            jsonURL = url
        }

        var chunksURL: URL?
        var outlineURL: URL?
        if options.writeChunks {
            let chunker = Chunker(options: options.chunking,
                                  markdown: MarkdownWriter(options: options.markdown))
            let chunks = chunker.chunk(document)

            let url = directory.appending(path: "\(stem).chunks.jsonl")
            try chunker.jsonLines(chunks).write(to: url, options: .atomic)
            chunksURL = url

            // The outline ships with the chunks so an agent can look at the
            // structure and choose what to read, instead of embedding
            // everything and hoping similarity finds it.
            let outline = chunker.outline(document, chunks: chunks)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let outlinePath = directory.appending(path: "\(stem).outline.json")
            try encoder.encode(outline).write(to: outlinePath, options: .atomic)
            outlineURL = outlinePath
        }

        return Result(markdownURL: markdownURL, jsonURL: jsonURL,
                      chunksURL: chunksURL, outlineURL: outlineURL, figureURLs: figureURLs)
    }

    private func writeFigures(_ document: OffprintDocument,
                              source: URL,
                              into directory: URL) throws -> [URL] {
        guard let pdf = PDFDocument(url: source) else { return [] }
        let imagesDirectory = directory.appending(path: "images")
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

        let renderer = PDFRenderer(dpi: options.figureDPI)
        var written: [URL] = []

        for page in document.pages {
            guard let pdfPage = pdf.page(at: page.index) else { continue }
            for block in page.blocks {
                guard case .figure(let figure) = block, let box = figure.bbox else { continue }
                let url = directory.appending(path: figure.path)
                guard let image = try? renderer.render(pdfPage, crop: box, dpi: options.figureDPI),
                      Self.writePNG(image, to: url) else { continue }
                written.append(url)
            }
        }
        return written
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
