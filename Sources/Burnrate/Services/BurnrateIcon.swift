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

    static let menubarImage: NSImage? = {
        guard let image = image?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 20, height: 20)
        image.isTemplate = false
        return image
    }()
}
