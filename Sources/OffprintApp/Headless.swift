import Foundation
import OffprintCore

/// Runs a conversion without showing the UI.
///
/// `Offprint.app/Contents/MacOS/Offprint --convert file.pdf --tier balanced`
///
/// This exists so the model tiers can be exercised and measured — they live in
/// the app target, not the package, because MLX needs the Metal toolchain that
/// SwiftPM's command line cannot drive — and it doubles as the scripting entry
/// point for automating conversions.
/// Throttles download progress to whole steps, safely across contexts.
private nonisolated final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1

    func report(_ fraction: Double) {
        let percent = Int(fraction * 100)
        lock.lock()
        defer { lock.unlock() }
        guard percent >= lastPercent + 5 else { return }
        lastPercent = percent
        FileHandle.standardError.write(Data("  downloading \(percent)%\n".utf8))
    }
}

enum Headless {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--convert")
    }

    static func run() async -> Never {
        var inputs: [URL] = []
        var tier = QualityTier.fast
        var output = URL(filePath: FileManager.default.currentDirectoryPath)
        var json = false
        var figures = true
        var limit: Int?

        var arguments = Array(CommandLine.arguments.dropFirst())
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value() -> String? { index + 1 < arguments.count ? arguments[index + 1] : nil }
            switch argument {
            case "--convert":
                while let next = value(), !next.hasPrefix("--") {
                    inputs.append(URL(filePath: next))
                    index += 1
                }
            case "--tier":
                if let raw = value(), let parsed = QualityTier(rawValue: raw) { tier = parsed; index += 1 }
            case "--out":
                if let path = value() { output = URL(filePath: path); index += 1 }
            case "--limit":
                if let raw = value(), let count = Int(raw) { limit = count; index += 1 }
            case "--json": json = true
            case "--no-figures": figures = false
            default: break
            }
            index += 1
        }

        guard !inputs.isEmpty else {
            FileHandle.standardError.write(Data("usage: Offprint --convert <pdf>… [--tier fast|balanced|best] [--out DIR] [--json]\n".utf8))
            exit(2)
        }

        for input in inputs {
            do {
                if tier.requiresModel {
                    // The progress handler is called from the downloader's own
                    // context, so the throttle state has to be shared safely.
                    let reporter = ProgressReporter()
                    _ = try await ModelStore.shared.container(for: .glmOCR4bit) { fraction in
                        reporter.report(fraction)
                    }
                }

                let engine = tier.requiresModel
                    ? ConversionEngine(ocrEngine: GLMOCRExtractor())
                    : ConversionEngine()
                let started = Date()
                let document = try await engine.document(for: input, options: .init(
                    tier: tier, extractFigures: figures,
                    appVersion: Bundle.main.appVersion,
                    pageRange: limit.map { 0..<$0 }))
                let elapsed = Date().timeIntervalSince(started)

                let exporter = DocumentExporter(options: .init(writeJSON: json, writeFigures: figures))
                let result = try exporter.export(document, source: input, to: output)

                let blocks = document.allBlocks
                let tables = blocks.filter { $0.typeName == "table" }.count
                print("\(input.lastPathComponent): \(document.pages.count) pages in "
                    + String(format: "%.2fs (%.3f s/page)", elapsed,
                             elapsed / Double(max(1, document.pages.count)))
                    + " · \(blocks.count) blocks, \(tables) tables"
                    + " → \(result.markdownURL?.lastPathComponent ?? "—")")
            } catch {
                FileHandle.standardError.write(
                    Data("\(input.lastPathComponent): \(error.localizedDescription)\n".utf8))
            }
        }
        exit(0)
    }
}
