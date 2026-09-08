import Foundation
import Testing
@testable import OffprintCore

@Suite("Agent surface")
struct AgentTests {

    /// A small document with real structure to navigate.
    static func sample() -> OffprintDocument {
        func paragraph(_ text: String) -> Block { .paragraph(.init(text: text)) }
        return OffprintDocument(
            source: .init(filename: "report.pdf", pages: 2),
            engine: .init(tier: .fast, appVersion: "0.1.0"),
            pages: [
                PageContent(index: 0, width: 600, height: 800, blocks: [
                    .heading(.init(level: 1, text: "Methods")),
                    paragraph("We collected samples from four sites."),
                    .heading(.init(level: 2, text: "Datasets")),
                    paragraph("The corpus contains ten thousand annotated documents."),
                ], engine: .textLayer),
                PageContent(index: 1, width: 600, height: 800, blocks: [
                    .heading(.init(level: 1, text: "Results")),
                    paragraph("Accuracy improved on every corpus we measured."),
                ], engine: .textLayer),
            ])
    }

    static func service() -> DocumentService {
        DocumentService { _, _ in sample() }
    }

    func entry() async throws -> DocumentService.Entry {
        try await Self.service().entry(for: URL(filePath: "/tmp/report.pdf"))
    }

    // MARK: - Service

    @Test("Search ranks heading matches above body matches")
    func searchPrefersHeadings() async throws {
        // A term in a heading describes the whole section; the same term buried
        // in a sentence describes one clause.
        let entry = try await entry()
        let hits = DocumentService.search("datasets", in: entry)
        #expect(hits.first?.chunk.headingPath.last == "Datasets")
    }

    @Test("Search covers more of the query first")
    func searchRewardsCoverage() async throws {
        let entry = try await entry()
        let hits = DocumentService.search("corpus accuracy", in: entry)
        let top = try #require(hits.first)
        #expect(top.chunk.text.contains("Accuracy"))
    }

    @Test("Search returns nothing for terms the document lacks")
    func searchMisses() async throws {
        let entry = try await entry()
        #expect(DocumentService.search("helicopter", in: entry).isEmpty)
    }

    @Test("A section can be read with or without its subsections")
    func readsSections() async throws {
        let entry = try await entry()
        let withChildren = DocumentService.section("1", in: entry, includingSubsections: true)
        let alone = DocumentService.section("1", in: entry, includingSubsections: false)
        #expect(withChildren.count > alone.count)
        #expect(alone.allSatisfy { $0.sectionID == "1" })
    }

    @Test("Neighbours widen a chunk without re-reading the document")
    func readsNeighbours() async throws {
        let entry = try await entry()
        let widened = DocumentService.chunk(id: 1, in: entry, neighbours: 1)
        #expect(widened.count == 3)
        #expect(widened.map(\.id) == [0, 1, 2])
    }

    @Test("The rendered outline shows ids, titles and token counts")
    func rendersOutline() async throws {
        let entry = try await entry()
        let text = DocumentService.renderOutline(entry.outline)
        #expect(text.contains("1 Methods"))
        #expect(text.contains("Datasets"))
        #expect(text.contains("tokens"))
    }

    @Test("A converted document is cached, not converted twice")
    func cachesConversions() async throws {
        // An agent asks several questions about one document in a row;
        // re-reading a long PDF for each would make the server unusable.
        let counter = Counter()
        let service = DocumentService { _, _ in
            await counter.increment()
            return Self.sample()
        }
        let url = URL(filePath: FileManager.default.temporaryDirectory
            .appending(path: "offprint-cache-test.pdf").path(percentEncoded: false))
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await service.entry(for: url)
        _ = try await service.entry(for: url)
        #expect(await counter.value == 1)
    }

    actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    // MARK: - Protocol

    func server() -> MCPServer { MCPServer(service: Self.service()) }

    func send(_ object: [String: Any], to server: MCPServer) async throws -> [String: Any]? {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let reply = await server.handle(data) else { return nil }
        return try JSONSerialization.jsonObject(with: reply) as? [String: Any]
    }

    @Test("Initialize reports the protocol version and server identity")
    func handlesInitialize() async throws {
        let reply = try await send(["jsonrpc": "2.0", "id": 1, "method": "initialize"],
                                   to: server())
        let result = try #require(reply?["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == MCPServer.protocolVersion)
        let info = try #require(result["serverInfo"] as? [String: Any])
        #expect(info["name"] as? String == "offprint")
    }

    @Test("Notifications get no reply")
    func ignoresNotifications() async throws {
        // A message without an id is a notification; replying to one is a
        // protocol violation.
        let reply = try await send(["jsonrpc": "2.0", "method": "notifications/initialized"],
                                   to: server())
        #expect(reply == nil)
    }

    @Test("Every advertised tool has a name, description and schema")
    func listsTools() async throws {
        let reply = try await send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], to: server())
        let result = try #require(reply?["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(tools.count == 6)
        for tool in tools {
            #expect((tool["name"] as? String)?.isEmpty == false)
            #expect((tool["description"] as? String)?.isEmpty == false)
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
        }
    }

    @Test("A tool call returns text content")
    func callsTool() async throws {
        let reply = try await send([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "get_outline", "arguments": ["path": "/tmp/report.pdf"]],
        ], to: server())
        let result = try #require(reply?["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect((content.first?["text"] as? String)?.contains("Methods") == true)
    }

    @Test("A failing tool reports the error in its result, not as a protocol error")
    func reportsToolErrors() async throws {
        // The agent should see the message and try something else, rather than
        // treat the server as broken.
        let reply = try await send([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "read_section",
                       "arguments": ["path": "/tmp/report.pdf", "section_id": "99"]],
        ], to: server())
        let result = try #require(reply?["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        #expect(reply?["error"] == nil)
    }

    @Test("A missing argument is reported, not crashed on")
    func reportsMissingArguments() async throws {
        let reply = try await send([
            "jsonrpc": "2.0", "id": 5, "method": "tools/call",
            "params": ["name": "read_section", "arguments": ["path": "/tmp/report.pdf"]],
        ], to: server())
        let result = try #require(reply?["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect((content.first?["text"] as? String)?.contains("section_id") == true)
    }

    @Test("An unknown method is a JSON-RPC error")
    func rejectsUnknownMethods() async throws {
        let reply = try await send(["jsonrpc": "2.0", "id": 6, "method": "resources/list"],
                                   to: server())
        let error = try #require(reply?["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32601)
    }

    @Test("Malformed input is a parse error, not a crash")
    func rejectsMalformedInput() async throws {
        let reply = await server().handle(Data("{not json".utf8))
        let object = try JSONSerialization.jsonObject(with: try #require(reply)) as? [String: Any]
        let error = try #require(object?["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32700)
    }
}
