import Foundation
import OffprintCore
import SwiftUI

/// One queued document.
@Observable
final class Job: Identifiable {
    enum Status: Equatable {
        case waiting
        case converting(page: Int, of: Int)
        case done
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let url: URL
    var status: Status = .waiting
    var document: OffprintDocument?
    /// Pages arrive as they finish, so the preview can fill in during a long run.
    var pages: [PageContent] = []

    init(url: URL) { self.url = url }

    var name: String { url.deletingPathExtension().lastPathComponent }

    var progress: Double? {
        guard case .converting(let page, let total) = status, total > 0 else {
            return status == .done ? 1 : nil
        }
        return Double(page) / Double(total)
    }

    var isFinished: Bool {
        switch status {
        case .done, .failed, .cancelled: return true
        default: return false
        }
    }
}

/// The app's single source of truth: what is queued, what tier to use, and what
/// has been produced.
@Observable
final class ConversionLibrary {
    var jobs: [Job] = []
    var selection: Job.ID?
    var tier: QualityTier = .fast
    var extractFigures = true
    var isRunning = false

    private var worker: Task<Void, Never>?
    private let engine = ConversionEngine()

    var selectedJob: Job? {
        jobs.first { $0.id == selection } ?? jobs.first { !$0.isFinished } ?? jobs.last
    }

    // MARK: - Queueing

    /// Accepts files and folders; folders contribute the PDFs directly inside them.
    func add(_ urls: [URL]) {
        let pdfs = urls.flatMap(Self.expand).filter { url in
            !jobs.contains { $0.url == url }
        }
        guard !pdfs.isEmpty else { return }
        jobs.append(contentsOf: pdfs.map(Job.init))
        if selection == nil { selection = jobs.first?.id }
        start()
    }

    static func expand(_ url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        // `URL.path()` percent-encodes by default, which FileManager will not match.
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            return url.pathExtension.lowercased() == "pdf" ? [url] : []
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func remove(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
        if selection == job.id { selection = jobs.first?.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.isFinished }
        if !jobs.contains(where: { $0.id == selection }) { selection = jobs.first?.id }
    }

    // MARK: - Running

    /// Converts queued documents one at a time.
    ///
    /// Sequential on purpose: the model tiers hold a multi-gigabyte model and read
    /// one page at a time, so running documents in parallel would multiply peak
    /// memory without finishing sooner.
    func start() {
        guard worker == nil else { return }
        isRunning = true
        worker = Task { [weak self] in
            while let job = self?.jobs.first(where: { $0.status == .waiting }) {
                await self?.run(job)
                if Task.isCancelled { break }
            }
            self?.worker = nil
            self?.isRunning = false
        }
    }

    func cancelAll() {
        worker?.cancel()
        worker = nil
        isRunning = false
        for job in jobs where !job.isFinished { job.status = .cancelled }
    }

    private func run(_ job: Job) async {
        // A dropped URL sits outside the sandbox container, so access has to be
        // claimed for the duration and released afterwards.
        let scoped = job.url.startAccessingSecurityScopedResource()
        defer { if scoped { job.url.stopAccessingSecurityScopedResource() } }

        job.status = .converting(page: 0, of: 0)
        job.pages = []

        let options = ConversionEngine.Options(
            tier: tier,
            extractFigures: extractFigures,
            appVersion: Bundle.main.appVersion
        )

        var total = 0
        for await event in await engine.convert(url: job.url, options: options) {
            if Task.isCancelled { job.status = .cancelled; return }
            switch event {
            case .started(let count):
                total = count
                job.status = .converting(page: 0, of: count)
            case .page(let page):
                job.pages.append(page)
                job.status = .converting(page: job.pages.count, of: total)
            case .finished(let document):
                job.document = document
                job.pages = document.pages
                job.status = .done
            case .failed(let error):
                job.status = .failed(error.localizedDescription)
            }
        }
    }
}

extension Bundle {
    var appVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
