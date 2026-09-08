import Foundation

/// The routing decision for a single page.
///
/// Routing is per page, not per document: hybrid PDFs — a born-digital report
/// with scanned appendices, or a scanned cover sheet on a digital body — are
/// common, and treating the document as one thing gets one half of it wrong.
public struct PageClassification: Sendable, Hashable {
    public enum Route: String, Sendable, Codable {
        /// Clean, well-ordered text layer; extract it directly and skip OCR.
        case textLayer
        /// No usable text layer, or one whose order cannot be trusted.
        case needsOCR
    }

    public var route: Route
    /// Human-readable reasons, surfaced in the harness report and in diagnostics.
    public var reasons: [String]

    /// Characters in the embedded text layer per 1000 pt² of page area.
    public var characterDensity: Double
    /// Whether the text layer declares embedded fonts. Scans OCRed by weak tools
    /// often carry text with no font information at all.
    public var hasEmbeddedFonts: Bool
    /// Fraction of the page covered by text-layer character boxes.
    public var textCoverage: Double
    /// Whether the text appears to be laid out in more than one column.
    public var isMultiColumn: Bool
    /// Share of characters that look like broken encoding output.
    public var garbledRatio: Double

    public init(route: Route, reasons: [String], characterDensity: Double,
                hasEmbeddedFonts: Bool, textCoverage: Double,
                isMultiColumn: Bool, garbledRatio: Double) {
        self.route = route
        self.reasons = reasons
        self.characterDensity = characterDensity
        self.hasEmbeddedFonts = hasEmbeddedFonts
        self.textCoverage = textCoverage
        self.isMultiColumn = isMultiColumn
        self.garbledRatio = garbledRatio
    }
}
