import Foundation

/// Which extraction pipeline the user selected. The three stops of the quality
/// slider. Named rather than continuous because the cost of each stop differs in
/// kind — `fast` needs no download, the other two need a 1.25 GB model.
public enum QualityTier: String, Codable, Sendable, CaseIterable {
    case fast, balanced, best

    public var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .best: return "Best"
        }
    }

    public var requiresModel: Bool { self != .fast }
}

/// Which engine actually produced a given page. Recorded per page because a
/// single document routes pages independently — a hybrid PDF with scanned
/// inserts will show more than one value here.
public enum EngineID: String, Codable, Sendable {
    case textLayer      // PDFKit, digital text
    case vision         // Vision RecognizeDocumentsRequest
    case glmOCR         // GLM-OCR full page
    case glmOCRLayout   // Vision layout + GLM-OCR per region
}

public struct PageContent: Codable, Sendable, Hashable {
    public var index: Int
    /// Page size in PDF points.
    public var width: Double
    public var height: Double
    public var blocks: [Block]
    public var engine: EngineID
    /// Wall-clock seconds spent extracting this page.
    public var duration: Double?

    public init(index: Int, width: Double, height: Double, blocks: [Block],
                engine: EngineID, duration: Double? = nil) {
        self.index = index
        self.width = width
        self.height = height
        self.blocks = blocks
        self.engine = engine
        self.duration = duration
    }
}

public struct OffprintDocument: Codable, Sendable, Hashable {
    public var source: Source
    public var engine: Engine
    public var pages: [PageContent]

    public struct Source: Codable, Sendable, Hashable {
        public var filename: String
        public var pages: Int
        public var sha256: String?
        public init(filename: String, pages: Int, sha256: String? = nil) {
            self.filename = filename
            self.pages = pages
            self.sha256 = sha256
        }
    }

    public struct Engine: Codable, Sendable, Hashable {
        public var tier: QualityTier
        public var model: String?
        public var appVersion: String
        public init(tier: QualityTier, model: String? = nil, appVersion: String) {
            self.tier = tier
            self.model = model
            self.appVersion = appVersion
        }
    }

    public init(source: Source, engine: Engine, pages: [PageContent]) {
        self.source = source
        self.engine = engine
        self.pages = pages
    }

    public var allBlocks: [Block] { pages.flatMap(\.blocks) }

    /// Total extraction time across pages, when recorded.
    public var totalDuration: Double {
        pages.compactMap(\.duration).reduce(0, +)
    }
}
