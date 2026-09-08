import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import OffprintCore
import PDFKit

/// A bench for comparing OCR strategies on one page.
///
///     offprint --probe file.pdf --page 2
///
/// Exists because the model tiers can only be judged by running them: the
/// question "is this page failing because of resolution, or because a full
/// two-column page is out of distribution for a model trained on regions?" is
/// not answerable by reading code.
enum Probe {

    static var isRequested: Bool { CommandLine.arguments.contains("--probe") }

    static func run() async -> Never {
        var path: String?
        var pageIndex = 0
        var dpis: [Double] = [150]
        var arguments = Array(CommandLine.arguments.dropFirst())
        var index = 0
        while index < arguments.count {
            func value() -> String? { index + 1 < arguments.count ? arguments[index + 1] : nil }
            switch arguments[index] {
            case "--probe": if let v = value(), !v.hasPrefix("--") { path = v; index += 1 }
            case "--page": if let v = value(), let n = Int(v) { pageIndex = n - 1; index += 1 }
            case "--model":
                if let v = value() {
                    model = v.contains("8") ? .glmOCR8bit : .glmOCR4bit
                    index += 1
                }
            case "--region":
                if let v = value() {
                    let parts = v.split(separator: ",").compactMap { Double($0) }
                    if parts.count == 4 {
                        region = BoundingBox(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                    }
                    index += 1
                }
            case "--penalty":
                if let v = value(), let p = Float(v) { penalty = p; index += 1 }
            case "--dpi":
                if let v = value() { dpis = v.split(separator: ",").compactMap { Double($0) }; index += 1 }
            default: break
            }
            index += 1
        }

        guard let path, let document = PDFDocument(url: URL(filePath: path)),
              let page = document.page(at: pageIndex) else {
            FileHandle.standardError.write(Data("usage: offprint --probe file.pdf --page N [--dpi 150,220]\n".utf8))
            exit(2)
        }

        let bounds = page.bounds(for: .cropBox)
        let pageSize = bounds.size
        print("page \(pageIndex + 1) of \(document.pageCount) — \(Int(pageSize.width))×\(Int(pageSize.height))pt")

        // Ground truth from the text layer, for comparison.
        let reference = TextLayerExtractor().extract(page: page, pageIndex: pageIndex)
        let referenceWords = reference.content.blocks
            .map(\.plainText).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).count
        print("text layer: \(referenceWords) words, \(reference.content.blocks.count) blocks\n")

        print("model: \(model.displayName)")
        print("── region size sweep ──")

        for dpi in dpis {
            let renderer = PDFRenderer(dpi: dpi)
            // A single-region run isolates whether the model reads accurately at
            // all, separately from whether it sustains a long transcription.
            if let region {
                guard let cropped = try? renderer.render(page, crop: region, dpi: dpi) else { continue }
                save(cropped, named: "probe-region.png")
                let result = await transcribe(image: cropped, pageSize: pageSize, pageIndex: pageIndex)
                print("── region @ \(Int(dpi)) dpi (\(cropped.width)×\(cropped.height)px) ──")
                print("   \(words(result.raw)) words")
                print("   \(result.raw.prefix(600))\n")
                continue
            }
            // How large can a region get before the model starts dropping text?
            // Each region costs a full invocation, so the answer sets the speed
            // of the whole tier.
            let base = PageRegionFinder.regions(fromTextLayerOf: page)
            if !base.isEmpty {
                for height in [180.0, 300.0, 450.0, 700.0] {
                    let regions = PageRegionFinder.coalesce(base, pageWidth: Double(pageSize.width),
                                                            maximumHeight: height)
                    let clock = Date()
                    var transcribed = 0
                    for region in regions {
                        let crop = region.bbox.inset(by: -6)
                        guard let cropped = try? renderer.render(page, crop: crop, dpi: dpi) else { continue }
                        let result = await transcribe(image: cropped, pageSize: pageSize, pageIndex: pageIndex)
                        transcribed += words(result.raw)
                    }
                    let elapsed = Date().timeIntervalSince(clock)
                    print(String(format: "   maxHeight %4.0fpt → %2d regions, %5d words (%3.0f%%) in %5.1fs",
                                 height, regions.count, transcribed,
                                 Double(transcribed) / Double(max(1, referenceWords)) * 100, elapsed))
                }
                print("")
            }

            guard false, let image = try? renderer.render(page) else { continue }
            print("── full page @ \(Int(dpi)) dpi (\(image.width)×\(image.height)px) ──")
            await report(image: image, pageSize: pageSize, pageIndex: pageIndex,
                         reference: referenceWords)

            let columnLayout = TextLayerGeometry.layout(of: page)
            let columns = Set(columnLayout.lines.map { $0.column }).filter { $0 >= 0 }
            guard columns.count > 1 else { continue }

            print("── per column @ \(Int(dpi)) dpi ──")
            let clock = Date()
            var total = 0
            for column in columns.sorted() {
                let boxes = columnLayout.lines.filter { $0.column == column }.map { $0.bbox }
                guard let first = boxes.first else { continue }
                var crop = boxes.dropFirst().reduce(first) { $0.union($1) }
                crop = crop.inset(by: -8)
                guard let cropped = try? renderer.render(page, crop: crop, dpi: dpi) else { continue }
                save(cropped, named: "probe-col\(column).png")
                let result = await transcribe(image: cropped, pageSize: pageSize, pageIndex: pageIndex)
                total += words(result.parsed)
                print("   column \(column): \(cropped.width)×\(cropped.height)px → "
                    + "raw \(words(result.raw)) words, parsed \(words(result.parsed)) words")
                print("      raw head: \(result.raw.prefix(160).replacingOccurrences(of: "\n", with: "⏎"))")
            }
            let elapsed = Date().timeIntervalSince(clock)
            print(String(format: "   total %d words (%.0f%% of text layer) in %.1fs\n",
                         total, Double(total) / Double(max(1, referenceWords)) * 100, elapsed))
        }
        exit(0)
    }

    static func report(image: CGImage, pageSize: CGSize, pageIndex: Int, reference: Int) async {
        let clock = Date()
        let result = await transcribe(image: image, pageSize: pageSize, pageIndex: pageIndex)
        print(String(format: "   raw %d words, parsed %d words (%.0f%% of text layer) in %.1fs",
                     words(result.raw), words(result.parsed),
                     Double(words(result.parsed)) / Double(max(1, reference)) * 100,
                     Date().timeIntervalSince(clock)))
        print("   raw head: \(result.raw.prefix(200).replacingOccurrences(of: "\n", with: "⏎"))")
        print("   raw tail: \(result.raw.suffix(120).replacingOccurrences(of: "\n", with: "⏎"))\n")
    }

    nonisolated(unsafe) static var penalty: Float?
    nonisolated(unsafe) static var model: OCRModel = .glmOCR4bit
    /// Optional sub-region of the page, in points, to isolate a single paragraph.
    nonisolated(unsafe) static var region: BoundingBox?

    /// Writes a crop next to the PDF so the input can be inspected directly.
    static func save(_ image: CGImage, named name: String) {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: name)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        print("      wrote \(url.path(percentEncoded: false))")
    }

    /// Returns the model's raw output, and what survives parsing.
    static func transcribe(image: CGImage, pageSize: CGSize, pageIndex: Int)
        async -> (raw: String, parsed: String) {
        let extractor = GLMOCRExtractor(model: model, repetitionPenalty: penalty)
        guard let raw = try? await extractor.transcribe(image: image) else { return ("", "") }
        let blocks = MarkdownParser().parse(GLMOCRExtractor.clean(raw))
        return (raw, blocks.map(\.plainText).joined(separator: "\n"))
    }

    static func words(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
