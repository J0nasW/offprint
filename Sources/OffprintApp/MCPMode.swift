import Foundation
import OffprintCore

/// Serves the Model Context Protocol over stdio.
///
///     "/Applications/Offprint PDF to Markdown.app/Contents/MacOS/offprint" --mcp
///
/// Lives inside the app rather than as a separate binary so it can reach the
/// model tiers, which need MLX and therefore the Metal toolchain the package
/// alone cannot build.
enum MCPMode {

    static var isRequested: Bool { CommandLine.arguments.contains("--mcp") }

    static func run() async -> Never {
        let version = Bundle.main.appVersion
        let service = DocumentService { url, tier in
            let engine = tier.requiresModel
                ? ConversionEngine(ocrEngine: GLMOCRExtractor())
                : ConversionEngine()
            return try await engine.document(for: url, options: .init(
                tier: tier, extractFigures: false, appVersion: version))
        }

        // Reading stdin blocks, so the loop runs off the main thread; stdout
        // carries the protocol and must stay clean.
        await MCPServer(service: service, version: version).run()
        exit(0)
    }
}
