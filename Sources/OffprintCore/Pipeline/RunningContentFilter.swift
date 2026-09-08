import Foundation

/// Removes running headers, footers and page numbers.
///
/// Page furniture is the most persistent noise in a converted document: a
/// journal repeats its title, DOI and page number on all fifteen pages, and
/// because that line is set apart and often in a distinct size, heading
/// detection promotes every copy. The result is a document whose outline is
/// mostly the same line fifteen times, and whose chunks each open with a DOI.
///
/// Furniture is recognised by *repetition in place*: the same text, ignoring
/// digits, appearing in the same margin band on many pages. One page cannot
/// tell you it is furniture — only the document can.
public enum RunningContentFilter {

    public struct Options: Sendable {
        /// Fraction of page height at the top and bottom to consider.
        public var marginFraction: Double
        /// Pages a line must appear on before it counts as furniture.
        public var minimumPages: Int
        /// Share of pages a line must appear on.
        public var minimumShare: Double

        public init(marginFraction: Double = 0.13, minimumPages: Int = 3,
                    minimumShare: Double = 0.4) {
            self.marginFraction = marginFraction
            self.minimumPages = minimumPages
            self.minimumShare = minimumShare
        }
    }

    public static func strip(_ pages: [PageContent], options: Options = .init()) -> [PageContent] {
        guard pages.count >= options.minimumPages else { return pages }

        // Count how many distinct pages each normalised margin line appears on.
        var pagesByKey: [String: Set<Int>] = [:]
        for page in pages {
            for block in page.blocks {
                guard let key = key(for: block, on: page, options: options) else { continue }
                pagesByKey[key, default: []].insert(page.index)
            }
        }

        let threshold = max(options.minimumPages,
                            Int((Double(pages.count) * options.minimumShare).rounded()))
        let furniture = Set(pagesByKey.filter { $0.value.count >= threshold }.keys)
        guard !furniture.isEmpty else { return pages }

        return pages.map { page in
            var page = page
            page.blocks = page.blocks.filter { block in
                guard let key = key(for: block, on: page, options: options) else { return true }
                return !furniture.contains(key)
            }
            return page
        }
    }

    /// A normalised identity for a block, or nil if it cannot be furniture.
    static func key(for block: Block, on page: PageContent, options: Options) -> String? {
        // Only text can be furniture: a table or figure in the margin is content.
        switch block {
        case .paragraph, .heading: break
        default: return nil
        }
        guard let bbox = block.bbox, page.height > 0 else { return nil }

        let margin = page.height * options.marginFraction
        let inTop = bbox.maxY <= margin
        let inBottom = bbox.minY >= page.height - margin
        guard inTop || inBottom else { return nil }

        let text = normalize(block.plainText)
        // A bare page number normalises to nothing, and is furniture wherever it
        // sits in the margin.
        guard text.count <= 200 else { return nil }
        return (inTop ? "top:" : "bottom:") + text
    }

    /// Lowercased, with digits dropped so page numbers do not make every
    /// footer unique, and whitespace collapsed.
    static func normalize(_ text: String) -> String {
        var out = ""
        var lastWasSpace = true
        for character in text.lowercased() {
            if character.isNumber { continue }
            if character.isWhitespace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(character)
                lastWasSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
