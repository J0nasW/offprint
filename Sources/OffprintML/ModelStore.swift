import Foundation
import HuggingFace
import Metal
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import OffprintCore
// Required in this file specifically: the #hubDownloader and
// #huggingFaceTokenizerLoader macros expand into HubClient and
// Tokenizers.AutoTokenizer references at the call site.
import Tokenizers

/// A document model Offprint can run locally.
public nonisolated struct OCRModel: Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var approximateBytes: Int64
    public var summary: String

    /// GLM-OCR, 4-bit. The default: 0.9B parameters, MIT licensed, and top-three
    /// on OmniDocBench v1.6 — above Gemini 3 Pro — while fitting in 1.25 GB.
    /// Critically, it is also the only model in that class with a first-class
    /// Swift implementation in MLX, so Offprint needs no Python.
    public static let glmOCR4bit = OCRModel(
        id: "mlx-community/GLM-OCR-4bit",
        displayName: "GLM-OCR",
        approximateBytes: 1_250_000_000,
        summary: "Best balance of accuracy and size. Recommended.")

    /// The same model at 8-bit, for people who would rather spend the disk.
    public static let glmOCR8bit = OCRModel(
        id: "mlx-community/GLM-OCR-8bit",
        displayName: "GLM-OCR (8-bit)",
        approximateBytes: 1_590_000_000,
        summary: "Slightly more faithful on difficult scans. Larger and slower.")

    public static let all: [OCRModel] = [.glmOCR4bit, .glmOCR8bit]
}

public nonisolated enum ModelStoreError: Error, LocalizedError, Sendable {
    case notInstalled(OCRModel)
    case noMetalDevice

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let model):
            return "\(model.displayName) has not been downloaded yet."
        case .noMetalDevice:
            return "No Metal device is available, so models cannot run on this Mac."
        }
    }
}

/// Downloads, caches, and hands out loaded models.
public actor ModelStore {
    public static let shared = ModelStore()

    private var containers: [String: ModelContainer] = [:]
    private var loading: [String: Task<ModelContainer, Error>] = [:]

    private init() {}

    /// Weights live in Application Support, not the default `~/.cache`.
    ///
    /// A multi-gigabyte download hidden in a dot-directory is how an app earns
    /// support tickets. Here it is somewhere a person can find, and Settings can
    /// show its size and delete it.
    public nonisolated var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        return base.appending(path: "de.boostnow.Offprint/Models")
    }

    private nonisolated func prepareDirectory() throws {
        var url = directory
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Model weights are re-downloadable and enormous; they have no business
        // in Time Machine or iCloud.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Hugging Face's on-disk layout, which `HubCache` reproduces.
    private nonisolated func snapshotDirectory(for model: OCRModel) -> URL {
        directory.appending(path: "models--" + model.id.replacingOccurrences(of: "/", with: "--"))
    }

    public nonisolated func isInstalled(_ model: OCRModel) -> Bool {
        let snapshots = snapshotDirectory(for: model).appending(path: "snapshots")
        guard let revisions = try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil) else { return false }
        return revisions.contains { revision in
            let files = (try? FileManager.default.contentsOfDirectory(atPath: revision.path(percentEncoded: false))) ?? []
            return files.contains { $0.hasSuffix(".safetensors") }
                && files.contains("config.json")
        }
    }

    public nonisolated func installedBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    public func remove(_ model: OCRModel) throws {
        containers[model.id] = nil
        try? FileManager.default.removeItem(at: snapshotDirectory(for: model))
    }

    /// Loads a model, downloading it first if necessary.
    ///
    /// Concurrent callers share one load: a second page arriving mid-download
    /// must wait for the same task, not start a second multi-gigabyte transfer.
    public func container(
        for model: OCRModel,
        progress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws -> ModelContainer {
        if let container = containers[model.id] { return container }
        if let existing = loading[model.id] { return try await existing.value }

        let task = Task<ModelContainer, Error> { [directory] in
            // Guard the real failure mode: without a Metal device MLX silently
            // falls back to the CPU and runs at roughly half speed with no error.
            guard MTLCreateSystemDefaultDevice() != nil else {
                throw ModelStoreError.noMetalDevice
            }
            try prepareDirectory()

            // Bound the buffer cache: pages are converted one after another, and
            // an unbounded cache grows across a long document.
            MLX.Memory.cacheLimit = 64 * 1024 * 1024

            let client = HubClient(cache: HubCache(cacheDirectory: directory))
            return try await VLMModelFactory.shared.loadContainer(
                from: #hubDownloader(client),
                using: #huggingFaceTokenizerLoader(),
                configuration: ModelConfiguration(id: model.id)
            ) { hubProgress in
                progress(hubProgress.fractionCompleted)
            }
        }
        loading[model.id] = task

        do {
            let container = try await task.value
            containers[model.id] = container
            loading[model.id] = nil
            return container
        } catch {
            loading[model.id] = nil
            throw error
        }
    }

    /// Drops loaded weights but keeps the download.
    public func unload() {
        containers.removeAll()
        MLX.Memory.clearCache()
    }
}
