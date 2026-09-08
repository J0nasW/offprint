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

    public init(model: OCRModel = .glmOCR4bit, task: Task = .text, maximumTokens: Int = 6000) {
        self.model = model
        self.task = task
        self.maximumTokens = maximumTokens
    }

    public var engineID: EngineID { .glmOCR }
    public var preferredDPI: Double { PDFRenderer.defaultDPI }

    public func extract(image: CGImage, pageSize: CGSize, pageIndex: Int) async throws -> PageContent {
        let start = Date()
        let container = try await ModelStore.shared.container(for: model)

        var parameters = GenerateParameters()
        // OCR is a transcription task, not a creative one.
        parameters.temperature = 0
        parameters.maxTokens = maximumTokens
        // A light touch against the repetition loops these models fall into;
        // heavier penalties start damaging legitimately repetitive tables.
        parameters.repetitionPenalty = 1.02
        parameters.repetitionContextSize = 64

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
    static func clean(_ output: String) -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some checkpoints wrap the whole page in a ```markdown fence.
        for fence in ["```markdown", "```md", "```html", "```"] where text.hasPrefix(fence) {
            text = String(text.dropFirst(fence.count))
            if text.hasSuffix("```") { text = String(text.dropLast(3)) }
            break
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
