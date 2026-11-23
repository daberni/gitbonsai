import AppKit
import GitEngine

/// One decoded side of an image change.
struct ImagePreview {
    let image: NSImage
    /// Pixel dimensions of a bitmap; nil for a vector image (SVG, PDF), whose size is in points.
    let pixelSize: CGSize?
    let byteCount: Int

    var size: CGSize { pixelSize ?? image.size }
}

/// What one side of an image change shows.
enum ImageSideState {
    /// The file does not exist on this side: added or deleted.
    case absent
    /// Larger than what loads on its own; loads on a click.
    case tooLarge(byteCount: Int)
    case image(ImagePreview)
    /// git has the content, but it is no image macOS can decode.
    case unreadable(byteCount: Int?)
}

/// Both sides of an image change, or the LFS note when the repository holds only pointers.
enum ImageDiffContent {
    case images(old: ImageSideState, new: ImageSideState, offersText: Bool)
    /// A side is a Git LFS pointer: the text diff stays, with this note above it.
    case lfsPointer
}

/// Reads and decodes both sides of a changed image through the engine; nothing is read for a file that is no image.
enum ImageDiffLoader {
    /// Sides up to this size load with the diff; larger ones wait for a click.
    static let automaticLimit = 32 << 20

    static func load(_ diff: FileDiff, path: String, source: DiffSource, from repository: Repository, loadingLarge: Bool) async -> ImageDiffContent? {
        guard ImageFile.isImage(path) else { return nil }
        let sides = repository.blobSides(of: diff, in: source)
        async let old = read(sides.old, from: repository, loadingLarge: loadingLarge)
        async let new = read(sides.new, from: repository, loadingLarge: loadingLarge)
        let (oldRead, newRead) = await (old, new)
        if oldRead.isLFSPointer || newRead.isLFSPointer { return .lfsPointer }
        // A text diff exists only for text images such as SVG; a binary diff has none to offer.
        guard diff.isBinary || oldRead.state.isImage || newRead.state.isImage else { return nil }
        return .images(old: oldRead.state, new: newRead.state, offersText: !diff.isBinary)
    }

    private struct SideRead {
        var state: ImageSideState
        var isLFSPointer = false
    }

    private static func read(_ location: BlobLocation?, from repository: Repository, loadingLarge: Bool) async -> SideRead {
        guard let location else { return SideRead(state: .absent) }
        let byteCount = await repository.blobSize(at: location)
        if let byteCount, byteCount > automaticLimit, !loadingLarge { return SideRead(state: .tooLarge(byteCount: byteCount)) }
        guard let data = try? await repository.blobData(at: location) else { return SideRead(state: .unreadable(byteCount: byteCount)) }
        if LFSPointer(data) != nil { return SideRead(state: .unreadable(byteCount: data.count), isLFSPointer: true) }
        return SideRead(state: decode(data))
    }

    /// NSImage decodes every format the image diff offers, PDF as its first page.
    private static func decode(_ data: Data) -> ImageSideState {
        guard let image = NSImage(data: data), image.isValid, image.size.width > 0, image.size.height > 0 else { return .unreadable(byteCount: data.count) }
        let bitmap = image.representations.first as? NSBitmapImageRep
        let pixelSize = bitmap.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
        return .image(ImagePreview(image: image, pixelSize: pixelSize, byteCount: data.count))
    }
}

private extension ImageSideState {
    var isImage: Bool {
        if case .image = self { return true }
        return false
    }
}
