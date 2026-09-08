import Foundation

/// Promotes visually prominent paragraphs to headings.
///
/// Vision identifies a single `title` per page and calls everything else a
/// paragraph, so a document run through it lands as a flat wall of text with no
/// structure — which is most of what makes Markdown worth having. Vision does not
/// report font size, but line height is a serviceable proxy for it.
public enum HeadingHeuristic {

    public struct Candidate: Sendable {
        public var text: String
        public var bbox: BoundingBox
        /// Number of text lines grouped into this paragraph.
        public var lineCount: Int
        /// Measured type size, when the engine can supply one. Falls back to the
        /// box height divided by the line count, which is noisier.
        public var fontSize: Double
        /// Whether the text is set in a bold face, when the engine can tell.
        public var isBold: Bool

        public init(text: String, bbox: BoundingBox, lineCount: Int,
                    fontSize: Double? = nil, isBold: Bool = false) {
            self.text = text
            self.bbox = bbox
            self.lineCount = lineCount
            self.fontSize = fontSize ?? (bbox.height / Double(max(1, lineCount)))
            self.isBold = isBold
        }
    }

    public enum Classification: Sendable, Equatable {
        case heading(level: Int)
        case paragraph
    }

    /// Classifies each candidate against the page's own typography.
    ///
    /// Sizes are compared to the median body line height on the same page rather
    /// than to absolute values, so this works the same on a slide deck and on a
    /// dense journal page.
    public static func classify(_ candidates: [Candidate]) -> [Classification] {
        guard !candidates.isEmpty else { return [] }

        // Body text is whatever the multi-line paragraphs are set in. If the page
        // has none, fall back to the median of everything.
        let bodyHeights = candidates
            .filter { $0.lineCount > 1 }
            .map(\.fontSize)
            .filter { $0 > 0 }
            .sorted()
        let allHeights = candidates
            .map(\.fontSize)
            .filter { $0 > 0 }
            .sorted()
        let reference = (bodyHeights.isEmpty ? allHeights : bodyHeights)
        guard !reference.isEmpty else { return candidates.map { _ in .paragraph } }
        let body = reference[reference.count / 2]
        guard body > 0 else { return candidates.map { _ in .paragraph } }

        // Collect the distinct sizes that qualify as headings, largest first, so
        // level assignment reflects the page's actual hierarchy rather than fixed
        // thresholds. Rounded to 0.5pt to avoid OCR jitter splitting one size in two.
        var headingSizes: Set<Double> = []
        for candidate in candidates {
            let size = lineHeight(candidate)
            if isHeadingShaped(candidate, size: size, body: body) {
                headingSizes.insert((size * 2).rounded() / 2)
            }
        }
        let ranked = headingSizes.sorted(by: >)

        return candidates.map { candidate in
            let size = lineHeight(candidate)
            guard isHeadingShaped(candidate, size: size, body: body) else { return .paragraph }
            let rounded = (size * 2).rounded() / 2
            let rank = ranked.firstIndex(of: rounded) ?? 0
            // Start at h1 and never go past h6.
            return .heading(level: min(rank + 1, 6))
        }
    }

    private static func lineHeight(_ c: Candidate) -> Double { c.fontSize }

    private static func isHeadingShaped(_ c: Candidate, size: Double, body: Double) -> Bool {
        // Headings are short. A long run of text set large is a pull quote or a
        // large-print document, not a heading, and promoting it wrecks the outline.
        let text = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, c.lineCount <= 2, text.count <= 120 else { return false }
        // Page numbers, margin line numbers and rules are set in their own size
        // and would otherwise outrank the real headings.
        guard text.contains(where: \.isLetter) else { return false }
        guard text.count >= 2 else { return false }
        // Sentence-ending punctuation is strong evidence of prose.
        if text.hasSuffix(".") && text.count > 60 { return false }
        // A heading starts with a capital, a digit, or a symbol — never a
        // lowercase word. A fragment like "its evolution." is the tail of a
        // sentence that happened to be set apart, and promoting it puts prose
        // into the outline every chunk beneath it then inherits.
        if let first = text.first, first.isLowercase { return false }

        // A numbered section title is a heading however it is set. Some styles
        // distinguish subsections by weight alone, or by nothing beyond the
        // number itself — and those are exactly the headings a size test misses.
        if c.lineCount == 1, text.count <= 90, sectionDepth(of: text) != nil,
           let first = text.drop(while: { !$0.isWhitespace })
                           .drop(while: { $0.isWhitespace }).first,
           first.isUppercase {
            return true
        }
        // Either visibly larger, or set in bold at no less than body size —
        // the two ways a heading distinguishes itself typographically.
        // Academic styles often set section headings just one point above the
        // body, so the size threshold has to be tight. It can afford to be:
        // `fontSize` is a real point size read from the font, which varies by
        // under 2% within a paragraph, not a noisy geometric estimate.
        if size >= body * 1.06 { return true }
        return c.isBold && size >= body * 0.95 && text.count <= 80
    }
}

extension HeadingHeuristic {
    /// Re-ranks heading levels across a whole document.
    ///
    /// Each page is classified against its own typography, which is right for
    /// deciding *whether* something is a heading but wrong for deciding its
    /// depth: a page holding only section headings has nothing larger to compare
    /// them to and calls them all h1. Ranking the distinct sizes once, over the
    /// entire document, restores a consistent outline.
    public static func normalizeLevels(_ pages: [PageContent]) -> [PageContent] {
        let sizes = pages
            .flatMap(\.blocks)
            .compactMap { block -> Double? in
                guard case .heading(let heading) = block else { return nil }
                return heading.fontSize
            }
            .filter { $0 > 0 }

        // Nothing to rank if the engine could not measure sizes.
        guard sizes.count > 1 else { return pages }
        let tiers = clusterSizes(sizes)
        guard tiers.count > 1 else { return pages }

        // A document that numbers its sections has already declared its own
        // outline. "3.2 Results" is unambiguously one level below "3 Method",
        // whatever the type sizes happen to be — and numbering survives styles
        // where every heading is set at the same size.
        let numbered = pages.flatMap(\.blocks).contains { block in
            guard case .heading(let heading) = block else { return false }
            return sectionDepth(of: heading.text) != nil
        }
        // Numbered sections sit under the document title when there is one.
        let offset = numbered && tiers.count > 1 ? 1 : 0

        return pages.map { page in
            var page = page
            page.blocks = page.blocks.map { block in
                guard case .heading(var heading) = block else { return block }
                if let depth = sectionDepth(of: heading.text) {
                    heading.level = min(depth + offset, 6)
                } else if let size = heading.fontSize, size > 0 {
                    heading.level = min(level(for: size, in: tiers), 6)
                }
                return .heading(heading)
            }
            return page
        }
    }

    /// Depth of a heading's section number, or nil when it has none.
    ///
    /// Recognises `2`, `3.1`, `4.2.1` and appendix forms like `A` or `B.2`, each
    /// followed by an actual title — a bare number is a page number, and a line
    /// starting with a year or a citation is prose.
    public static func sectionDepth(of text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return nil
        }
        var label = String(trimmed[trimmed.startIndex..<separator])
        if label.hasSuffix(".") { label.removeLast() }
        guard !label.isEmpty else { return nil }

        // There must be a real title after the number.
        let rest = trimmed[trimmed.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
        guard rest.count >= 2, rest.contains(where: \.isLetter) else { return nil }

        let parts = label.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }

        for (index, part) in parts.enumerated() {
            if part.allSatisfy(\.isNumber), !part.isEmpty {
                // A four-digit leading number is a year, not a section.
                if index == 0, part.count > 2 { return nil }
                continue
            }
            // A single capital letter is an appendix, but only in first position.
            if index == 0, part.count == 1, part.first!.isUppercase, part.first!.isLetter {
                continue
            }
            return nil
        }
        return parts.count
    }

    /// Groups measured sizes into distinct typographic tiers, largest first.
    ///
    /// Sizes are clustered rather than rounded because engines differ in how
    /// precisely they can measure: the text layer reports true point sizes, while
    /// Vision only offers box heights, where the same heading can vary a few
    /// percent from line to line. Fixed rounding turns that jitter into a dozen
    /// spurious heading levels.
    static func clusterSizes(_ sizes: [Double], tolerance: Double = 0.06) -> [Double] {
        let sorted = sizes.sorted(by: >)
        var tiers: [Double] = []
        for size in sorted {
            if let last = tiers.last, size > last * (1 - tolerance) { continue }
            tiers.append(size)
        }
        return tiers
    }

    static func level(for size: Double, in tiers: [Double]) -> Int {
        for (index, tier) in tiers.enumerated() where size > tier * 0.94 {
            return index + 1
        }
        return tiers.count
    }
}
