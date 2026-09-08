import Foundation

/// A Model Context Protocol server over stdio.
///
/// The tools are deliberately not "convert this PDF and hand back the text".
/// A 125-page report is ~64,000 tokens; returning it in one call spends most of
/// an agent's context to answer a question that one section would have answered.
/// So the surface is: look at the outline, search it, read the part you want,
/// and write the full export to disk when you actually want the whole thing.
///
/// The protocol is implemented directly rather than through a dependency: the
/// three methods that matter — `initialize`, `tools/list`, `tools/call` — are
/// small and stable, and keeping them here means the whole surface is unit
/// tested with no package to track.
public actor MCPServer {

    public static let protocolVersion = "2025-06-18"
    public static let serverName = "offprint"

    private let service: DocumentService
    private let version: String
    private let defaultTier: QualityTier

    public init(service: DocumentService, version: String = "0.1.0",
                defaultTier: QualityTier = .fast) {
        self.service = service
        self.version = version
        self.defaultTier = defaultTier
    }

    // MARK: - Transport

    /// Reads newline-delimited JSON-RPC from `input` and writes replies to `output`.
    public func run(input: FileHandle = .standardInput,
                    output: FileHandle = .standardOutput) async {
        var buffer = Data()
        while true {
            let read = input.availableData
            if read.isEmpty { break }             // stdin closed
            buffer.append(read)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = buffer[buffer.index(after: newline)...]
                guard !line.isEmpty else { continue }
                if let reply = await handle(Data(line)) {
                    try? output.write(contentsOf: reply + Data([0x0A]))
                }
            }
        }
    }

    /// Handles one message. Returns nil for notifications, which take no reply.
    public func handle(_ message: Data) async -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: message),
              let request = object as? [String: Any],
              let method = request["method"] as? String else {
            return encode(error: -32700, message: "Parse error", id: nil)
        }
        let id = request["id"]
        // A request without an id is a notification.
        guard id != nil else { return nil }

        let arguments = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return encode(result: [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": Self.serverName, "version": version],
            ], id: id)

        case "ping":
            return encode(result: [:], id: id)

        case "tools/list":
            return encode(result: ["tools": Self.toolDefinitions], id: id)

        case "tools/call":
            let name = arguments["name"] as? String ?? ""
            let input = arguments["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await call(name, input)
                return encode(result: [
                    "content": [["type": "text", "text": text]],
                    "isError": false,
                ], id: id)
            } catch {
                // Tool failures are reported in the result, not as protocol
                // errors: the agent should see the message and try something
                // else rather than treat the server as broken.
                return encode(result: [
                    "content": [["type": "text", "text": "Error: \(error.localizedDescription)"]],
                    "isError": true,
                ], id: id)
            }

        default:
            return encode(error: -32601, message: "Unknown method: \(method)", id: id)
        }
    }

    // MARK: - Tools

    public enum ToolError: Error, LocalizedError {
        case missingArgument(String)
        case unknownTool(String)
        case notFound(String)

        public var errorDescription: String? {
            switch self {
            case .missingArgument(let name): return "Missing required argument '\(name)'."
            case .unknownTool(let name): return "No such tool '\(name)'."
            case .notFound(let what): return "\(what) not found."
            }
        }
    }

    func call(_ name: String, _ arguments: [String: Any]) async throws -> String {
        func string(_ key: String) throws -> String {
            guard let value = arguments[key] as? String, !value.isEmpty else {
                throw ToolError.missingArgument(key)
            }
            return value
        }
        func integer(_ key: String, default fallback: Int) -> Int {
            (arguments[key] as? Int) ?? (arguments[key] as? NSNumber)?.intValue ?? fallback
        }
        func flag(_ key: String, default fallback: Bool) -> Bool {
            (arguments[key] as? Bool) ?? fallback
        }

        let tier = QualityTier(rawValue: arguments["tier"] as? String ?? "") ?? defaultTier

        switch name {
        case "open_document":
            let entry = try await service.entry(for: URL(filePath: try string("path")), tier: tier)
            let statistics = entry.document.statistics ?? entry.document.computedStatistics
            // Grouped in en_US regardless of the host locale: "41.022 words"
            // under a German locale reads as forty-one to a model.
            let count = { (value: Int) in value.formatted(.number.locale(Locale(identifier: "en_US"))) }
            return """
            \(entry.path.lastPathComponent) — \(statistics.pages) pages, \
            \(count(statistics.words)) words, ~\(count(statistics.estimatedTokens)) tokens, \
            \(statistics.tables) tables\(statistics.uncertainTables > 0 ? " (\(statistics.uncertainTables) unverified)" : "")
            \(entry.chunks.count) chunks. Read one with read_section or find passages with search_document.

            OUTLINE
            \(DocumentService.renderOutline(entry.outline))
            """

        case "get_outline":
            let entry = try await service.entry(for: URL(filePath: try string("path")), tier: tier)
            return DocumentService.renderOutline(entry.outline)

        case "read_section":
            let entry = try await service.entry(for: URL(filePath: try string("path")), tier: tier)
            let id = try string("section_id")
            let chunks = DocumentService.section(id, in: entry,
                                                 includingSubsections: flag("include_subsections", default: true))
            guard !chunks.isEmpty else { throw ToolError.notFound("Section '\(id)'") }
            return chunks.map(\.text).joined(separator: "\n\n")

        case "search_document":
            let entry = try await service.entry(for: URL(filePath: try string("path")), tier: tier)
            let query = try string("query")
            let hits = DocumentService.search(query, in: entry, limit: integer("limit", default: 8))
            guard !hits.isEmpty else { return "No passages matched \"\(query)\"." }
            return hits.map { hit in
                let path = hit.chunk.headingPath.joined(separator: " › ")
                let pages = hit.chunk.pages.map { String($0 + 1) }.joined(separator: ", ")
                return """
                [chunk \(hit.chunk.id) · section \(hit.chunk.sectionID) · p. \(pages)]
                \(path)
                \(hit.chunk.text.prefix(700))
                """
            }.joined(separator: "\n\n---\n\n")

        case "read_chunk":
            let entry = try await service.entry(for: URL(filePath: try string("path")), tier: tier)
            let chunks = DocumentService.chunk(id: integer("chunk_id", default: 0), in: entry,
                                               neighbours: integer("neighbours", default: 0))
            guard !chunks.isEmpty else { throw ToolError.notFound("Chunk") }
            return chunks.map(\.text).joined(separator: "\n\n")

        case "export_document":
            let path = URL(filePath: try string("path"))
            let entry = try await service.entry(for: path, tier: tier)
            let directory = URL(filePath: try string("output_directory"))
            let exporter = DocumentExporter(options: .init(
                writeJSON: flag("json", default: true),
                writeChunks: flag("chunks", default: true),
                writeFigures: flag("figures", default: true)))
            let result = try exporter.export(entry.document, source: path, to: directory)
            // Paths, not content: this is the way to get the whole document
            // without spending the context to read it.
            return [result.markdownURL, result.jsonURL, result.chunksURL, result.outlineURL]
                .compactMap { $0?.path(percentEncoded: false) }
                .joined(separator: "\n")

        default:
            throw ToolError.unknownTool(name)
        }
    }

    // MARK: - Schemas

    static var tierProperty: [String: Any] {[
        "type": "string",
        "enum": ["fast", "balanced", "best"],
        "description": "Extraction quality. 'fast' uses the text layer and Apple Vision and needs no download; 'balanced' and 'best' run a local OCR model at about 4 s/page.",
    ]}

    static var toolDefinitions: [[String: Any]] {[
        [
            "name": "open_document",
            "description": "Convert a PDF and return its size, counts and section outline. Start here: the outline tells you which sections exist so you can read only what you need.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute path to the PDF."],
                    "tier": tierProperty,
                ],
                "required": ["path"],
            ],
        ],
        [
            "name": "get_outline",
            "description": "Return just the section outline of a PDF, with token counts and page ranges per section.",
            "inputSchema": [
                "type": "object",
                "properties": ["path": ["type": "string"], "tier": tierProperty],
                "required": ["path"],
            ],
        ],
        [
            "name": "read_section",
            "description": "Read one section of a PDF as Markdown, by the section id shown in the outline (for example '3.1').",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string"],
                    "section_id": ["type": "string", "description": "Section id from the outline, e.g. '3.1'."],
                    "include_subsections": ["type": "boolean", "description": "Include nested sections. Defaults to true."],
                    "tier": tierProperty,
                ],
                "required": ["path", "section_id"],
            ],
        ],
        [
            "name": "search_document",
            "description": "Find the passages in a PDF that mention a term. Returns ranked excerpts with their section breadcrumb, page numbers and chunk id.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string"],
                    "query": ["type": "string"],
                    "limit": ["type": "integer", "description": "Maximum passages to return. Defaults to 8."],
                    "tier": tierProperty,
                ],
                "required": ["path", "query"],
            ],
        ],
        [
            "name": "read_chunk",
            "description": "Read one chunk by id, optionally with its neighbours, to widen a search hit.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string"],
                    "chunk_id": ["type": "integer"],
                    "neighbours": ["type": "integer", "description": "Chunks to include on each side. Defaults to 0."],
                    "tier": tierProperty,
                ],
                "required": ["path", "chunk_id"],
            ],
        ],
        [
            "name": "export_document",
            "description": "Write the full conversion to a directory as Markdown, JSON, chunks and figures, and return the file paths. Use this instead of reading a whole document into the conversation.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string"],
                    "output_directory": ["type": "string"],
                    "json": ["type": "boolean"], "chunks": ["type": "boolean"],
                    "figures": ["type": "boolean"], "tier": tierProperty,
                ],
                "required": ["path", "output_directory"],
            ],
        ],
    ]}

    // MARK: - Encoding

    private func encode(result: [String: Any], id: Any?) -> Data? {
        envelope(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func encode(error code: Int, message: String, id: Any?) -> Data? {
        envelope(["jsonrpc": "2.0", "id": id ?? NSNull(),
                  "error": ["code": code, "message": message]])
    }

    private func envelope(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }
}
