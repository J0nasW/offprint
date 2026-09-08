import CoreGraphics
import Foundation

/// A rectangle in PDF points with the origin at the **top-left** of the page.
///
/// Vision reports normalised regions with a bottom-left origin; PDFKit uses a
/// bottom-left origin in page points. Both are converted here so that everything
/// downstream — Markdown ordering, figure cropping, the JSON export — works in a
/// single coordinate space that matches how a reader sees the page.
public struct BoundingBox: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var area: Double { max(0, width) * max(0, height) }
    public var midY: Double { y + height / 2 }
    public var midX: Double { x + width / 2 }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func intersection(_ other: BoundingBox) -> BoundingBox {
        let x0 = max(minX, other.minX)
        let y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX)
        let y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return BoundingBox(x: 0, y: 0, width: 0, height: 0) }
        return BoundingBox(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func union(_ other: BoundingBox) -> BoundingBox {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let x0 = min(minX, other.minX)
        let y0 = min(minY, other.minY)
        let x1 = max(maxX, other.maxX)
        let y1 = max(maxY, other.maxY)
        return BoundingBox(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Fraction of `self` that `other` covers. Used to decide whether a detected
    /// region is already accounted for by another block.
    public func coverage(by other: BoundingBox) -> Double {
        guard area > 0 else { return 0 }
        return intersection(other).area / area
    }

    public func inset(by d: Double) -> BoundingBox {
        BoundingBox(x: x + d, y: y + d, width: width - 2 * d, height: height - 2 * d)
    }

    /// Clipped to a page of the given size.
    public func clamped(to size: CGSize) -> BoundingBox {
        intersection(BoundingBox(x: 0, y: 0,
                                 width: Double(size.width), height: Double(size.height)))
    }

    public func scaled(by f: Double) -> BoundingBox {
        BoundingBox(x: x * f, y: y * f, width: width * f, height: height * f)
    }
}

// The JSON export writes boxes as a compact `[x, y, w, h]` array rather than an
// object — it keeps page dumps readable when a page has a hundred blocks.
extension BoundingBox {
    public init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
        width = try c.decode(Double.self)
        height = try c.decode(Double.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        // Round to 2dp: sub-point precision is noise and it doubles the file size.
        for v in [x, y, width, height] { try c.encode((v * 100).rounded() / 100) }
    }
}

extension Character {
    /// The characters Markdown escapes with a backslash.
    var isASCIIPunctuation: Bool {
        guard let ascii = asciiValue else { return false }
        return (33...47).contains(ascii) || (58...64).contains(ascii)
            || (91...96).contains(ascii) || (123...126).contains(ascii)
    }
}
