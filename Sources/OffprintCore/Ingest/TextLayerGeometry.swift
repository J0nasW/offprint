import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// Recovers line and paragraph geometry from a PDF's embedded text layer.
///
/// `PDFPage.string` cannot be trusted for ordering: it returns characters in
/// content-stream order, which on a two-column page interleaves the columns —
/// producing fluent-looking text that says something the document never said.
/// So the string is used only for the characters themselves; every ordering
/// decision here is made from `characterBounds` geometry.
public enum TextLayerGeometry {

    public struct Line: Sendable {
        public var text: String
        public var bbox: BoundingBox
        /// Index of the column this line belongs to, left to right.
        public var column: Int
        /// Whether the line is set in a bold face.
        ///
        /// In academic typography a section heading is often the same size as the
        /// body and distinguished only by weight, so size alone misses them.
        public var isBold: Bool
        /// Estimated type size, taken from the tallest glyph on the line.
        ///
        /// The row's box height is not usable for this: a line with no ascenders
        /// or descenders is visibly shorter than its neighbours in the same font,
        /// which reads as a size change and splits paragraphs mid-sentence.
        public var fontSize: Double
        /// Runs of text on this line separated by gaps too wide to be word
        /// spaces. On a table row these are the cells; on ordinary prose there
        /// is exactly one.
        public var segments: [Segment]

        public init(text: String, bbox: BoundingBox, column: Int = 0,
                    fontSize: Double? = nil, isBold: Bool = false,
                    segments: [Segment] = []) {
            self.text = text
            self.bbox = bbox
            self.column = column
            self.fontSize = fontSize ?? bbox.height
            self.isBold = isBold
            self.segments = segments
        }
    }

    public struct Segment: Sendable, Hashable {
        public var text: String
        public var bbox: BoundingBox
        public init(text: String, bbox: BoundingBox) {
            self.text = text
            self.bbox = bbox
        }
    }

    public struct Paragraph: Sendable {
        public var lines: [Line]
        public var bbox: BoundingBox
        public var text: String {
            // Re-join words hyphenated across a line break; leaving them produces
            // "under-\nstand" in the Markdown, which is worse than wrong.
            var out = ""
            for (i, line) in lines.enumerated() {
                let t = line.text
                if i == 0 { out = t; continue }
                if out.hasSuffix("-"), let previous = out.dropLast().last, previous.isLetter,
                   let next = t.first, next.isLowercase {
                    out.removeLast()
                    out += t
                } else {
                    out += " " + t
                }
            }
            return out
        }
        public init(lines: [Line], bbox: BoundingBox) {
            self.lines = lines
            self.bbox = bbox
        }
    }

    /// A single positioned glyph box.
    ///
    /// Deliberately carries no character: `PDFPage.characterBounds(at:)` and
    /// `PDFPage.string` do not share an index space — the association drifts by a
    /// couple of characters per line, which silently truncates every line and
    /// prepends the lost letters to the next one. Only the geometry is taken
    /// from here; the text of each row is read back with `selection(for:)`.
    struct Glyph {
        var box: BoundingBox
    }

    /// Lines plus the glyph geometry behind them.
    ///
    /// Table detection needs raw glyph positions, not the merged segments: the
    /// gaps between a table's numeric columns are often narrower than the
    /// threshold that splits segments, so they are invisible once glyphs have
    /// been merged.
    public struct PageLayout: Sendable {
        public var lines: [Line]
        /// Glyph boxes for each line, in the same order as `lines`.
        public var glyphBoxes: [[BoundingBox]]
        public init(lines: [Line], glyphBoxes: [[BoundingBox]]) {
            self.lines = lines
            self.glyphBoxes = glyphBoxes
        }
    }

    public static func lines(of page: PDFPage, displayBox: PDFDisplayBox = .cropBox) -> [Line] {
        layout(of: page, displayBox: displayBox).lines
    }

    /// Extracts lines in reading order, with top-left-origin page-point geometry.
    public static func layout(of page: PDFPage, displayBox: PDFDisplayBox = .cropBox) -> PageLayout {
        let bounds = page.bounds(for: displayBox)
        let glyphs = self.glyphs(of: page, bounds: bounds)
        guard !glyphs.isEmpty else { return PageLayout(lines: [], glyphBoxes: []) }

        let ordered = arrange(glyphs, pageWidth: Double(bounds.width),
                              pageHeight: Double(bounds.height))
        var lines: [Line] = []
        var boxes: [[BoundingBox]] = []
        for row in ordered {
            let read = self.read(in: row.box, of: page, bounds: bounds)
            guard !read.text.isEmpty else { continue }
            let size = read.fontSize ?? row.fontSize
            let splits = segmentBoxes(of: row.glyphs, fontSize: size)
            // Only worth reading segments separately when the line actually
            // splits; prose is one segment and would just cost a selection call.
            let segments: [Segment] = splits.count > 1
                ? splits.compactMap { box in
                    let text = self.read(in: box, of: page, bounds: bounds).text
                    return text.isEmpty ? nil : Segment(text: text, bbox: box)
                }
                : [Segment(text: read.text, bbox: row.box)]
            lines.append(Line(text: read.text, bbox: row.box, column: row.column,
                              fontSize: size, isBold: read.isBold, segments: segments))
            boxes.append(row.glyphs.map { $0.box })
        }
        return PageLayout(lines: lines, glyphBoxes: boxes)
    }

    static func glyphs(of page: PDFPage, bounds: CGRect) -> [Glyph] {
        let count = page.numberOfCharacters
        guard count > 0 else { return [] }

        var glyphs: [Glyph] = []
        glyphs.reserveCapacity(count)
        for i in 0..<count {
            let raw = page.characterBounds(at: i)
            guard !raw.isNull, raw.width.isFinite, raw.height.isFinite,
                  raw.height > 0.5, raw.width >= 0,
                  raw.width < bounds.width else { continue }
            // Flip from PDF's bottom-left origin to Offprint's top-left origin.
            let box = BoundingBox(
                x: Double(raw.origin.x - bounds.origin.x),
                y: Double(bounds.height) - Double(raw.origin.y - bounds.origin.y) - Double(raw.height),
                width: Double(raw.width),
                height: Double(raw.height)
            )
            // Some documents draw past the paper and rely on clipping to hide
            // it. Those glyphs are invisible, but their coordinates are not:
            // they drag a block's box off the page, which then breaks reading
            // order, figure crops and the boxes in the JSON export.
            let visible = box.clamped(to: bounds.size)
            guard visible.width > 0, visible.height > 0 else { continue }
            glyphs.append(Glyph(box: visible))
        }
        return glyphs
    }

    /// Reads just the text inside a rectangle. Used for table cells, where the
    /// type size is not needed.
    public static func text(in box: BoundingBox, of page: PDFPage, bounds: CGRect) -> String {
        read(in: box, of: page, bounds: bounds).text
    }

    /// Reads the text PDFKit places inside a rectangle, and the type size it is set in.
    ///
    /// The point size comes from the selection's own font attributes. Estimating
    /// it from glyph geometry does not work: a row's height depends on whether it
    /// happens to contain an ascender or a descender, so ordinary body lines vary
    /// by ~35% and half of them get promoted to headings.
    static func read(in box: BoundingBox, of page: PDFPage, bounds: CGRect)
        -> (text: String, fontSize: Double?, isBold: Bool) {
        let rect = CGRect(
            x: bounds.origin.x + box.x,
            y: bounds.origin.y + (Double(bounds.height) - box.maxY),
            width: box.width,
            height: box.height
        )
        guard let selection = page.selection(for: rect), let raw = selection.string else {
            return ("", nil, false)
        }
        // A row rect can clip the line above or below; fold any stray line breaks
        // into spaces and collapse the result.
        let text = raw
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Largest run wins: a heading is uniformly larger, while a body line that
        // contains a superscript should not be dragged down by it.
        var size: Double?
        var boldLength = 0
        var totalLength = 0
        let attributed = selection.attributedString
        if let attributed, attributed.length > 0 {
            attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                guard let font = value as? NSFont else { return }
                size = max(size ?? 0, Double(font.pointSize))
                totalLength += range.length
                if Self.isBoldFont(font) { boldLength += range.length }
            }
        }
        // Most of the line must be bold, so an inline bold term does not turn a
        // body paragraph into a heading.
        let isBold = totalLength > 0 && Double(boldLength) / Double(totalLength) > 0.8
        return (text, size, isBold)
    }

    /// An ordered row of the page, before its text is read back.
    struct Row {
        var box: BoundingBox
        /// Column index, or -1 for a line that spans the full page width.
        var column: Int
        var fontSize: Double
        var glyphs: [Glyph]
    }

    /// Turns loose glyph boxes into ordered rows, handling multi-column layouts.
    ///
    /// A paper's title spans both columns while its abstract does not, so this
    /// cannot simply split the page down the middle: full-width lines are kept
    /// whole and act as section breaks, and within each section the left column
    /// is read before the right.
    static func arrange(_ glyphs: [Glyph], pageWidth: Double, pageHeight: Double) -> [Row] {
        let median = medianHeight(glyphs.map(\.box))

        guard let gutter = columnGutter(glyphs, pageWidth: pageWidth, pageHeight: pageHeight) else {
            return rows(of: glyphs, median: median).map { Row(box: box(of: $0), column: 0, fontSize: fontSize(of: $0), glyphs: $0) }
        }

        // Classify each row as full-width or column content.
        //
        // Neither "a glyph straddles the gutter" nor "the row puts ink near the
        // gutter" works. The first misses a full-width title whose word space
        // happens to fall on the gutter, cutting the title in half; the second
        // welds two column lines together whenever their inner ends sit close to
        // it. What actually distinguishes them is *continuity*: a full-width line
        // runs across the gutter with only word spaces, while two column lines
        // are separated by the whole gutter.
        var fullWidth: [Glyph] = []
        var columnar: [Glyph] = []
        let minimumSeparation = max(6.0, gutter.halfWidth)
        for row in rows(of: glyphs, median: median) {
            if isContinuous(row, across: gutter.center, minimumGap: minimumSeparation) {
                fullWidth += row
            } else {
                columnar += row
            }
        }

        // Columns are re-clustered independently, so a tall left-column line can
        // never chain through the right column into the line below it.
        let leftRows  = rows(of: columnar.filter { $0.box.midX <  gutter.center }, median: median)
            .map { Row(box: box(of: $0), column: 0, fontSize: fontSize(of: $0), glyphs: $0) }
        let rightRows = rows(of: columnar.filter { $0.box.midX >= gutter.center }, median: median)
            .map { Row(box: box(of: $0), column: 1, fontSize: fontSize(of: $0), glyphs: $0) }
        let fullRows  = rows(of: fullWidth, median: median)
            .map { Row(box: box(of: $0), column: -1, fontSize: fontSize(of: $0), glyphs: $0) }
            .sorted { $0.box.minY < $1.box.minY }

        // Emit section by section.
        var out: [Row] = []
        var boundaries = fullRows.map(\.box.minY)
        boundaries.append(.greatestFiniteMagnitude)
        var previous = -Double.greatestFiniteMagnitude

        for (index, boundary) in boundaries.enumerated() {
            // Column content comes first: a full-width line closes the section
            // above it, it does not open the one below.
            let inSection: (Row) -> Bool = { $0.box.midY > previous && $0.box.midY < boundary }
            out += leftRows.filter(inSection)
            out += rightRows.filter(inSection)
            if index < fullRows.count { out.append(fullRows[index]) }
            previous = boundary
        }
        return out
    }

    /// Whether a row's text runs continuously across `x`, rather than stopping
    /// on one side and resuming on the other.
    static func isContinuous(_ row: [Glyph], across x: Double, minimumGap: Double) -> Bool {
        let left = row.filter { $0.box.midX < x }
        let right = row.filter { $0.box.midX >= x }
        guard !left.isEmpty, !right.isEmpty else { return false }

        // The gap that actually straddles x is the one that matters.
        let innerLeft = left.map(\.box.maxX).max() ?? 0
        let innerRight = right.map(\.box.minX).min() ?? 0
        return (innerRight - innerLeft) < minimumGap
    }

    /// Finds a vertical gutter by projecting glyph coverage onto the x axis.
    ///
    /// Counting *strips of page height* rather than raw glyph crossings is what
    /// lets a full-width title coexist with a two-column body: the title crosses
    /// the gutter, but only over a few percent of the page's height.
    struct Gutter {
        var center: Double
        /// Half the width of the empty band, used to decide whether a row's text
        /// runs continuously through the gutter.
        var halfWidth: Double
    }

    static func columnGutter(_ glyphs: [Glyph], pageWidth: Double, pageHeight: Double) -> Gutter? {
        guard glyphs.count >= 200, pageWidth > 0, pageHeight > 0 else { return nil }

        let stripCount = 120
        let stripHeight = pageHeight / Double(stripCount)
        let samples = 200
        var crossings = [Int](repeating: 0, count: samples)   // strips crossed, per x
        var occupied = [Bool](repeating: false, count: stripCount)

        // For each sampled x, which horizontal strips contain a glyph covering it.
        var perX = [[Bool]](repeating: [Bool](repeating: false, count: stripCount), count: samples)
        for glyph in glyphs {
            let s0 = max(0, min(stripCount - 1, Int(glyph.box.minY / stripHeight)))
            let s1 = max(0, min(stripCount - 1, Int(glyph.box.maxY / stripHeight)))
            for s in s0...s1 { occupied[s] = true }

            let x0 = Int((glyph.box.minX / pageWidth) * Double(samples))
            let x1 = Int((glyph.box.maxX / pageWidth) * Double(samples))
            guard x1 >= 0, x0 < samples else { continue }
            for xi in max(0, x0)...min(samples - 1, x1) {
                for s in s0...s1 where !perX[xi][s] {
                    perX[xi][s] = true
                    crossings[xi] += 1
                }
            }
        }

        let textStrips = occupied.filter { $0 }.count
        guard textStrips >= 20 else { return nil }

        // Search the middle half of the page for the emptiest column of x.
        let lower = samples / 4, upper = (samples * 3) / 4
        var best: (index: Int, crossings: Int)?
        for xi in lower...upper where best == nil || crossings[xi] < best!.crossings {
            best = (xi, crossings[xi])
        }
        guard let found = best else { return nil }
        // A single-column page has text crossing its midline on essentially every
        // occupied strip (~95%); a two-column page crosses the gutter only where
        // a full-width element sits. Those elements can be large — a page with
        // two wide results tables plus a title crosses on half its height — so
        // the threshold has to be generous. It can afford to be: the gap between
        // "about half" and "essentially all" is still wide.
        guard Double(found.crossings) < Double(textStrips) * 0.55 else { return nil }

        // Measure how wide the genuinely empty band is by walking outwards only
        // while coverage stays at the minimum. Using the acceptance threshold
        // here instead would walk deep into the text on either side and report a
        // gutter several times its real width — which then makes two column lines
        // look like one continuous full-width line.
        let ceiling = found.crossings + 1
        var lo = found.index, hi = found.index
        while lo > 0, crossings[lo - 1] < ceiling { lo -= 1 }
        while hi < samples - 1, crossings[hi + 1] < ceiling { hi += 1 }

        let unit = pageWidth / Double(samples)
        let center = (Double(lo + hi) / 2 + 0.5) * unit
        let halfWidth = max(unit, Double(hi - lo + 1) * unit / 2)

        // Both sides must actually hold content.
        let leftCount = glyphs.filter { $0.box.midX < center }.count
        guard leftCount > glyphs.count / 8, leftCount < glyphs.count * 7 / 8 else { return nil }
        return Gutter(center: center, halfWidth: halfWidth)
    }

    /// Clusters glyphs into rows by vertical overlap.
    ///
    /// Overlap rather than baseline distance: a comma and a capital sit on the
    /// same line but have very different box centres and bottoms.
    static func rows(of glyphs: [Glyph], median: Double) -> [[Glyph]] {
        guard !glyphs.isEmpty else { return [] }
        let sorted = glyphs.sorted {
            $0.box.minY == $1.box.minY ? $0.box.minX < $1.box.minX : $0.box.minY < $1.box.minY
        }

        var out: [[Glyph]] = []
        var current: [Glyph] = [sorted[0]]
        var box = sorted[0].box

        for glyph in sorted.dropFirst() {
            let overlap = min(glyph.box.maxY, box.maxY) - max(glyph.box.minY, box.minY)
            if overlap > glyph.box.height * 0.45 {
                current.append(glyph)
                box = box.union(glyph.box)
            } else {
                out.append(current)
                current = [glyph]
                box = glyph.box
            }
        }
        out.append(current)
        return out
    }

    /// Splits a row wherever the gap between glyphs is too wide to be a word space.
    ///
    /// A word space runs about a quarter of the type size; anything past ~1.2x is
    /// a deliberate horizontal separation. Table columns are *not* found this
    /// way — a dense results table sets its numeric columns barely wider than a
    /// space — they come from vertical whitespace corridors instead.
    static func segmentBoxes(of glyphs: [Glyph], fontSize: Double) -> [BoundingBox] {
        guard !glyphs.isEmpty, fontSize > 0 else { return [] }
        let ordered = glyphs.sorted { $0.box.minX < $1.box.minX }
        let minimumGap = fontSize * 1.2

        var out: [BoundingBox] = []
        var current = ordered[0].box
        for glyph in ordered.dropFirst() {
            if glyph.box.minX - current.maxX > minimumGap {
                out.append(current)
                current = glyph.box
            } else {
                current = current.union(glyph.box)
            }
        }
        out.append(current)
        return out
    }

    /// Whether a font is bold.
    ///
    /// Embedded Type 1 and CID fonts frequently ship a descriptor with no
    /// symbolic traits set, so the PostScript name has to be consulted too —
    /// `NimbusRomNo9L-Medi` and friends are bold in every way except the flag.
    static func isBoldFont(_ font: NSFont) -> Bool {
        if font.fontDescriptor.symbolicTraits.contains(.bold) { return true }
        let name = font.fontName.lowercased()
        return ["bold", "-bd", "semibold", "black", "heavy", "-medi", "demi"]
            .contains { name.contains($0) }
    }

    /// The bounding box of a clustered row.
    static func box(of row: [Glyph]) -> BoundingBox {
        row.dropFirst().reduce(row[0].box) { $0.union($1.box) }
    }

    /// Type size of a row, estimated from its tallest glyph.
    static func fontSize(of row: [Glyph]) -> Double {
        row.map(\.box.height).max() ?? 0
    }

    static func medianHeight(_ boxes: [BoundingBox]) -> Double {
        let heights = boxes.map(\.height).filter { $0 > 0 }.sorted()
        guard !heights.isEmpty else { return 10 }
        return heights[heights.count / 2]
    }

    /// Groups lines into paragraphs on vertical gaps, indentation, and column breaks.
    public static func paragraphs(from lines: [Line]) -> [Paragraph] {
        guard !lines.isEmpty else { return [] }
        let sizes = lines.map(\.fontSize).filter { $0 > 0 }.sorted()
        let median = sizes.isEmpty ? medianHeight(lines.map(\.bbox)) : sizes[sizes.count / 2]

        // Widest line in each column, which is what a full measure looks like.
        var columnWidth: [Int: Double] = [:]
        for line in lines {
            columnWidth[line.column] = max(columnWidth[line.column] ?? 0, line.bbox.width)
        }

        var paragraphs: [Paragraph] = []
        var current: [Line] = []

        func flush() {
            guard !current.isEmpty else { return }
            let box = current.dropFirst().reduce(current[0].bbox) { $0.union($1.bbox) }
            paragraphs.append(Paragraph(lines: current, bbox: box))
            current = []
        }

        for line in lines {
            guard let previous = current.last else { current = [line]; continue }
            let gap = line.bbox.minY - previous.bbox.maxY
            let bigGap = gap > median * 0.75
            let columnBreak = line.column != previous.column
            // A first-line indent starts a paragraph only in body text. Above
            // body size the offset is centring or a hanging indent, and treating
            // it as a break splits a two-line heading in half — "5 Evaluating
            // Semantic Embedding" from "Capabilities".
            let isBodySized = line.fontSize <= median * 1.05
            let indented = isBodySized && line.bbox.minX - previous.bbox.minX > median * 0.9
            // A real change of type size starts something new — most often a
            // heading. The threshold is tight because `fontSize` is a true point
            // size read from the font, stable to within about 1% inside a
            // paragraph. At the old 1.25 a section heading set at 10.8pt above
            // 8.2pt body was merged into the paragraph below it and never
            // reached heading detection at all.
            let sizeChange = max(line.fontSize, previous.fontSize)
                           > min(line.fontSize, previous.fontSize) * 1.06
                          || line.isBold != previous.isBold
            // A numbered section title set in the body face is invisible to
            // every other test here, and merging it into the paragraph below
            // loses the heading entirely.
            let startsSection = HeadingHeuristic.sectionDepth(of: line.text) != nil
            // A section title set at body size is separated from the sentence
            // after it by nothing but its length. Some styles do that for every
            // subsection, and without this "5.1 Generalization to Longer Texts"
            // absorbs the paragraph beneath it and stops being a heading at all.
            let openedWithSection = current.first.map {
                HeadingHeuristic.sectionDepth(of: $0.text) != nil
            } ?? false
            let measure = columnWidth[line.column] ?? line.bbox.width
            let isFullMeasure = line.bbox.width >= measure * 0.9
            let endsTitle = openedWithSection && isFullMeasure

            if bigGap || columnBreak || indented || sizeChange || startsSection || endsTitle {
                flush()
            }
            current.append(line)
        }
        flush()
        return paragraphs
    }
}
