import CoreGraphics
import Foundation
import PDFKit

/// Decides, per page, whether the embedded text layer can be trusted.
public struct PageClassifier: Sendable {

    public struct Thresholds: Sendable {
        /// Characters per 1000 pt² below which a page is treated as having no
        /// meaningful text layer. A dense A4 page of prose sits around 6.
        ///
        /// Deliberately near zero rather than merely low. A cover page or a
        /// section divider has a sparse but perfectly good text layer, and
        /// sending it to OCR instead reads the artwork — a title page's logos and
        /// stylised lettering come back as headings and pollute the outline of
        /// the whole document. Genuinely scanned pages have no text layer at all,
        /// or a garbled one, and both are caught separately.
        public var minimumCharacterDensity: Double = 0.08
        /// Share of characters that may look like broken encoding before the
        /// text layer is rejected outright.
        public var maximumGarbledRatio: Double = 0.04
        public init() {}
    }

    public var thresholds: Thresholds
    public var displayBox: PDFDisplayBox

    public init(thresholds: Thresholds = .init(), displayBox: PDFDisplayBox = .cropBox) {
        self.thresholds = thresholds
        self.displayBox = displayBox
    }

    public func classify(_ page: PDFPage) -> PageClassification {
        let bounds = page.bounds(for: displayBox)
        let pageArea = Double(bounds.width * bounds.height)
        let text = page.string ?? ""
        let characterCount = text.count

        let density = pageArea > 0 ? Double(characterCount) / (pageArea / 1000) : 0
        let garbled = Self.garbledRatio(text)
        let fonts = Self.hasEmbeddedFonts(page)

        let lines = TextLayerGeometry.lines(of: page, displayBox: displayBox)
        let textArea = lines.reduce(0.0) { $0 + $1.bbox.area }
        let coverage = pageArea > 0 ? min(1, textArea / pageArea) : 0
        let multiColumn = ReadingOrder.findGutter(lines.map(\.bbox),
                                                  pageWidth: Double(bounds.width)) != nil

        var reasons: [String] = []
        var route = PageClassification.Route.textLayer

        if density < thresholds.minimumCharacterDensity {
            route = .needsOCR
            reasons.append(String(format: "sparse text layer (%.2f chars/1000pt²)", density))
        }
        if garbled > thresholds.maximumGarbledRatio {
            route = .needsOCR
            reasons.append(String(format: "%.0f%% of characters look like broken encoding", garbled * 100))
        }
        if characterCount > 0 && !fonts {
            route = .needsOCR
            reasons.append("text layer declares no embedded fonts")
        }
        if lines.isEmpty && characterCount > 0 {
            route = .needsOCR
            reasons.append("text layer reports no character geometry")
        }
        // Multi-column layout is recorded but is deliberately *not* disqualifying:
        // Offprint rebuilds order from per-character geometry rather than trusting
        // PDFKit's string order, so columns are handled on this path too.
        if multiColumn { reasons.append("multi-column layout") }
        if route == .textLayer && reasons.isEmpty { reasons.append("clean text layer") }

        return PageClassification(
            route: route,
            reasons: reasons,
            characterDensity: density,
            hasEmbeddedFonts: fonts,
            textCoverage: coverage,
            isMultiColumn: multiColumn,
            garbledRatio: garbled
        )
    }

    // MARK: - Signals

    /// Characters that indicate a broken `ToUnicode` mapping: the glyphs draw
    /// fine, but the extracted codepoints are meaningless.
    static func garbledRatio(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        var bad = 0
        var total = 0
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace { continue }
            total += 1
            let v = scalar.value
            let isPrivateUse = (0xE000...0xF8FF).contains(v)
                || (0xF0000...0xFFFFD).contains(v)
                || (0x100000...0x10FFFD).contains(v)
            let isReplacement = v == 0xFFFD
            let isControl = scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .unassigned
            if isPrivateUse || isReplacement || isControl { bad += 1 }
        }
        guard total > 0 else { return 0 }
        return Double(bad) / Double(total)
    }

    static func hasEmbeddedFonts(_ page: PDFPage) -> Bool {
        guard let attributed = page.attributedString, attributed.length > 0 else { return false }
        var found = false
        // Sampling the first few runs is enough; a page either carries font
        // information or it does not.
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: min(attributed.length, 2000))) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }
}
