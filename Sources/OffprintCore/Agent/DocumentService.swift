import Foundation

/// Converts documents once and answers questions about them.
///
/// Built for an agent rather than a pipeline. Handing back a whole 125-page
/// report costs ~64,000 tokens and buries the answer; the useful operations are
/// *look at the structure*, *read one section*, and *find the passages that
/// mention this* — which is what an outline plus section-scoped chunks make
/// possible.
public actor DocumentService {

    public struct Entry: Sendable {
        public var document: OffprintDocument
        public var chunks: [DocumentChunk]
        public var outline: DocumentOutline
        public var path: URL
    }

    /// Supplied by the caller so this stays free of the model tiers, which live
    /// in the app target because MLX needs the Metal toolchain.
    public typealias Converter = @Sendable (URL, QualityTier) async throws -> OffprintDocument

    private let convert: Converter
    private let chunker: Chunker
    private var cache: [String: (modified: Date, entry: Entry)] = [:]

    public init(chunker: Chunker = .init(), convert: @escaping Converter) {
        self.chunker = chunker
        self.convert = convert
    }

    /// Converts a document, or returns the cached result if the file is unchanged.
    ///
    /// Caching on modification date matters more here than in a batch tool: an
    /// agent asks several questions about one document in a row, and re-reading
    /// a 125-page PDF for each would make the whole thing unusable.
    public func entry(for path: URL, tier: QualityTier = .fast) async throws -> Entry {
        let key = path.path(percentEncoded: false) + "#" + tier.rawValue
        let modified = (try? FileManager.default.attributesOfItem(atPath: path.path(percentEncoded: false))[.modificationDate] as? Date) ?? nil

        if let cached = cache[key], let modified, cached.modified == modified {
            return cached.entry
        }

        let document = try await convert(path, tier)
        let chunks = chunker.chunk(document)
        let entry = Entry(document: document, chunks: chunks,
                          outline: chunker.outline(document, chunks: chunks),
                          path: path)
        if let modified { cache[key] = (modified, entry) }
        return entry
    }

    public func forget(_ path: URL) {
        let prefix = path.path(percentEncoded: false) + "#"
        cache = cache.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: - Operations

    /// A compact, indented view of the section tree.
    public static func renderOutline(_ outline: DocumentOutline) -> String {
        var lines: [String] = []
        func walk(_ sections: [DocumentOutline.Section], depth: Int) {
            for section in sections {
                let indent = String(repeating: "  ", count: depth)
                let pages = section.pages.isEmpty ? "" :
                    " · p.\(section.pages[0] + 1)\(section.pages.count > 1 ? "–\(section.pages.last! + 1)" : "")"
                lines.append("\(indent)\(section.id) \(section.title)"
                    + "  [\(section.estimatedTokens) tokens\(pages)]")
                walk(section.children, depth: depth + 1)
            }
        }
        walk(outline.sections, depth: 0)
        return lines.joined(separator: "\n")
    }

    /// All chunks belonging to a section, and optionally its subsections.
    public static func section(_ id: String, in entry: Entry,
                               includingSubsections: Bool = true) -> [DocumentChunk] {
        entry.chunks.filter { chunk in
            includingSubsections
                ? chunk.sectionID == id || chunk.sectionID.hasPrefix(id + ".")
                : chunk.sectionID == id
        }
    }

    /// Ranked full-text search over the chunks.
    ///
    /// Deliberately lexical rather than semantic: embedding a document would mean
    /// downloading a second model and building an index for a question that is
    /// usually answered by "which section mentions this word". Heading matches
    /// score higher because a term in a heading describes the whole section.
    public static func search(_ query: String, in entry: Entry, limit: Int = 8) -> [(chunk: DocumentChunk, score: Double)] {
        let terms = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 }
        guard !terms.isEmpty else { return [] }

        var scored: [(DocumentChunk, Double)] = []
        for chunk in entry.chunks {
            let body = chunk.text.lowercased()
            let heading = chunk.headingPath.joined(separator: " ").lowercased()

            var score = 0.0
            var matched = 0
            for term in terms {
                let inBody = body.ranges(of: term).count
                let inHeading = heading.ranges(of: term).count
                if inBody + inHeading == 0 { continue }
                matched += 1
                // Diminishing returns on repetition, so a page that merely says
                // the word twenty times does not outrank the section about it.
                score += log(1 + Double(inBody)) + 3 * Double(inHeading)
            }
            guard matched > 0 else { continue }
            // Reward covering more of the query.
            score *= Double(matched) / Double(terms.count)
            scored.append((chunk, score))
        }

        return scored
            .sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }
            .prefix(limit)
            .map { (chunk: $0.0, score: $0.1) }
    }

    public static func chunk(id: Int, in entry: Entry, neighbours: Int = 0) -> [DocumentChunk] {
        guard entry.chunks.indices.contains(id) else { return [] }
        let low = max(0, id - neighbours)
        let high = min(entry.chunks.count - 1, id + neighbours)
        return Array(entry.chunks[low...high])
    }
}
