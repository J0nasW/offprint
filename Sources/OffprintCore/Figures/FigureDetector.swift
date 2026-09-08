import CoreGraphics
import Foundation

/// Finds figures by looking for ink the text engines did not claim.
///
/// Neither PDFKit nor Vision enumerates embedded images through public API, so
/// figures are found by subtraction: rasterise the page, mark every pixel that
/// carries ink, erase everything already covered by a text block, and whatever
/// survives in a large enough connected region is a figure.
///
/// Testing for ink is the part that matters. Most of the empty area on a text
/// page is margin and line spacing; a purely geometric "negative space" search
/// returns the margins and nothing useful.
public struct FigureDetector: Sendable {

    public struct Configuration: Sendable {
        /// Grid resolution along the page's longer edge.
        public var gridResolution: Int = 96
        /// Minimum share of the page a region must cover to count as a figure.
        public var minimumAreaFraction: Double = 0.012
        /// Luminance below which a pixel counts as ink (0…1).
        public var inkThreshold: Double = 0.92
        /// Share of a cell's pixels that must be ink for the cell to count.
        public var cellInkFraction: Double = 0.02
        /// Text boxes are grown slightly before erasing, so antialiased glyph
        /// edges don't survive as speckle.
        public var textPadding: Double = 2.0
        public init() {}
    }

    public var configuration: Configuration
    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public struct Region: Sendable, Hashable {
        public var bbox: BoundingBox
        /// Fraction of the region's cells that carry ink — low values suggest a
        /// rule or a border rather than a real figure.
        public var inkDensity: Double
    }

    /// - Parameters:
    ///   - image: the rendered page.
    ///   - pageSize: page size in points; returned boxes use this space.
    ///   - occupied: boxes already claimed by text blocks, in top-left page points.
    public func detect(image: CGImage, pageSize: CGSize, occupied: [BoundingBox]) -> [Region] {
        guard pageSize.width > 0, pageSize.height > 0 else { return [] }
        let (cols, rows) = gridSize(for: pageSize)
        guard cols > 1, rows > 1 else { return [] }

        guard var ink = Self.inkGrid(image: image, cols: cols, rows: rows,
                                     inkThreshold: configuration.inkThreshold,
                                     cellInkFraction: configuration.cellInkFraction)
        else { return [] }

        // Erase everything the text engines already accounted for.
        let cellW = Double(pageSize.width) / Double(cols)
        let cellH = Double(pageSize.height) / Double(rows)
        for box in occupied {
            let padded = box.inset(by: -configuration.textPadding)
            let c0 = max(0, Int(floor(padded.minX / cellW)))
            let c1 = min(cols - 1, Int(ceil(padded.maxX / cellW)))
            let r0 = max(0, Int(floor(padded.minY / cellH)))
            let r1 = min(rows - 1, Int(ceil(padded.maxY / cellH)))
            guard c0 <= c1, r0 <= r1 else { continue }
            for r in r0...r1 where r >= 0 && r < rows {
                for c in c0...c1 where c >= 0 && c < cols {
                    ink[r * cols + c] = false
                }
            }
        }

        let components = Self.connectedComponents(ink, cols: cols, rows: rows)
        let pageArea = Double(pageSize.width) * Double(pageSize.height)

        return components.compactMap { component -> Region? in
            let box = BoundingBox(
                x: Double(component.minCol) * cellW,
                y: Double(component.minRow) * cellH,
                width: Double(component.maxCol - component.minCol + 1) * cellW,
                height: Double(component.maxRow - component.minRow + 1) * cellH
            )
            guard box.area / pageArea >= configuration.minimumAreaFraction else { return nil }
            let cells = Double((component.maxCol - component.minCol + 1)
                             * (component.maxRow - component.minRow + 1))
            let density = cells > 0 ? Double(component.count) / cells : 0
            // A very sparse component is a rule, a border, or scattered speckle.
            guard density >= 0.18 else { return nil }
            // Ignore slivers: a figure has some extent in both directions.
            guard box.width > Double(pageSize.width) * 0.05,
                  box.height > Double(pageSize.height) * 0.02 else { return nil }
            return Region(bbox: box, inkDensity: density)
        }
        .sorted { ($0.bbox.minY, $0.bbox.minX) < ($1.bbox.minY, $1.bbox.minX) }
    }

    func gridSize(for pageSize: CGSize) -> (cols: Int, rows: Int) {
        let n = Double(configuration.gridResolution)
        if pageSize.width >= pageSize.height {
            return (Int(n), max(2, Int(n * Double(pageSize.height / pageSize.width))))
        }
        return (max(2, Int(n * Double(pageSize.width / pageSize.height))), Int(n))
    }

    // MARK: - Rasterisation

    /// Renders the image into a grayscale buffer and reduces it to a boolean grid.
    static func inkGrid(image: CGImage, cols: Int, rows: Int,
                        inkThreshold: Double, cellInkFraction: Double) -> [Bool]? {
        // Sample at a few pixels per cell: enough to notice a thin line, cheap
        // enough to run on every page.
        let sampleW = cols * 4
        let sampleH = rows * 4
        guard let context = CGContext(
            data: nil, width: sampleW, height: sampleH,
            bitsPerComponent: 8, bytesPerRow: sampleW,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: sampleW, height: sampleH))
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))

        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: sampleW * sampleH)
        let cutoff = UInt8(max(0, min(255, inkThreshold * 255)))

        var grid = [Bool](repeating: false, count: cols * rows)
        let perCell = 4 * 4
        let needed = max(1, Int(Double(perCell) * cellInkFraction))

        for r in 0..<rows {
            for c in 0..<cols {
                var inked = 0
                for dy in 0..<4 {
                    // A CGBitmapContext stores its first buffer row at the *top*
                    // of the rendered image, which matches the grid's top-left
                    // origin. Flipping here mirrors the ink map against the text
                    // boxes used to erase it, which leaves real text unerased and
                    // reports blank paper as figures.
                    let y = r * 4 + dy
                    guard y < sampleH else { continue }
                    let rowBase = y * sampleW
                    for dx in 0..<4 {
                        let x = c * 4 + dx
                        guard x < sampleW else { continue }
                        if pixels[rowBase + x] < cutoff { inked += 1 }
                    }
                }
                grid[r * cols + c] = inked >= needed
            }
        }
        return grid
    }

    // MARK: - Connected components

    struct Component {
        var minRow = Int.max, maxRow = Int.min
        var minCol = Int.max, maxCol = Int.min
        var count = 0
        mutating func add(row: Int, col: Int) {
            minRow = min(minRow, row); maxRow = max(maxRow, row)
            minCol = min(minCol, col); maxCol = max(maxCol, col)
            count += 1
        }
    }

    /// 8-connected flood fill, iterative so a full-page component cannot blow the
    /// stack.
    static func connectedComponents(_ grid: [Bool], cols: Int, rows: Int) -> [Component] {
        var visited = [Bool](repeating: false, count: grid.count)
        var out: [Component] = []
        var stack: [Int] = []

        for start in 0..<grid.count where grid[start] && !visited[start] {
            var component = Component()
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = true

            while let index = stack.popLast() {
                let r = index / cols
                let c = index % cols
                component.add(row: r, col: c)
                for dr in -1...1 {
                    for dc in -1...1 where !(dr == 0 && dc == 0) {
                        let nr = r + dr, nc = c + dc
                        guard nr >= 0, nr < rows, nc >= 0, nc < cols else { continue }
                        let n = nr * cols + nc
                        if grid[n] && !visited[n] {
                            visited[n] = true
                            stack.append(n)
                        }
                    }
                }
            }
            out.append(component)
        }
        return out
    }
}
