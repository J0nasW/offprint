import CoreGraphics
import Foundation

/// An engine that reads a rendered page image.
///
/// `VisionExtractor` conforms here, and so will the GLM-OCR engine, which lives
/// in a separate module so that everything in `OffprintCore` stays buildable and
/// testable without the Metal toolchain.
public protocol PageOCREngine: Sendable {
    var engineID: EngineID { get }
    /// Resolution the engine wants its page images rendered at.
    var preferredDPI: Double { get }
    func extract(image: CGImage, pageSize: CGSize, pageIndex: Int) async throws -> PageContent
}

extension VisionExtractor: PageOCREngine {
    public var engineID: EngineID { .vision }
    public var preferredDPI: Double { PDFRenderer.defaultDPI }
}
