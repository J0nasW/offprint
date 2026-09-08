import CoreGraphics
import Foundation
import PDFKit

/// Rasterises PDF pages for the OCR engines.
public struct PDFRenderer: Sendable {

    /// 150 dpi is the working default: comfortably above what both Vision and
    /// GLM-OCR resize to internally, while 300 dpi mostly buys larger images and
    /// slower prefill rather than better text.
    public static let defaultDPI: Double = 150
    /// Figures are cropped at a higher density than the OCR pass, since they end
    /// up in front of a reader rather than a model.
    public static let figureDPI: Double = 200

    public var dpi: Double
    public var displayBox: PDFDisplayBox

    public init(dpi: Double = PDFRenderer.defaultDPI, displayBox: PDFDisplayBox = .cropBox) {
        self.dpi = dpi
        self.displayBox = displayBox
    }

    public enum RenderError: Error, Sendable {
        case emptyPage
        case contextCreationFailed
        case imageCreationFailed
    }

    public var scale: Double { dpi / 72.0 }

    public func pageSize(_ page: PDFPage) -> CGSize {
        page.bounds(for: displayBox).size
    }

    /// Renders a full page.
    public func render(_ page: PDFPage) throws -> CGImage {
        try render(page, cropTo: nil, scale: scale)
    }

    /// Renders a sub-rectangle of a page, given in **top-left-origin page points**.
    public func render(_ page: PDFPage, crop: BoundingBox, dpi cropDPI: Double) throws -> CGImage {
        try render(page, cropTo: crop, scale: cropDPI / 72.0)
    }

    private func render(_ page: PDFPage, cropTo crop: BoundingBox?, scale: Double) throws -> CGImage {
        let bounds = page.bounds(for: displayBox)
        guard bounds.width > 0, bounds.height > 0 else { throw RenderError.emptyPage }

        // Crop rectangles arrive in top-left coordinates; PDF user space is
        // bottom-left, so flip before intersecting with the page box.
        let region: CGRect
        if let crop {
            let flippedY = Double(bounds.height) - (crop.y + crop.height)
            region = CGRect(x: bounds.origin.x + crop.x,
                            y: bounds.origin.y + flippedY,
                            width: crop.width,
                            height: crop.height).intersection(bounds)
        } else {
            region = bounds
        }
        guard region.width > 0, region.height > 0 else { throw RenderError.emptyPage }

        let pixelWidth = Int((Double(region.width) * scale).rounded())
        let pixelHeight = Int((Double(region.height) * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { throw RenderError.emptyPage }

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw RenderError.contextCreationFailed }

        // PDFs assume they are printed on white paper; without this, transparent
        // areas come through as black and OCR quality collapses.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.interpolationQuality = .high

        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -region.origin.x, y: -region.origin.y)
        page.draw(with: displayBox, to: context)

        guard let image = context.makeImage() else { throw RenderError.imageCreationFailed }
        return image
    }
}
