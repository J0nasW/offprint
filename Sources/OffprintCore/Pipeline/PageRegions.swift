import CoreGraphics
import Foundation
import PDFKit

/// What kind of content a region holds, which decides how it is read.
public enum RegionKind: String, Sendable, Codable {
    case text
    case table
    case formula
    case figure
}

/// A region of a page, in reading order.
public struct PageRegion: Sendable, Hashable {
    public var kind: RegionKind
    public var bbox: BoundingBox
    /// Text already known for this region, when it came from the text layer.
    public var knownText: String?

    public init(kind: RegionKind, bbox: BoundingBox, knownText: String? = nil) {
        self.kind = kind
        self.bbox = bbox
        self.knownText = knownText
    }
}

/// Finds the regions of a page for an engine that reads them one at a time.
///
/// Document OCR models of this class are trained on regions, not pages: GLM-OCR
/// pairs a layout stage with "parallel recognition" of what that stage finds.
/// Handed a whole two-column page it recovers about a fifth of the text and
/// stops; handed the same page as eleven paragraph crops it recovers all of it.
/// So finding the regions is not an optimisation, it is the difference between
/// the model working and not.
public enum PageRegionFinder {

    /// Regions from the page's own text-layer geometry.
    ///
    /// Preferred when the page has a usable text layer: the boxes are exact
    /// rather than inferred, and it costs no render.
    public static func regions(fromTextLayerOf page: PDFPage,
                               displayBox: PDFDisplayBox = .cropBox) -> [PageRegion] {
        let layout = TextLayerGeometry.layout(of: page, displayBox: displayBox)
        guard !layout.lines.isEmpty else { return [] }

        let tables = TableDetector.detect(lines: layout.lines, glyphBoxes: layout.glyphBoxes)
        var consumed = Set<Int>()
        for table in tables { consumed.formUnion(table.lineIndices) }

        var keyed: [(line: Int, region: PageRegion)] = tables.map {
            ($0.lineIndices.lowerBound, PageRegion(kind: .table, bbox: $0.bbox))
        }

        let remaining = layout.lines.indices.filter { !consumed.contains($0) }
        let paragraphs = TextLayerGeometry.paragraphs(from: remaining.map { layout.lines[$0] })
        var cursor = 0
        for paragraph in paragraphs {
            let key = remaining.indices.contains(cursor) ? remaining[cursor] : layout.lines.count
            cursor += paragraph.lines.count
            let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            keyed.append((key, PageRegion(kind: .text, bbox: paragraph.bbox, knownText: text)))
        }

        return keyed
            .enumerated()
            .sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }
            .map(\.element.region)
    }

    /// Regions from Vision, for pages with no usable text layer.
    public static func regions(fromVisionOf blocks: [Block]) -> [PageRegion] {
        blocks.compactMap { block in
            guard let bbox = block.bbox else { return nil }
            switch block {
            case .table: return PageRegion(kind: .table, bbox: bbox)
            case .figure: return nil          // figures are cropped, not read
            case .formula: return PageRegion(kind: .formula, bbox: bbox)
            default: return PageRegion(kind: .text, bbox: bbox)
            }
        }
    }

    /// Merges regions that are too small to be worth a separate pass.
    ///
    /// Each region costs a full model invocation, so a page of one-line
    /// fragments would take minutes. Adjacent short regions in the same column
    /// are combined up to a size the model still handles reliably.
    public static func coalesce(_ regions: [PageRegion], pageWidth: Double,
                                maximumHeight: Double) -> [PageRegion] {
        var out: [PageRegion] = []
        for region in regions {
            guard region.kind == .text, var last = out.last, last.kind == .text else {
                out.append(region)
                continue
            }
            let merged = last.bbox.union(region.bbox)
            // Only merge within one column and while the result stays short
            // enough that the model still transcribes it completely.
            let sameColumn = abs(last.bbox.minX - region.bbox.minX) < pageWidth * 0.1
                && merged.width < max(last.bbox.width, region.bbox.width) * 1.2
            let gap = region.bbox.minY - last.bbox.maxY
            guard sameColumn, gap >= -2, gap < 24, merged.height <= maximumHeight else {
                out.append(region)
                continue
            }
            last.bbox = merged
            if let a = last.knownText, let b = region.knownText { last.knownText = a + "\n" + b }
            out[out.count - 1] = last
        }
        return out
    }
}
