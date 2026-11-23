import Foundation

/// How a changed image is compared: both side by side, a swipe line over both, or the new one faded over the old. A text image (SVG) can also show its source diff. The last choice holds for the next image and the next launch.
enum ImageDiffMode: String, CaseIterable {
    case sideBySide
    case swipe
    case onionSkin
    case text

    var title: String {
        switch self {
        case .sideBySide: String(localized: "diff.image.mode.sideBySide", defaultValue: "Side by side", bundle: .module, comment: "Image diff mode: old and new image next to each other")
        case .swipe: String(localized: "diff.image.mode.swipe", defaultValue: "Swipe", bundle: .module, comment: "Image diff mode: a draggable line shows the old image on one side and the new on the other")
        case .onionSkin: String(localized: "diff.image.mode.onionSkin", defaultValue: "Onion skin", bundle: .module, comment: "Image diff mode: the new image over the old with adjustable opacity")
        case .text: String(localized: "diff.image.mode.text", defaultValue: "Text", bundle: .module, comment: "Image diff mode for SVG: the source as a text diff")
        }
    }

    /// The modes for an image; only a text image offers its text.
    static func offered(includingText: Bool) -> [ImageDiffMode] {
        includingText ? allCases : allCases.filter { $0 != .text }
    }

    private static let key = "imageDiffMode"

    /// Harness runs start side by side unless `GITBONSAI_IMAGE_MODE` names a mode.
    @MainActor static var remembered: ImageDiffMode {
        get {
            if ScreenshotHarness.isActive { return ProcessInfo.processInfo.environment["GITBONSAI_IMAGE_MODE"].flatMap(ImageDiffMode.init) ?? .sideBySide }
            return defaults.string(forKey: key).flatMap(ImageDiffMode.init) ?? .sideBySide
        }
        set { defaults.set(newValue.rawValue, forKey: key) }
    }

    @MainActor private static var defaults: UserDefaults { ScreenshotHarness.defaults }
}

/// Which files are shown as images, by extension.
enum ImageFile {
    private static let raster: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico", "icns"]
    private static let vector: Set<String> = ["svg", "pdf"]

    static func isImage(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return raster.contains(ext) || vector.contains(ext)
    }
}
