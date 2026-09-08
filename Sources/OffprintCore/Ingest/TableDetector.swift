import Foundation

/// Finds tables in a PDF's text layer from the geometry of its glyphs.
///
/// Glyph positions are stronger evidence for table structure than a rendered
/// image is — the coordinates are exact rather than inferred. The whole problem
/// is telling a table apart from justified prose, which also has wide gaps
/// between words.
///
/// The signal that separates them is a **vertical whitespace corridor**: a strip
/// of x that no glyph on *any* row of the block touches. A table has one at every
/// column boundary, and it can be narrow — a dense results table sets its numeric
/// columns barely wider than a word space — but it is perfectly consistent. In
/// justified prose the gaps land wherever the line breaks put them, so over a few
/// lines every interior x gets covered by something.
///
/// This stage is pure geometry: it returns cell rectangles, and the caller reads
/// the text out of them. That keeps it testable without a PDF.
public enum TableDetector {

    public struct Candidate: Sendable {
        /// Indices into the input arrays that the table consumed.
        public var lineIndices: Range<Int>
        public var bbox: BoundingBox
        /// Cell rectangles, one array per row, left to right.
        public var cells: [[BoundingBox]]
    }

    public struct Configuration: Sendable {
        /// Narrowest corridor that counts as a column boundary, as a multiple of
        /// the type size.
        ///
        /// Justified prose stretches its word spaces, and a stretched space can
        /// reach roughly 0.7x the type size — so anything below that shreds
        /// paragraphs into cells. Column gaps are wider than that by design.
        public var minimumCorridor: Double = 0.9
        /// Largest vertical gap between consecutive rows of one table, as a
        /// multiple of the type size.
        public var maximumRowGap: Double = 2.0
        public var minimumRows: Int = 3
        public var minimumColumns: Int = 2
        /// Share of rows that must reach into more than one column.
        public var rowSupport: Double = 0.6
        public init() {}
    }

    public static func detect(lines: [TextLayerGeometry.Line],
                              glyphBoxes: [[BoundingBox]],
                              configuration: Configuration = .init()) -> [Candidate] {
        guard lines.count == glyphBoxes.count else { return [] }

        var out: [Candidate] = []
        var cursor = 0

        while cursor < lines.count {
            let end = blockEnd(from: cursor, lines: lines, configuration: configuration)
            // A block is rarely all table: a caption above and prose below cover
            // the corridors and hide the rows between them, so the longest valid
            // run has to be searched for rather than assumed.
            var best: Candidate?

            for start in cursor..<end {
                // Cannot beat what we already have.
                guard end - start > (best?.lineIndices.count ?? 0) else { break }

                // Rows are merged into the running interval set as the window
                // grows, rather than recomputed from scratch for every window —
                // the recomputing version is quadratic in a way that shows up as
                // seconds per page on table-heavy documents.
                var merged: [(low: Double, high: Double)] = []
                var fontSize = 0.0
                var longest: Candidate?

                for finish in (start + 1)...end {
                    merge(glyphBoxes[finish - 1], into: &merged)
                    fontSize = max(fontSize, lines[finish - 1].fontSize)
                    guard finish - start >= configuration.minimumRows else { continue }

                    let gaps = interiorGaps(merged,
                                            minimumWidth: fontSize * configuration.minimumCorridor)
                    // Adding a row can only cover more x, so once the corridors
                    // are gone they cannot come back. Every other check is
                    // non-monotonic and must not stop the scan.
                    if gaps.isEmpty { break }

                    if let candidate = build(range: start..<finish, gaps: gaps, merged: merged,
                                             lines: lines, glyphBoxes: glyphBoxes,
                                             configuration: configuration) {
                        longest = candidate
                    }
                }

                if let longest, longest.lineIndices.count > (best?.lineIndices.count ?? 0) {
                    best = longest
                }
            }

            if let best {
                out.append(best)
                cursor = best.lineIndices.upperBound
            } else {
                cursor = max(cursor + 1, min(end, lines.count))
            }
        }
        return out
    }

    /// Extends a block of consecutive, vertically contiguous lines in one column.
    static func blockEnd(from start: Int, lines: [TextLayerGeometry.Line],
                         configuration: Configuration) -> Int {
        var end = start + 1
        while end < lines.count {
            let previous = lines[end - 1]
            let line = lines[end]
            guard line.column == previous.column else { break }
            let gap = line.bbox.minY - previous.bbox.maxY
            guard gap <= max(previous.fontSize, line.fontSize) * configuration.maximumRowGap else {
                break
            }
            end += 1
        }
        return end
    }

    /// Folds a row's glyph extents into a sorted, non-overlapping interval set.
    static func merge(_ boxes: [BoundingBox], into merged: inout [(low: Double, high: Double)]) {
        for box in boxes {
            var low = box.minX
            var high = box.maxX
            var index = 0
            var insertAt = merged.count
            while index < merged.count {
                let existing = merged[index]
                if existing.high < low {
                    index += 1
                    continue
                }
                if existing.low > high {
                    insertAt = index
                    break
                }
                low = min(low, existing.low)
                high = max(high, existing.high)
                merged.remove(at: index)
            }
            if index >= merged.count && insertAt == merged.count { insertAt = index }
            merged.insert((low, high), at: min(insertAt, merged.count))
        }
    }

    /// Gaps between merged intervals that are wide enough to be column boundaries.
    static func interiorGaps(_ merged: [(low: Double, high: Double)],
                             minimumWidth: Double) -> [(low: Double, high: Double)] {
        var gaps: [(low: Double, high: Double)] = []
        for (a, b) in zip(merged, merged.dropFirst()) where b.low - a.high >= minimumWidth {
            gaps.append((a.high, b.low))
        }
        return gaps
    }

    static func build(range: Range<Int>, gaps: [(low: Double, high: Double)],
                      merged: [(low: Double, high: Double)],
                      lines: [TextLayerGeometry.Line], glyphBoxes: [[BoundingBox]],
                      configuration: Configuration) -> Candidate? {
        guard let minX = merged.first?.low, let maxX = merged.last?.high else { return nil }
        let rows = Array(range)

        var edges: [(low: Double, high: Double)] = []
        var start = minX
        for gap in gaps {
            edges.append((start, gap.low))
            start = gap.high
        }
        edges.append((start, maxX))
        guard edges.count >= configuration.minimumColumns else { return nil }

        // Three rows minimum, with no escape for extra columns. Two lines of
        // justified prose land their stretched spaces at the same few x often
        // enough to fake a wide grid, and shredding a paragraph into cells is a
        // far worse failure than missing a rare two-row table.
        guard rows.count >= 3 else { return nil }

        // Most rows must actually span more than one column, or this is a list
        // with a hanging indent rather than a table.
        let spanning = rows.filter { row in
            glyphBoxes[row].reduce(into: Set<Int>()) { columns, box in
                if let index = edges.firstIndex(where: { box.midX >= $0.low && box.midX <= $0.high }) {
                    columns.insert(index)
                }
            }.count >= 2
        }
        guard Double(spanning.count) >= Double(rows.count) * configuration.rowSupport else {
            return nil
        }

        let cells: [[BoundingBox]] = rows.map { row in
            let line = lines[row]
            return edges.map { edge in
                BoundingBox(x: edge.low, y: line.bbox.minY,
                            width: edge.high - edge.low, height: line.bbox.height)
            }
        }
        let bbox = rows.dropFirst().reduce(lines[rows[0]].bbox) { $0.union(lines[$1].bbox) }
        return Candidate(lineIndices: range, bbox: bbox, cells: cells)
    }

    /// Finds interior x-intervals that no glyph covers.
    static func corridors(in boxes: [BoundingBox], from minX: Double, to maxX: Double,
                          minimumWidth: Double) -> [(low: Double, high: Double)] {
        // Merge every glyph's horizontal extent, then read off what is left.
        let intervals = boxes
            .map { (low: $0.minX, high: $0.maxX) }
            .sorted { $0.low < $1.low }

        var merged: [(low: Double, high: Double)] = []
        for interval in intervals {
            if var last = merged.last, interval.low <= last.high {
                last.high = max(last.high, interval.high)
                merged[merged.count - 1] = last
            } else {
                merged.append(interval)
            }
        }

        var gaps: [(low: Double, high: Double)] = []
        for (a, b) in zip(merged, merged.dropFirst()) where b.low - a.high >= minimumWidth {
            // Strictly interior: the page margins are not column boundaries.
            guard a.high > minX, b.low < maxX else { continue }
            gaps.append((a.high, b.low))
        }
        return gaps
    }
}
