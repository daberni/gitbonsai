import AppKit
import Avatars
import GitEngine

/// Author avatars for the history and the detail panel.
///
/// Pictures are kept per address, not per repository: one found in any repository shows in every other.
/// Drawing reads memory, and the disk cache once per address and run, so pictures from an earlier launch show with the first frame. Anything else returns nil, so the generated fallback shows, and starts one background lookup per author.
/// Rows only ask while they are on screen, which keeps the network lazy and the history's cost per row a dictionary lookup.
@MainActor
final class AvatarStore {
    /// Posted, at most once per run loop turn, when avatars arrived or were dropped; views showing avatars redraw.
    static let didChange = Notification.Name("AvatarStore.didChange")

    /// A lookup that found nothing because the service could not be reached is tried again after this long.
    private static let retryInterval: TimeInterval = 300
    /// Pictures kept in memory; well above a screenful of authors, a few MB at 56 px.
    private static let memoryCapacity = 1000

    private let cache: AvatarDiskCache
    private let resolver: AvatarResolver
    /// The avatar service of each repository folder, from its remotes.
    private var services: [String: AvatarService] = [:]
    private var servicesLoading: Set<String> = []
    private var images = AvatarMemoryCache<NSImage>(capacity: memoryCapacity)
    /// When each author without image was last looked up, including lookups still running.
    private var attempts: [String: Date] = [:]
    /// Addresses whose picture was already looked for on disk this run.
    private var diskRead: Set<String> = []
    private let settings: @MainActor () -> AvatarMode
    private var applied: AvatarMode
    private var changePending = false

    /// `settings` is read again whenever `AppSettings` posts a change; tests pass their own instead of the user's preferences.
    init(cacheDirectory: URL, fetcher: AvatarFetching, settings: @escaping @MainActor () -> AvatarMode) {
        cache = AvatarDiskCache(directory: cacheDirectory)
        resolver = AvatarResolver(cache: cache, fetcher: fetcher)
        self.settings = settings
        applied = settings()
        let resolver = resolver
        if applied.showsPictures {
            Task { await resolver.sweepCache() }
        } else {
            // Covers a cache left from before the setting was turned off, or from a run that ended before deleting it.
            Task { await resolver.discardAll() }
        }
        NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    /// Whether nodes show pictures and, for authors without one, the generated stand-in; otherwise plain initials.
    var showsPictures: Bool { applied.showsPictures }

    /// The stand-in for an author without picture.
    var fallbackStyle: AvatarFallbackStyle {
        guard showsPictures else { return .initials }
        // harness: the harness stores the style in its defaults domain, or the theme decides alone.
        return ScreenshotHarness.avatarFallbackStyle ?? Theme.Avatar.fallback
    }

    /// The avatar of whoever uses `email`, if it is in memory; otherwise nil, and a lookup starts unless one ran recently.
    /// `commit` is a commit with that address as author or committer; GitHub's commit list starts there to name the account.
    func image(email: String, commit: String, in repository: Repository) -> NSImage? {
        guard let sources = applied.sources, let personKey = AvatarPlan.personKey(email: email, sources: sources, pixels: Theme.Avatar.pixels) else { return nil }
        let key = personKey
        if let image = images.value(for: key) { return image }
        if diskRead.insert(key).inserted, case .image(let data) = cache.read(key, now: Date()), let image = NSImage(data: data) {
            images.insert(image, for: key)
            return image
        }
        guard let service = service(of: repository), let address = AvatarPlan.normalized(email) else { return nil }
        if let last = attempts[key], Date().timeIntervalSince(last) < Self.retryInterval { return nil }
        attempts[key] = Date()
        let steps = AvatarPlan.steps(email: address, commit: commit, service: service, sources: sources, pixels: Theme.Avatar.pixels)
        guard !steps.isEmpty else { return nil }
        let resolver = resolver
        Task {
            guard let data = await resolver.image(for: steps, personKey: personKey), let image = NSImage(data: data) else { return }
            // Settings may have changed while the lookup ran.
            guard applied.sources == sources else { return }
            images.insert(image, for: key)
            attempts[key] = nil
            postChange()
        }
        return nil
    }

    private func service(of repository: Repository) -> AvatarService? {
        if let service = services[repository.path] { return service }
        guard servicesLoading.insert(repository.path).inserted else { return nil }
        Task {
            services[repository.path] = await Self.resolveService(of: repository)
            servicesLoading.remove(repository.path)
            postChange()
        }
        return nil
    }

    /// The repository's remotes may have changed outside the app (`git remote add`, `set-url`, another upstream); a service already resolved is read again and replaced only when it differs, so the avatars on screen stay until then.
    func remotesMayHaveChanged(in repository: Repository) {
        guard showsPictures, let current = services[repository.path], !servicesLoading.contains(repository.path) else { return }
        servicesLoading.insert(repository.path)
        Task {
            let resolved = await Self.resolveService(of: repository)
            servicesLoading.remove(repository.path)
            guard resolved != current, services[repository.path] == current else { return }
            services[repository.path] = resolved
            postChange()
        }
    }

    private static func resolveService(of repository: Repository) async -> AvatarService {
        let urls = try? await repository.remoteURLs()
        let remotes = (urls?.remotes ?? []).map { (name: $0.name, url: $0.url) }
        let url = AvatarService.remoteURL(in: remotes, upstreamRemote: urls?.upstreamRemote)
        return url.map(AvatarService.init(remoteURL:)) ?? AvatarService.none
    }

    private func settingsChanged() {
        let current = settings()
        guard current != applied else { return }
        let turnedOff = applied.showsPictures && !current.showsPictures
        applied = current
        images.removeAll()
        attempts.removeAll()
        diskRead.removeAll()
        if turnedOff {
            let resolver = resolver
            Task { await resolver.discardAll() }
        }
        postChange()
    }

    private func postChange() {
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.changePending = false
                NotificationCenter.default.post(name: AvatarStore.didChange, object: nil)
            }
        }
    }
}

/// A picture clipped to the inside of a ring, with background between ring and picture; draws nothing without an image so the caller keeps its initials.
@MainActor
enum AvatarDrawing {
    /// `rect` is the ring's outer bounds and `ring` its stroke width.
    static func draw(_ image: NSImage, in rect: CGRect, ring: CGFloat, context: CGContext) {
        let inner = rect.insetBy(dx: ring + Theme.Avatar.ringGap, dy: ring + Theme.Avatar.ringGap)
        context.saveGState()
        context.addEllipse(in: inner)
        context.clip()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: inner, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        context.restoreGState()
    }
}
