import Foundation
import OffprintCore
import PDFKit

// A deliberately small CLI: its job is to make quality and speed measurable
// before any of those numbers get promised in the UI or on the landing page.

struct Arguments {
    var command = "convert"
    var paths: [URL] = []
    var tier: QualityTier = .fast
    var output: URL?
    var json = false
    var chunks = false
    var pageMarkers = false
    var noFigures = false
    var forceOCR = false
    var limit: Int?
}

func parse() -> Arguments {
    var a = Arguments()
    var rest = Array(CommandLine.arguments.dropFirst())
    if let first = rest.first, !first.hasPrefix("-") ,
       ["convert", "classify", "report", "lines"].contains(first) {
        a.command = first
        rest.removeFirst()
    }
    var i = 0
    while i < rest.count {
        let arg = rest[i]
        func value() -> String? { i + 1 < rest.count ? rest[i + 1] : nil }
        switch arg {
        case "--tier", "-t":
            if let v = value(), let t = QualityTier(rawValue: v) { a.tier = t; i += 1 }
        case "--out", "-o":
            if let v = value() { a.output = URL(filePath: v); i += 1 }
        case "--json": a.json = true
        case "--chunks": a.chunks = true
        case "--page-markers": a.pageMarkers = true
        case "--no-figures": a.noFigures = true
        case "--force-ocr": a.forceOCR = true
        case "--limit":
            if let v = value(), let n = Int(v) { a.limit = n; i += 1 }
        case "-h", "--help":
            print(usage); exit(0)
        default:
            a.paths.append(URL(filePath: arg))
        }
        i += 1
    }
    return a
}

let usage = """
offprint-harness — measure Offprint's extraction quality and speed

USAGE
  offprint-harness convert  <pdf|dir>...  [--tier fast|balanced|best] [--out DIR] [--json]
  offprint-harness classify <pdf|dir>...  Show the per-page routing decision
  offprint-harness report   <pdf|dir>...  Timing and block-count table
  offprint-harness lines    <pdf>         Dump text-layer line geometry (debugging)

OPTIONS
  -t, --tier      Quality tier (default: fast)
  -o, --out       Output directory (default: ./Fixtures/out)
      --json      Also write JSON alongside the Markdown
      --chunks    Also write <name>.chunks.jsonl for retrieval pipelines
      --page-markers   Emit <!-- page N --> comments
      --no-figures     Skip figure detection
      --force-ocr      Ignore the text layer; send every page to the OCR engine
      --limit N   Only process the first N pages of each document
"""

func collectPDFs(_ paths: [URL]) -> [URL] {
    var out: [URL] = []
    for path in paths {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path(percentEncoded: false),
                                            isDirectory: &isDirectory) else {
            FileHandle.standardError.write(Data("warning: no such path \(path.path(percentEncoded: false))\n".utf8))
            continue
        }
        if isDirectory.boolValue {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: path, includingPropertiesForKeys: nil)) ?? []
            out += contents.filter { $0.pathExtension.lowercased() == "pdf" }.sorted {
                $0.lastPathComponent < $1.lastPathComponent
            }
        } else if path.pathExtension.lowercased() == "pdf" {
            out.append(path)
        }
    }
    return out
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}
func padLeft(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : String(repeating: " ", count: n - s.count) + s
}

let args = parse()
let pdfs = collectPDFs(args.paths)

guard !pdfs.isEmpty else {
    print(usage)
    FileHandle.standardError.write(Data("\nerror: no PDFs found\n".utf8))
    exit(1)
}

switch args.command {

case "lines":
    for pdf in pdfs {
        guard let document = PDFDocument(url: pdf) else { continue }
        let count = min(document.pageCount, args.limit ?? 1)
        for i in 0..<count {
            guard let page = document.page(at: i) else { continue }
            let bounds = page.bounds(for: .cropBox)
            let ordered = TextLayerGeometry.lines(of: page)
            let raw = ordered
            let paragraphs = TextLayerGeometry.paragraphs(from: ordered)
            print("\n\(pdf.lastPathComponent) page \(i + 1) — "
                + "\(Int(bounds.width))×\(Int(bounds.height))pt, "
                + "\(raw.count) lines → \(paragraphs.count) paragraphs")
            let columns = Set(ordered.map(\.column)).sorted()
            print("  columns: \(columns.map { $0 < 0 ? "full" : String($0) }.joined(separator: ", "))")
            print("  " + pad("x", 6) + pad("y", 6) + pad("w", 6)
                + pad("pt", 6) + pad("bold", 6) + "text")
            for line in ordered {
                let x: String = pad(String(format: "%.0f", line.bbox.x), 6)
                let y: String = pad(String(format: "%.0f", line.bbox.y), 6)
                let w: String = pad(String(format: "%.0f", line.bbox.width), 6)
                let pt: String = pad(String(format: "%.1f", line.fontSize), 6)
                let bold: String = pad(line.isBold ? "yes" : "-", 6)
                let text: String = String(line.text.prefix(64))
                print("  " + x + y + w + pt + bold + text)
            }
        }
    }

case "classify":
    let classifier = PageClassifier()
    for pdf in pdfs {
        guard let document = PDFDocument(url: pdf) else {
            print("\(pdf.lastPathComponent): could not open"); continue
        }
        print("\n\(pdf.lastPathComponent) — \(document.pageCount) page(s)")
        print("  \(pad("page", 6))\(pad("route", 11))\(padLeft("chars/1k", 9))  \(pad("fonts", 6))\(pad("cols", 6))notes")
        let count = min(document.pageCount, args.limit ?? document.pageCount)
        for i in 0..<count {
            guard let page = document.page(at: i) else { continue }
            let c = classifier.classify(page)
            print("  \(pad(String(i + 1), 6))"
                + pad(c.route.rawValue, 11)
                + padLeft(String(format: "%.2f", c.characterDensity), 9) + "  "
                + pad(c.hasEmbeddedFonts ? "yes" : "no", 6)
                + pad(c.isMultiColumn ? "2+" : "1", 6)
                + c.reasons.joined(separator: "; "))
        }
    }

case "report":
    print(pad("document", 34) + padLeft("pages", 6) + padLeft("sec", 8)
        + padLeft("s/page", 8) + padLeft("blocks", 8) + padLeft("tables", 7) + padLeft("figs", 6))
    print(String(repeating: "─", count: 77))
    for pdf in pdfs {
        let engine = ConversionEngine()
        let options = ConversionEngine.Options(
            tier: args.tier, extractFigures: !args.noFigures, forceOCR: args.forceOCR,
            pageRange: args.limit.map { 0..<$0 })
        let clock = Date()
        do {
            let document = try await engine.document(for: pdf, options: options)
            let elapsed = Date().timeIntervalSince(clock)
            let blocks = document.allBlocks
            let tables = blocks.filter { $0.typeName == "table" }.count
            let figures = blocks.filter { $0.typeName == "figure" }.count
            print(pad(pdf.lastPathComponent, 34)
                + padLeft(String(document.pages.count), 6)
                + padLeft(String(format: "%.2f", elapsed), 8)
                + padLeft(String(format: "%.3f", elapsed / Double(max(1, document.pages.count))), 8)
                + padLeft(String(blocks.count), 8)
                + padLeft(String(tables), 7)
                + padLeft(String(figures), 6))
        } catch {
            print(pad(pdf.lastPathComponent, 34) + "  error: \(error.localizedDescription)")
        }
    }

default:  // convert
    let outputRoot = args.output ?? URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: "Fixtures/out")
    for pdf in pdfs {
        let engine = ConversionEngine()
        let options = ConversionEngine.Options(
            tier: args.tier, extractFigures: !args.noFigures, forceOCR: args.forceOCR,
            pageRange: args.limit.map { 0..<$0 })
        do {
            let clock = Date()
            let document = try await engine.document(for: pdf, options: options)
            let exporter = DocumentExporter(options: .init(
                writeJSON: args.json,
                writeChunks: args.chunks,
                writeFigures: !args.noFigures,
                markdown: .init(pageMarkers: args.pageMarkers)))
            let result = try exporter.export(document, source: pdf, to: outputRoot)
            let elapsed = Date().timeIntervalSince(clock)
            let engines = Set(document.pages.map(\.engine.rawValue)).sorted().joined(separator: "+")
            print("\(pdf.lastPathComponent): \(document.pages.count) page(s) in "
                + String(format: "%.2fs", elapsed)
                + " via \(engines) → \(result.markdownURL?.lastPathComponent ?? "—")"
                + (result.figureURLs.isEmpty ? "" : " (+\(result.figureURLs.count) figures)"))
        } catch {
            FileHandle.standardError.write(Data("\(pdf.lastPathComponent): \(error.localizedDescription)\n".utf8))
        }
    }
}
