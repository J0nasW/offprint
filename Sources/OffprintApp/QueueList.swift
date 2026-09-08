import OffprintCore
import SwiftUI

struct QueueList: View {
    @Environment(ConversionLibrary.self) private var library

    var body: some View {
        @Bindable var library = library
        List(selection: $library.selection) {
            ForEach(library.jobs) { job in
                JobRow(job: job)
                    .tag(job.id)
                    .contextMenu {
                        Button("Remove") { library.remove(job) }
                        Button("Show Original in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([job.url])
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if library.jobs.contains(where: \.isFinished) {
                Button("Clear Finished") { library.clearFinished() }
                    .buttonStyle(.link)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }
}

/// One row per document. The row *is* the progress indicator — no modal, no
/// separate screen, the way a Mac file utility has always worked.
struct JobRow: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                statusIcon
                Text(job.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let progress = job.progress, !job.isFinished {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.status {
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.tertiary)
        case .converting:
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        switch job.status {
        case .waiting:
            return "Waiting"
        case .converting(let page, let total):
            return total > 0 ? "Page \(max(page, 1)) of \(total)" : "Reading…"
        case .done:
            let blocks = job.pages.reduce(0) { $0 + $1.blocks.count }
            let engines = Set(job.pages.map(\.engine))
            return "\(job.pages.count) pages · \(blocks) blocks · \(Self.describe(engines))"
        case .failed(let message):
            return message
        case .cancelled:
            return "Cancelled"
        }
    }

    /// Names the engines that actually ran, since pages route independently.
    static func describe(_ engines: Set<EngineID>) -> String {
        let names = engines.sorted { $0.rawValue < $1.rawValue }.map { engine -> String in
            switch engine {
            case .textLayer: return "text layer"
            case .vision: return "Vision"
            case .glmOCR, .glmOCRLayout: return "GLM-OCR"
            }
        }
        return names.joined(separator: " + ")
    }
}
