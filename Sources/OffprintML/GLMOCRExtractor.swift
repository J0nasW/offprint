import CoreGraphics
import CoreImage
import Foundation
import MLXLMCommon
import OffprintCore

/// Reads a page with GLM-OCR.
///
/// The model emits Markdown rather than structure, so its output is parsed back
/// into the block tree. That keeps a model-read page and a text-layer page
/// identical everywhere downstream — same JSON schema, same preview, same table
/// warnings — instead of leaving one of them as an opaque string.
public nonisolated struct GLMOCRExtractor: PageOCREngine, Sendable {

    /// GLM-OCR's prompt protocol is a fixed set of task strings, not free text.
    public enum Task: String, Sendable {
        case text = "Text Recognition:"
        case table = "Table Recognition:"
        case formula = "Formula Recognition:"
    }

    public var model: OCRModel
    public var task: Task
    /// Ceiling on generated tokens per page.
    ///
    /// Document OCR models are known to fall into repetition loops on dense
    /// pages, and an unbounded generation turns that into a hang. A dense A4
    /// page is roughly 1,500–3,000 tokens, so this leaves headroom while still
    /// ending a runaway.
    public var maximumTokens: Int
    /// Penalty applied to recently generated tokens, or nil for none.
    public var repetitionPenalty: Float?

    public init(model: OCRModel = .glmOCR4bit, task: Task = .text,
                maximumTokens: Int = 6000, repetitionPenalty: Float? = nil) {
        self.model = model
        self.task = task
        self.maximumTokens = maximumTokens
        self.repetitionPenalty = repetitionPenalty
    }

    public var engineID: EngineID { .glmOCR }
    public var preferredDPI: Double { PDFRenderer.defaultDPI }

    /// Always. Measured on a dense two-column journal page, one pass over the
    /// whole page recovered 20% of the text and stopped; the same page as
    /// eleven paragraph regions came back complete. The model's own card
    /// describes it as layout analysis plus "parallel recognition" — regions
    /// are what it was trained on.
    public var prefersRegions: Bool { true }

    /// Regions taller than this get split. A ~90pt paragraph transcribes
    /// perfectly; a 712pt column loses a third of its words and sometimes all
    /// but the last line.
    public var maximumRegionHeight: Double { 260 }

    public func read(region image: CGImage, kind: RegionKind) async throws -> [Block] {
        let task: Task
        switch kind {
        case .table: task = .table
        case .formula: task = .formula
        case .text, .figure: task = .text
        }
        var extractor = self
        extractor.task = task
        let markdown = try await extractor.transcribe(image: image)
        return MarkdownParser().parse(Self.clean(markdown))
    }

    /// The model's raw output for an image, before any parsing.
    public func transcribe(image: CGImage) async throws -> String {
        let container = try await ModelStore.shared.container(for: model)

        var parameters = GenerateParameters()
        parameters.temperature = 0
        parameters.maxTokens = maximumTokens
        if let penalty = repetitionPenalty {
            parameters.repetitionPenalty = penalty
            parameters.repetitionContextSize = 64
        }

        let session = ChatSession(
            container,
            generateParameters: parameters,
            processing: .init(resize: nil)
        )
        return try await session.respond(to: task.rawValue,
                                         image: .ciImage(CIImage(cgImage: image)))
    }

    public func extract(image: CGImage, pageSize: CGSize, pageIndex: Int) async throws -> PageContent {
        let start = Date()
        let container = try await ModelStore.shared.container(for: model)

        var parameters = GenerateParameters()
        // OCR is a transcription task, not a creative one.
        parameters.temperature = 0
        parameters.maxTokens = maximumTokens
        // No repetition penalty by default. It is the wrong tool for
        // transcription: a page legitimately repeats common tokens, and
        // penalising them corrupts words outright — "AI n-gram" came back as
        // "AI-nogram" — and pushes the model toward an early end-of-sequence,
        // which silently truncates the page.
        if let penalty = repetitionPenalty {
            parameters.repetitionPenalty = penalty
            parameters.repetitionContextSize = 64
        }

        // A fresh session per page: pages are independent, and carrying chat
        // history between them would both waste context and let one page's
        // output bias the next.
        let session = ChatSession(
            container,
            generateParameters: parameters,
            // `resize: nil` leaves the model's own pixel budget in charge.
            // GLM-OCR sizes its input dynamically, and forcing a square resize
            // throws away the resolution small text needs.
            processing: .init(resize: nil)
        )

        let markdown = try await session.respond(
            to: task.rawValue,
            image: .ciImage(CIImage(cgImage: image))
        )

        let blocks = MarkdownParser().parse(Self.clean(markdown))

        return PageContent(
            index: pageIndex,
            width: Double(pageSize.width),
            height: Double(pageSize.height),
            blocks: blocks,
            engine: .glmOCR,
            duration: Date().timeIntervalSince(start)
        )
    }

    /// Strips wrappers models sometimes put around their output.
    public static func clean(_ output: String) -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some checkpoints wrap the whole page in a ```markdown fence.
        for fence in ["```markdown", "```md", "```html", "```"] where text.hasPrefix(fence) {
            text = String(text.dropFirst(fence.count))
            if text.hasSuffix("```") { text = String(text.dropLast(3)) }
            break
        }
        return Self.tightenMath(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Removes the padding GLM-OCR puts inside maths delimiters.
    ///
    /// The model writes `$ x_{1} $`. CommonMark maths — GitHub's included —
    /// requires the delimiters to hug their content, so the padded form renders
    /// as literal dollar signs.
    static func tightenMath(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "$") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "$") else { break }
            let inner = rest[afterOpen..<close].trimmingCharacters(in: .whitespaces)
            out += rest[rest.startIndex..<open]
            out += inner.isEmpty ? "$$" : "$" + inner + "$"
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}
