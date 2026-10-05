import AppKit

enum BurnrateIcon {
    static let image: NSImage? = {
        // App bundles keep resources under Contents/Resources; SwiftPM runs use Bundle.module.
        let resources = Bundle.main.url(forResource: "Burnrate_Burnrate", withExtension: "bundle")
            .flatMap { Bundle(url: $0) } ?? Bundle.module
        guard let url = resources.url(forResource: "fire", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    static let smallImage = rasterizedImage(pointSize: 20)
    static let previewImage = rasterizedImage(pointSize: 12)

    private static func rasterizedImage(pointSize: Int) -> NSImage? {
        guard let source = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let size = NSSize(width: pointSize, height: pointSize)
        let result = NSImage(size: size)

        // Downsample once at each display scale so small icons retain smooth alpha edges.
        for scale in [1, 2] {
            let pixels = pointSize * scale
            guard let context = CGContext(
                data: nil,
                width: pixels,
                height: pixels,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }

            context.interpolationQuality = .high
            context.setShouldAntialias(true)
            context.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            guard let rendered = context.makeImage() else { return nil }

            let representation = NSBitmapImageRep(cgImage: rendered)
            representation.size = size
            result.addRepresentation(representation)
        }

        result.isTemplate = false
        return result
    }
}
