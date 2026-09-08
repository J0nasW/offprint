import OffprintCore
import SwiftUI

/// The bottom bar: the quality control, and what to do with the result.
struct ControlBar: View {
    @Environment(ConversionLibrary.self) private var library
    @State private var exporting = false
    @State private var exportError: String?

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            QualitySlider()
                .frame(width: 300)

            Divider().frame(height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(library.tier.displayName)
                    .font(.callout.weight(.medium))
                Text(Self.cost(of: library.tier))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if library.isRunning {
                Button("Stop") { library.cancelAll() }
            }

            if let job = library.selectedJob, job.document != nil {
                Button("Copy Markdown") { copyMarkdown(job) }
                Button("Save…") { export(job) }
                    .buttonStyle(.borderedProminent)
                    .disabled(exporting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .alert("Could not save", isPresented: .constant(exportError != nil)) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    /// The honest cost of each stop. These numbers come from the harness, not
    /// from guesses — which is also why they are worth showing.
    static func cost(of tier: QualityTier) -> String {
        switch tier {
        case .fast:
            return "≈0.1 s/page · no download"
        case .balanced:
            return "GLM-OCR · 1.25 GB download"
        case .best:
            return "GLM-OCR per region · 1.25 GB download"
        }
    }

    private func copyMarkdown(_ job: Job) {
        guard let document = job.document else { return }
        let markdown = MarkdownWriter().write(document)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    private func export(_ job: Job) {
        guard let document = job.document,
              let directory = FilePicker.chooseExportDirectory(named: job.name) else { return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                let exporter = DocumentExporter(options: .init(
                    writeJSON: true, writeFigures: library.extractFigures))
                let result = try exporter.export(document, source: job.url, to: directory)
                if let markdown = result.markdownURL {
                    NSWorkspace.shared.activateFileViewerSelecting([markdown])
                }
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

/// Three named stops rather than a continuous knob.
///
/// The stops differ in kind, not just degree — Fast needs no download, the other
/// two need 1.25 GB — and a continuous slider cannot say that. It still reads and
/// behaves like a slider, which is what makes the tradeoff feel adjustable.
struct QualitySlider: View {
    @Environment(ConversionLibrary.self) private var library

    var body: some View {
        @Bindable var library = library
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { Double(QualityTier.allCases.firstIndex(of: library.tier) ?? 0) },
                    set: { library.tier = QualityTier.allCases[Int($0.rounded())] }
                ),
                in: 0...Double(QualityTier.allCases.count - 1),
                step: 1
            ) {
                EmptyView()
            } minimumValueLabel: {
                Image(systemName: "hare").foregroundStyle(.secondary).font(.caption)
            } maximumValueLabel: {
                Image(systemName: "sparkles").foregroundStyle(.secondary).font(.caption)
            }
            .accessibilityLabel("Conversion quality")
            .accessibilityValue("\(library.tier.displayName), \(ControlBar.cost(of: library.tier))")

            HStack(spacing: 0) {
                ForEach(QualityTier.allCases, id: \.self) { tier in
                    Text(tier.displayName)
                        .font(.caption2)
                        .foregroundStyle(tier == library.tier ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 14)
            // The stop labels are decoration for sighted users; the slider itself
            // carries the value, so announcing them again just repeats it.
            .accessibilityHidden(true)
        }
    }
}
