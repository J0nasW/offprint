import Foundation

/// Counts for a converted document.
///
/// Extraction is usually a step on the way to feeding a model, so the numbers
/// that decide whether the output fits a context window belong in the output
/// itself rather than in a separate tool.
public struct DocumentStatistics: Codable, Sendable, Hashable {
    public var pages: Int
    public var characters: Int
    public var charactersExcludingWhitespace: Int
    public var words: Int
    /// Approximate token count. See ``estimateTokens(in:)`` for what it assumes.
    public var estimatedTokens: Int
    public var blocks: Int
    public var headings: Int
    public var tables: Int
    public var figures: Int
    /// Tables whose structure the engine could not verify.
    public var uncertainTables: Int

    public init(pages: Int, characters: Int, charactersExcludingWhitespace: Int,
                words: Int, estimatedTokens: Int, blocks: Int, headings: Int,
                tables: Int, figures: Int, uncertainTables: Int) {
        self.pages = pages
        self.characters = characters
        self.charactersExcludingWhitespace = charactersExcludingWhitespace
        self.words = words
        self.estimatedTokens = estimatedTokens
        self.blocks = blocks
        self.headings = headings
        self.tables = tables
        self.figures = figures
        self.uncertainTables = uncertainTables
    }
}

extension DocumentStatistics {

    public init(_ document: OffprintDocument) {
        let blocks = document.allBlocks
        let text = blocks.map(\.plainText).joined(separator: "\n")

        var characters = 0
        var withoutWhitespace = 0
        for scalar in text.unicodeScalars {
            characters += 1
            if !scalar.properties.isWhitespace { withoutWhitespace += 1 }
        }

        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count

        self.init(
            pages: document.pages.count,
            characters: characters,
            charactersExcludingWhitespace: withoutWhitespace,
            words: words,
            estimatedTokens: Self.estimateTokens(in: text),
            blocks: blocks.count,
            headings: blocks.filter { $0.typeName == "heading" }.count,
            tables: blocks.filter { $0.typeName == "table" }.count,
            figures: blocks.filter { $0.typeName == "figure" }.count,
            uncertainTables: blocks.filter { block in
                guard case .table(let table) = block else { return false }
                return table.structureSuspect
            }.count
        )
    }

    /// Estimates the token count for a byte-pair tokenizer.
    ///
    /// Deliberately an estimate, and named as one. An exact count is only exact
    /// for one specific tokenizer, and models disagree — so shipping a number
    /// labelled "tokens" would be precise and wrong. This uses the widely-used
    /// ~4 characters per token for Latin scripts, adjusted upward for CJK, where
    /// a character often costs a token or more.
    public static func estimateTokens(in text: String) -> Int {
        var latin = 0
        var dense = 0
        for scalar in text.unicodeScalars where !scalar.properties.isWhitespace {
            let value = scalar.value
            // CJK, Hiragana, Katakana, Hangul.
            if (0x3040...0x30FF).contains(value) || (0x3400...0x4DBF).contains(value)
                || (0x4E00...0x9FFF).contains(value) || (0xAC00...0xD7AF).contains(value) {
                dense += 1
            } else {
                latin += 1
            }
        }
        return Int((Double(latin) / 3.8 + Double(dense) * 1.1).rounded())
    }
}

extension OffprintDocument {
    /// Counts computed from the current contents, ignoring any stored value.
    public var computedStatistics: DocumentStatistics { .init(self) }
}
