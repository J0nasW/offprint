import Foundation

/// One semantic element on a page.
///
/// Markdown and JSON are both rendered from this tree, so the two exports can
/// never drift apart — a bug in one is a bug in both.
public enum Block: Codable, Sendable, Hashable {
    case heading(Heading)
    case paragraph(Paragraph)
    case list(List)
    case table(Table)
    case figure(Figure)
    case formula(Formula)
    case code(Code)

    public struct Heading: Codable, Sendable, Hashable {
        public var level: Int
        public var text: String
        public var bbox: BoundingBox?
        public var confidence: Double?
        /// Measured type size, when the engine could read one.
        ///
        /// Kept on the block so heading levels can be ranked across the whole
        /// document: a page containing only section headings has no title to
        /// compare against, and would otherwise call them all h1.
        public var fontSize: Double?

        public init(level: Int, text: String, bbox: BoundingBox? = nil,
                    confidence: Double? = nil, fontSize: Double? = nil) {
            self.level = min(max(level, 1), 6)
            self.text = text
            self.bbox = bbox
            self.confidence = confidence
            self.fontSize = fontSize
        }
    }

    public struct Paragraph: Codable, Sendable, Hashable {
        public var text: String
        public var bbox: BoundingBox?
        public var confidence: Double?
        /// Measured type size, when the engine could read one. Used to establish
        /// the document's body size, which is what heading detection compares
        /// against.
        public var fontSize: Double?

        public init(text: String, bbox: BoundingBox? = nil, confidence: Double? = nil,
                    fontSize: Double? = nil) {
            self.text = text
            self.bbox = bbox
            self.confidence = confidence
            self.fontSize = fontSize
        }
    }

    public struct List: Codable, Sendable, Hashable {
        public var ordered: Bool
        public var items: [Item]
        public var bbox: BoundingBox?

        public struct Item: Codable, Sendable, Hashable {
            public var text: String
            /// Nesting depth, 0 for a top-level item.
            public var depth: Int
            public init(text: String, depth: Int = 0) {
                self.text = text
                self.depth = depth
            }
        }

        public init(ordered: Bool, items: [Item], bbox: BoundingBox? = nil) {
            self.ordered = ordered
            self.items = items
            self.bbox = bbox
        }
    }

    public struct Table: Codable, Sendable, Hashable {
        public var rows: [[Cell]]
        public var bbox: BoundingBox?
        /// Set when the engine has reason to doubt the row/column split.
        /// A mis-split table still serialises to valid Markdown, so without an
        /// explicit signal nothing downstream can tell that it went wrong.
        public var structureSuspect: Bool

        public struct Cell: Codable, Sendable, Hashable {
            public var text: String
            public var rowSpan: Int
            public var colSpan: Int
            public init(text: String, rowSpan: Int = 1, colSpan: Int = 1) {
                self.text = text
                self.rowSpan = max(1, rowSpan)
                self.colSpan = max(1, colSpan)
            }
        }

        public init(rows: [[Cell]], bbox: BoundingBox? = nil, structureSuspect: Bool = false) {
            self.rows = rows
            self.bbox = bbox
            self.structureSuspect = structureSuspect
        }

        public var columnCount: Int {
            rows.map { $0.reduce(0) { $0 + $1.colSpan } }.max() ?? 0
        }
    }

    public struct Figure: Codable, Sendable, Hashable {
        /// Path relative to the Markdown file, e.g. `images/p003-fig01.png`.
        public var path: String
        public var caption: String?
        public var bbox: BoundingBox?
        public init(path: String, caption: String? = nil, bbox: BoundingBox? = nil) {
            self.path = path
            self.caption = caption
            self.bbox = bbox
        }
    }

    public struct Formula: Codable, Sendable, Hashable {
        public var latex: String
        /// Inline formulas render as `$…$`, display formulas as a `$$` block.
        public var isInline: Bool
        public var bbox: BoundingBox?
        public init(latex: String, isInline: Bool = false, bbox: BoundingBox? = nil) {
            self.latex = latex
            self.isInline = isInline
            self.bbox = bbox
        }
    }

    public struct Code: Codable, Sendable, Hashable {
        public var text: String
        public var language: String?
        public var bbox: BoundingBox?
        public init(text: String, language: String? = nil, bbox: BoundingBox? = nil) {
            self.text = text
            self.language = language
            self.bbox = bbox
        }
    }
}

// MARK: - Convenience

extension Block {
    public var bbox: BoundingBox? {
        switch self {
        case .heading(let b):   return b.bbox
        case .paragraph(let b): return b.bbox
        case .list(let b):      return b.bbox
        case .table(let b):     return b.bbox
        case .figure(let b):    return b.bbox
        case .formula(let b):   return b.bbox
        case .code(let b):      return b.bbox
        }
    }

    /// Plain text of the block, used for diffing and for the page classifier.
    public var plainText: String {
        switch self {
        case .heading(let b):   return b.text
        case .paragraph(let b): return b.text
        case .list(let b):      return b.items.map(\.text).joined(separator: "\n")
        case .table(let b):     return b.rows.map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n")
        case .figure(let b):    return b.caption ?? ""
        case .formula(let b):   return b.latex
        case .code(let b):      return b.text
        }
    }

    /// Returns a copy positioned at `box`.
    ///
    /// Blocks parsed from a model's Markdown carry no geometry; the region they
    /// were read from supplies it, which keeps figure cropping, reading order
    /// and the JSON export working for model-read pages too.
    public func positioned(at box: BoundingBox) -> Block {
        switch self {
        case .heading(var b):   b.bbox = box; return .heading(b)
        case .paragraph(var b): b.bbox = box; return .paragraph(b)
        case .list(var b):      b.bbox = box; return .list(b)
        case .table(var b):     b.bbox = box; return .table(b)
        case .figure(var b):    b.bbox = box; return .figure(b)
        case .formula(var b):   b.bbox = box; return .formula(b)
        case .code(var b):      b.bbox = box; return .code(b)
        }
    }

    public var typeName: String {
        switch self {
        case .heading:   return "heading"
        case .paragraph: return "paragraph"
        case .list:      return "list"
        case .table:     return "table"
        case .figure:    return "figure"
        case .formula:   return "formula"
        case .code:      return "code"
        }
    }
}

// MARK: - Codable with a `type` discriminator

extension Block {
    private enum Discriminator: String, Codable {
        case heading, paragraph, list, table, figure, formula, code
    }

    private enum Key: String, CodingKey { case type }

    public init(from decoder: any Decoder) throws {
        let kind = try decoder.container(keyedBy: Key.self).decode(Discriminator.self, forKey: .type)
        let single = decoder
        switch kind {
        case .heading:   self = .heading(try Heading(from: single))
        case .paragraph: self = .paragraph(try Paragraph(from: single))
        case .list:      self = .list(try List(from: single))
        case .table:     self = .table(try Table(from: single))
        case .figure:    self = .figure(try Figure(from: single))
        case .formula:   self = .formula(try Formula(from: single))
        case .code:      self = .code(try Code(from: single))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var meta = encoder.container(keyedBy: Key.self)
        try meta.encode(typeName, forKey: .type)
        switch self {
        case .heading(let b):   try b.encode(to: encoder)
        case .paragraph(let b): try b.encode(to: encoder)
        case .list(let b):      try b.encode(to: encoder)
        case .table(let b):     try b.encode(to: encoder)
        case .figure(let b):    try b.encode(to: encoder)
        case .formula(let b):   try b.encode(to: encoder)
        case .code(let b):      try b.encode(to: encoder)
        }
    }
}
