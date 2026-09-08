import Foundation

/// One retrievable piece of a document, aware of where it sits in it.
///
/// Chunking by a fixed window is what makes retrieval brittle: a paragraph
/// lifted out of a 125-page report says almost nothing on its own, and a chunk
/// that straddles a section boundary answers questions about neither section.
///
/// So chunks here are cut *by section first*, then by size within a section.
/// Every chunk carries the breadcrumb trail of the section it belongs to, its
/// position within that section, and links to its neighbours — enough for an
/// agent to know what it is holding, whether it is holding all of it, and where
/// to look next.
public struct DocumentChunk: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    /// Markdown for this chunk, rendered from the same block tree as the export.
    public var text: String
    /// Enclosing headings, outermost first.
    public var headingPath: [String]
    /// Positional address of the section, e.g. `2.4.1`. Stable for a document.
    public var sectionID: String
    /// Position within the section: part `partIndex` of `partCount`.
    public var partIndex: Int
    public var partCount: Int
    /// Pages this chunk draws from, in order.
    public var pages: [Int]
    public var estimatedTokens: Int
    public var blockTypes: [String]
    /// Neighbouring chunks in reading order, for widening a retrieval hit.
    public var previousID: Int?
    public var nextID: Int?

    public init(id: Int, text: String, headingPath: [String], sectionID: String,
                partIndex: Int, partCount: Int, pages: [Int], estimatedTokens: Int,
                blockTypes: [String], previousID: Int? = nil, nextID: Int? = nil) {
        self.id = id
        self.text = text
        self.headingPath = headingPath
        self.sectionID = sectionID
        self.partIndex = partIndex
        self.partCount = partCount
        self.pages = pages
        self.estimatedTokens = estimatedTokens
        self.blockTypes = blockTypes
        self.previousID = previousID
        self.nextID = nextID
    }

    /// The text an embedding should usually see.
    ///
    /// Prepending the breadcrumb is what current retrieval practice calls
    /// contextual chunking: most of the disambiguating signal for a fragment is
    /// in which section it came from, not in the fragment itself.
    public var contextualText: String {
        var header = headingPath.joined(separator: " › ")
        if partCount > 1 { header += " (part \(partIndex) of \(partCount))" }
        return header.isEmpty ? text : header + "\n\n" + text
    }
}

/// The document's section tree, so an agent can navigate before it retrieves.
public struct DocumentOutline: Codable, Sendable, Hashable {
    public struct Section: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var level: Int
        public var pages: [Int]
        public var estimatedTokens: Int
        /// Chunks belonging to this section directly, in order.
        public var chunkIDs: [Int]
        public var children: [Section]

        public init(id: String, title: String, level: Int, pages: [Int],
                    estimatedTokens: Int, chunkIDs: [Int], children: [Section]) {
            self.id = id
            self.title = title
            self.level = level
            self.pages = pages
            self.estimatedTokens = estimatedTokens
            self.chunkIDs = chunkIDs
            self.children = children
        }
    }

    public var sections: [Section]
    public var totalChunks: Int
    public var estimatedTokens: Int
}

/// Splits a document into section-scoped, retrieval-sized pieces.
public struct Chunker: Sendable {

    public struct Options: Sendable {
        /// Token budget for a chunk within a section.
        public var targetTokens: Int
        /// A section shorter than this is merged into its parent's run rather
        /// than becoming a chunk of its own — otherwise a run of subheadings
        /// produces a chunk per heading and retrieval gets noisier, not better.
        public var minimumTokens: Int

        public init(targetTokens: Int = 512, minimumTokens: Int = 64) {
            self.targetTokens = targetTokens
            self.minimumTokens = minimumTokens
        }
    }

    public var options: Options
    public var writer: MarkdownWriter

    public init(options: Options = .init(), markdown writer: MarkdownWriter = .init()) {
        self.options = options
        self.writer = writer
    }

    // MARK: - Sections

    /// A run of blocks under one heading path.
    struct Section {
        var path: [String]
        var levels: [Int]
        var id: String
        var blocks: [(block: Block, page: Int)]
    }

    /// Cuts the document at every heading, so no chunk spans two sections.
    func sections(of document: OffprintDocument) -> [Section] {
        var out: [Section] = []
        var stack: [(level: Int, title: String)] = []
        // Positional counters, one per depth, producing ids like "2.4.1".
        var counters: [Int] = []
        var current = Section(path: [], levels: [], id: "0", blocks: [])

        func close() {
            if !current.blocks.isEmpty { out.append(current) }
        }

        for page in document.pages {
            for block in page.blocks {
                if case .heading(let heading) = block {
                    close()
                    stack.removeAll { $0.level >= heading.level }
                    stack.append((heading.level, heading.text))

                    // Positional address: siblings increment, deeper sections
                    // start a new component.
                    let depth = stack.count
                    if counters.count >= depth {
                        counters.removeSubrange(depth...)
                        counters[depth - 1] += 1
                    } else {
                        while counters.count < depth - 1 { counters.append(1) }
                        counters.append(1)
                    }

                    current = Section(
                        path: stack.map(\.title),
                        levels: stack.map(\.level),
                        id: counters.map(String.init).joined(separator: "."),
                        blocks: [(block, page.index)])
                } else {
                    current.blocks.append((block, page.index))
                }
            }
        }
        close()
        return out
    }

    // MARK: - Chunking

    public func chunk(_ document: OffprintDocument) -> [DocumentChunk] {
        var chunks: [DocumentChunk] = []

        for section in sections(of: document) {
            // Split the section's blocks into parts that fit the budget. A table
            // is never split: half a table is not a fact, it is a misleading one.
            var parts: [[(block: Block, page: Int)]] = []
            var current: [(block: Block, page: Int)] = []
            var tokens = 0

            for entry in section.blocks {
                let cost = DocumentStatistics.estimateTokens(in: entry.block.plainText)
                if tokens + cost > options.targetTokens, tokens >= options.minimumTokens {
                    parts.append(current)
                    current = []
                    tokens = 0
                }
                current.append(entry)
                tokens += cost
            }
            if !current.isEmpty { parts.append(current) }

            for (index, part) in parts.enumerated() {
                let text = writer.write(blocks: part.map(\.block))
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                var pages: [Int] = []
                for entry in part where pages.last != entry.page { pages.append(entry.page) }

                chunks.append(DocumentChunk(
                    id: chunks.count,
                    text: text,
                    headingPath: section.path,
                    sectionID: section.id,
                    partIndex: index + 1,
                    partCount: parts.count,
                    pages: pages,
                    estimatedTokens: DocumentStatistics.estimateTokens(in: text),
                    blockTypes: Array(Set(part.map(\.block.typeName))).sorted()))
            }
        }

        // Neighbour links, so a retrieval hit can be widened without re-reading
        // the document.
        for index in chunks.indices {
            chunks[index].previousID = index > 0 ? index - 1 : nil
            chunks[index].nextID = index + 1 < chunks.count ? index + 1 : nil
        }
        return chunks
    }

    /// Builds the section tree that accompanies the chunks.
    public func outline(_ document: OffprintDocument, chunks: [DocumentChunk]) -> DocumentOutline {
        var roots: [DocumentOutline.Section] = []

        // Group chunks by section, preserving order.
        var order: [String] = []
        var bySection: [String: [DocumentChunk]] = [:]
        for chunk in chunks {
            if bySection[chunk.sectionID] == nil { order.append(chunk.sectionID) }
            bySection[chunk.sectionID, default: []].append(chunk)
        }

        func insert(_ section: DocumentOutline.Section, into nodes: inout [DocumentOutline.Section],
                    path: [String]) {
            guard let head = path.first else { nodes.append(section); return }
            if let index = nodes.firstIndex(where: { $0.id == head }) {
                insert(section, into: &nodes[index].children, path: Array(path.dropFirst()))
            } else {
                nodes.append(section)
            }
        }

        for id in order {
            guard let group = bySection[id], let first = group.first else { continue }
            let node = DocumentOutline.Section(
                id: id,
                title: first.headingPath.last ?? "Document",
                level: first.headingPath.count,
                pages: Array(Set(group.flatMap(\.pages))).sorted(),
                estimatedTokens: group.reduce(0) { $0 + $1.estimatedTokens },
                chunkIDs: group.map(\.id),
                children: [])

            // Ancestors are the id with trailing components removed.
            let components = id.split(separator: ".").map(String.init)
            var ancestors: [String] = []
            for count in 1..<max(1, components.count) {
                ancestors.append(components.prefix(count).joined(separator: "."))
            }
            insert(node, into: &roots, path: ancestors)
        }

        return DocumentOutline(
            sections: roots,
            totalChunks: chunks.count,
            estimatedTokens: chunks.reduce(0) { $0 + $1.estimatedTokens })
    }

    /// Serialises chunks as JSON Lines, the format retrieval pipelines read.
    public func jsonLines(_ chunks: [DocumentChunk]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for chunk in chunks {
            out.append(try encoder.encode(chunk))
            out.append(0x0A)
        }
        return out
    }
}
