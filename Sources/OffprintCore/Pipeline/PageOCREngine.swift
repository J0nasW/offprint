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

    /// Whether the engine should be handed regions rather than whole pages.
    ///
    /// Document OCR models of this class are trained on regions: given a whole
    /// two-column page GLM-OCR recovers about a fifth of the text and stops,
    /// while the same page as paragraph crops comes back complete.
    var prefersRegions: Bool { get }

    /// Reads one region of a page.
    func read(region: CGImage, kind: RegionKind) async throws -> [Block]

    /// Largest region height, in points, the engine reads reliably in one pass.
    var maximumRegionHeight: Double { get }
}

extension PageOCREngine {
    public var prefersRegions: Bool { false }
    public var maximumRegionHeight: Double { 260 }
    public func read(region: CGImage, kind: RegionKind) async throws -> [Block] { [] }
}

extension VisionExtractor: PageOCREngine {
    public var engineID: EngineID { .vision }
    public var preferredDPI: Double { PDFRenderer.defaultDPI }
}
