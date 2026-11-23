import AppKit
import Avatars
import GitEngine

/// Author avatars for the history and the detail panel.
///
/// Drawing only reads memory: asking for an avatar that is not there yet returns nil, so the initials show, and starts one background lookup per author.
/// Rows only ask while they are on screen, which keeps the network lazy and the history's cost per row a dictionary lookup.
@MainActor
final class AvatarStore {
    static let shared = AvatarStore()
    /// Posted, at most once per run loop turn, when avatars arrived or were dropped; views showing avatars redraw.
    static let didChange = Notification.Name("AvatarStore.didChange")

    /// A lookup that found nothing because the service could not be reached is tried again after this long.
    private static let retryInterval: TimeInterval = 300
    /// Pictures kept in memory; well above a screenful of authors, a few MB at 56 px.
    private static let memoryCapacity = 1000

    private let resolver: AvatarResolver
    /// The avatar service of each repository folder, from its remotes.
    private var services: [String: AvatarService] = [:]
    private var servicesLoading: Set<String> = []
    private var images = AvatarMemoryCache<NSImage>(capacity: memoryCapacity)
    /// When each author without image was last looked up, including lookups still running.
    private var attempts: [String: Date] = [:]
    private var applied: (enabled: Bool, sources: AvatarSources)
    private var changePending = false

    private init() {
        let cache = AvatarDiskCache(directory: ScreenshotHarness.avatarCacheDirectory ?? Self.defaultCacheDirectory)
        resolver = AvatarResolver(cache: cache, fetcher: ScreenshotHarness.avatarFetcher(wrapping: URLSessionAvatarFetcher()))
        applied = (AppSettings.avatarsEnabled, AppSettings.avatarSources)
        let resolver = resolver
        if applied.enabled {
            Task { await resolver.sweepCache() }
        } else {
            // Covers a cache left from before the setting was turned off, or from a run that ended before deleting it.
            Task { await resolver.discardAll() }
        }
        NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AvatarStore.shared.settingsChanged() }
        }
    }

    private static var defaultCacheDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("GitBonsai/Avatars", isDirectory: true)
    }

    /// The avatar of whoever uses `email`, if it is in memory; otherwise nil, and a lookup starts unless one ran recently.
    /// `commit` is a commit with that address as author or committer; GitHub's commit list starts there to name the account.
    func image(email: String, commit: String, in repository: Repository) -> NSImage? {
        guard applied.enabled, let address = AvatarPlan.normalized(email) else { return nil }
        guard let service = service(of: repository) else { return nil }
        let key = "\(service)|\(applied.sources.rawValue)|\(address)"
        if let image = images.value(for: key) { return image }
        if let last = attempts[key], Date().timeIntervalSince(last) < Self.retryInterval { return nil }
        attempts[key] = Date()
        let steps = AvatarPlan.steps(email: address, commit: commit, service: service, sources: applied.sources, pixels: Theme.Avatar.pixels)
        guard !steps.isEmpty else { return nil }
        let resolver = resolver
        let sources = applied.sources
        Task {
            guard let data = await resolver.image(for: steps), let image = NSImage(data: data) else { return }
            // Settings may have changed while the lookup ran.
            guard applied.enabled, applied.sources == sources else { return }
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
        guard applied.enabled, let current = services[repository.path], !servicesLoading.contains(repository.path) else { return }
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
        let current = (AppSettings.avatarsEnabled, AppSettings.avatarSources)
        guard current != applied else { return }
        let turnedOff = applied.enabled && !current.0
        applied = current
        images.removeAll()
        attempts.removeAll()
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
                AvatarStore.shared.changePending = false
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
