import OffprintCore
import PDFKit
import SwiftUI

/// The result pane. Shows structure as structure, because that is the whole
/// point of the extraction — a wall of Markdown source would hide whether the
/// tables and headings actually came out right.
struct DocumentView: View {
    enum Mode: String, CaseIterable { case preview = "Preview", source = "Markdown" }

    let job: Job?
    @State private var mode: Mode = .preview

    var body: some View {
        Group {
            if let job {
                if job.pages.isEmpty {
                    placeholder(for: job)
                } else {
                    content(for: job)
                }
            } else {
                ContentUnavailableView("Nothing selected", systemImage: "doc.text")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func content(for job: Job) -> some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)

                Spacer()

                if case .converting(let page, let total) = job.status, total > 0 {
                    Text("Reading page \(page) of \(total)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                } else if let statistics = job.document?.statistics {
                    StatisticsBar(statistics: statistics)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                switch mode {
                case .preview:
                    BlockPreview(pages: job.pages, source: job.url)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 22)
                case .source:
                    Text(markdown(for: job))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }
        }
    }

    private func markdown(for job: Job) -> String {
        // Rendered from whatever has arrived so far, so a long document is
        // readable while the rest is still being converted.
        MarkdownWriter().write(blocks: job.pages.flatMap(\.blocks))
    }

    @ViewBuilder private func placeholder(for job: Job) -> some View {
        switch job.status {
        case .failed(let message):
            ContentUnavailableView {
                Label("Could not read this PDF", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        default:
            VStack(spacing: 10) {
                ProgressView()
                Text("Opening \(job.name)…").foregroundStyle(.secondary)
            }
        }
    }
}

/// The counts people actually need before feeding a document to a model.
struct StatisticsBar: View {
    let statistics: DocumentStatistics

    var body: some View {
        HStack(spacing: 12) {
            item("\(statistics.words.formatted()) words")
            item("\(statistics.characters.formatted()) chars")
            // Named an estimate because it is one: an exact count is exact for
            // exactly one tokenizer, and models disagree.
            item("~\(statistics.estimatedTokens.formatted()) tokens")
            if statistics.tables > 0 { item("\(statistics.tables) tables") }
            if statistics.uncertainTables > 0 {
                Label("\(statistics.uncertainTables) unverified",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .help("Token count is approximate: about one token per four Latin characters.")
    }

    private func item(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
}

/// Renders the extracted block tree directly, rather than round-tripping through
/// Markdown text.
struct BlockPreview: View {
    let pages: [PageContent]
    let source: URL

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(pages, id: \.index) { page in
                ForEach(Array(page.blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block, page: page.index)
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    @ViewBuilder private func view(for block: Block, page: Int) -> some View {
        switch block {
        case .heading(let heading):
            Text(heading.text)
                .font(.system(size: Self.size(forLevel: heading.level), weight: .semibold))
                .padding(.top, heading.level <= 2 ? 10 : 4)
                .textSelection(.enabled)

        case .paragraph(let paragraph):
            Text(paragraph.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .list(let list):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(list.ordered ? "\(index + 1)." : "•")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(item.text).textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }

        case .table(let table):
            TableBlockView(table: table)

        case .figure(let figure):
            FigureView(source: source, page: page, figure: figure)

        case .formula(let formula):
            Text(formula.latex)
                .font(.system(.body, design: .serif))
                .italic()
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))

        case .code(let code):
            Text(code.text)
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
        }
    }

    static func size(forLevel level: Int) -> CGFloat {
        switch level {
        case 1: return 26
        case 2: return 21
        case 3: return 18
        default: return 15
        }
    }
}

struct TableBlockView: View {
    let table: Block.Table

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if table.structureSuspect {
                // The dangerous failure is a table split down the wrong axis: it
                // still renders as a perfectly valid table, so nothing but an
                // explicit warning can tell the reader to go and check.
                Label("Table structure is uncertain — check it against the page",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            let grid = MarkdownWriter.flatten(table)
            VStack(spacing: 0) {
                ForEach(Array(grid.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell.replacingOccurrences(of: "<br>", with: "\n"))
                                .font(.callout)
                                .fontWeight(rowIndex == 0 ? .semibold : .regular)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                        }
                    }
                    .background(rowIndex == 0 ? AnyShapeStyle(.quaternary.opacity(0.5))
                                              : AnyShapeStyle(.clear))
                    Divider()
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary) }
        }
        .padding(.vertical, 4)
    }
}

/// Renders a detected figure straight from the PDF, so the preview shows the
/// actual crop that would be exported.
struct FigureView: View {
    let source: URL
    let page: Int
    let figure: Block.Figure

    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Group {
                if let image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary.opacity(0.4))
                        .frame(height: 120)
                        .overlay { ProgressView().controlSize(.small) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let caption = figure.caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: figure.path) { await load() }
    }

    private func load() async {
        guard let box = figure.bbox else { return }
        let url = source
        let index = page
        let rendered = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let document = PDFDocument(url: url),
                  let pdfPage = document.page(at: index) else { return nil }
            return try? PDFRenderer().render(pdfPage, crop: box, dpi: 144)
        }.value
        image = rendered
    }
}
