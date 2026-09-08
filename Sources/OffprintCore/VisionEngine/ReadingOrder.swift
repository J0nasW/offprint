import Foundation

/// Orders page elements the way a person reads them.
///
/// Vision groups lines into paragraphs and cells into rows, but exposes no
/// document-level reading order — so a two-column paper comes back as a bag of
/// paragraphs that, sorted naively by vertical position, interleaves the columns
/// and produces fluent-looking nonsense. This finds the gutters first.
public enum ReadingOrder {

    /// Sorts items into reading order, splitting into columns where a clear
    /// vertical gutter exists.
    ///
    /// - Parameters:
    ///   - items: elements to order, each with a bounding box.
    ///   - pageWidth: page width in the same units as the boxes.
    ///   - box: extracts the box from an item.
    public static func sort<T>(_ items: [T], pageWidth: Double, box: (T) -> BoundingBox?) -> [T] {
        let placed = items.compactMap { item -> (T, BoundingBox)? in
            guard let b = box(item) else { return nil }
            return (item, b)
        }
        // Items without geometry keep their original relative position at the end;
        // we have nothing better to go on.
        let unplaced = items.filter { box($0) == nil }
        return order(placed, pageWidth: pageWidth, depth: 0).map(\.0) + unplaced
    }

    private static func order<T>(_ items: [(T, BoundingBox)], pageWidth: Double, depth: Int)
        -> [(T, BoundingBox)]
    {
        guard items.count > 1 else { return items }

        // Two levels of splitting is plenty for real documents and stops a
        // pathological page from recursing indefinitely.
        if depth < 2, let split = findGutter(items.map(\.1), pageWidth: pageWidth) {
            let left  = items.filter { $0.1.midX <  split }
            let right = items.filter { $0.1.midX >= split }
            if !left.isEmpty && !right.isEmpty {
                return order(left, pageWidth: pageWidth, depth: depth + 1)
                     + order(right, pageWidth: pageWidth, depth: depth + 1)
            }
        }
        return sortTopToBottom(items)
    }

    /// Sorts within a single column: top to bottom, and left to right for items
    /// that sit on the same line.
    static func sortTopToBottom<T>(_ items: [(T, BoundingBox)]) -> [(T, BoundingBox)] {
        let tolerance = medianHeight(items.map(\.1)) * 0.5
        return items.enumerated().sorted { a, b in
            let (ai, (_, ab)) = a
            let (bi, (_, bb)) = b
            // Treat boxes whose tops are within half a line height as the same row.
            if abs(ab.minY - bb.minY) > tolerance {
                return ab.minY < bb.minY
            }
            if abs(ab.minX - bb.minX) > 1 {
                return ab.minX < bb.minX
            }
            return ai < bi   // stable
        }.map(\.element)
    }

    /// Finds an x-coordinate that no element straddles and that splits the page
    /// into two populated halves. Returns nil for single-column pages.
    public static func findGutter(_ boxes: [BoundingBox], pageWidth: Double) -> Double? {
        guard boxes.count >= 4, pageWidth > 0 else { return nil }

        // Full-width elements — a banner heading, a wide table — span any gutter.
        // Exclude them from the search but let them be assigned afterwards.
        let candidates = boxes.filter { $0.width < pageWidth * 0.7 }
        guard candidates.count >= 4 else { return nil }

        // Scan the middle half of the page for a vertical strip nothing crosses.
        let step = pageWidth / 200
        var best: (x: Double, clearance: Double)?
        var x = pageWidth * 0.25
        while x <= pageWidth * 0.75 {
            let crossing = candidates.contains { $0.minX < x && $0.maxX > x }
            if !crossing {
                let clearance = candidates.reduce(Double.greatestFiniteMagnitude) { acc, b in
                    min(acc, b.maxX <= x ? x - b.maxX : b.minX - x)
                }
                if best == nil || clearance > best!.clearance { best = (x, clearance) }
            }
            x += step
        }
        guard let found = best else { return nil }

        // Require a real gutter, not a coincidental one-pixel gap, and require
        // both sides to actually hold content.
        guard found.clearance > pageWidth * 0.015 else { return nil }
        let left = candidates.filter { $0.midX < found.x }.count
        let right = candidates.count - left
        guard left >= 2, right >= 2 else { return nil }
        return found.x
    }

    static func medianHeight(_ boxes: [BoundingBox]) -> Double {
        let heights = boxes.map(\.height).filter { $0 > 0 }.sorted()
        guard !heights.isEmpty else { return 1 }
        return heights[heights.count / 2]
    }
}
