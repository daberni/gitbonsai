import AppKit

/// A changed image shows both of its sides in place of the lines; the header's toggle then picks the image mode.
extension DiffViewController {
    /// Shows the images when the file is one and the mode is not its text; returns whether they took the place of the lines.
    func applyImages() -> Bool {
        guard case .images(let old, let new, let offersText) = images else {
            header.showImageModes(nil, offered: [])
            imageView.isHidden = true
            return false
        }
        // Swipe and onion skin need both sides; an added or deleted image only shows alone.
        let hasBothSides = if case .image = old, case .image = new { true } else { false }
        let offered = hasBothSides ? ImageDiffMode.offered(includingText: offersText) : offersText ? [.sideBySide, .text] : []
        let mode = offered.contains(imageMode) ? imageMode : .sideBySide
        header.showImageModes(mode, offered: offered)
        imageView.isHidden = mode == .text
        guard mode != .text else { return false }
        imageView.show(old: old, new: new, mode: mode)
        return true
    }

    /// Above the text diff of an image whose repository holds only its LFS pointer.
    var imageNotice: String? {
        guard case .lfsPointer = images else { return nil }
        return String(localized: "diff.image.lfsPointer", defaultValue: "Git LFS pointer: the image itself is stored on the LFS server", bundle: .module, comment: "Notice above the text diff of an image tracked with Git LFS")
    }

    /// The new mode holds for this image and every image after it; the images are already read.
    func switchImageMode(to newMode: ImageDiffMode) {
        guard newMode != imageMode, let selection else { return }
        imageMode = newMode
        ImageDiffMode.remembered = newMode
        header.show(selection, diff: diff, mode: mode, options: style.options)
        scroll.isHidden = applyImages() || !emptyState.isHidden
    }

    func loadLargeImages() {
        guard let selection else { return }
        loadsLargeImages = true
        load(selection, scroll: .keep, closesWhenGone: false)
    }
}
