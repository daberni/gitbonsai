import AppKit
import Avatars

/// Harness switches for avatars. Harness runs load none unless `GITBONSAI_AVATARS` asks for them.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_AVATARS=off|remote|gravatar` stores the avatar setting in the harness defaults at launch.
    static func applyAvatarSwitches() {
        guard isActive, let value = environment["GITBONSAI_AVATARS"] else { return }
        switch value {
        case "remote":
            AppSettings.avatarsEnabled = true
            AppSettings.avatarSources = .remoteHost
        case "gravatar":
            AppSettings.avatarsEnabled = true
            AppSettings.avatarSources = .remoteHostAndGravatar
        default:
            AppSettings.avatarsEnabled = false
        }
    }

    /// `GITBONSAI_AVATAR_CACHE=<folder>` keeps the avatar disk cache there, for example an empty folder to measure a cold load.
    /// Without it harness runs use a temporary folder, so their cleanup never touches the user's cache.
    static var avatarCacheDirectory: URL? {
        guard isActive else { return nil }
        guard let path = environment["GITBONSAI_AVATAR_CACHE"] else { return FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-harness-avatars", isDirectory: true) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// `GITBONSAI_AVATAR_LOG=1` prints every avatar request with its status and the running count; the query, which can hold an address, is left out.
    static func avatarFetcher(wrapping fetcher: AvatarFetching) -> AvatarFetching {
        guard isActive, environment["GITBONSAI_AVATAR_LOG"] == "1" else { return fetcher }
        return CountingAvatarFetcher(fetcher)
    }

    /// `GITBONSAI_AVATAR_SWEEP=<rows>` scrolls the history down a screen every half second until that row was on screen, the way a user pages through, and prints each step.
    static func driveAvatarSweep(_ history: HistoryViewController) {
        guard let rows = environment["GITBONSAI_AVATAR_SWEEP"].flatMap(Int.init) else { return }
        let table = history.tableView
        func step() {
            let visible = table.rows(in: table.visibleRect)
            let last = visible.location + visible.length - 1
            FileHandle.standardError.write(Data("avatar sweep: rows \(visible.location)–\(last)\n".utf8))
            guard last < min(rows, table.numberOfRows) - 1 else { return }
            table.scrollRowToVisible(min(last + visible.length - 1, rows - 1))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step() }
    }
}

private actor RequestCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}

private struct CountingAvatarFetcher: AvatarFetching {
    let fetcher: AvatarFetching
    let counter = RequestCounter()

    init(_ fetcher: AvatarFetching) {
        self.fetcher = fetcher
    }

    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let number = await counter.next()
        let target = "\(request.url?.host ?? "?")\(request.url?.path ?? "")"
        do {
            let (data, response) = try await fetcher.fetch(request)
            FileHandle.standardError.write(Data("avatar request \(number): \(response.statusCode) \(target)\n".utf8))
            return (data, response)
        } catch {
            FileHandle.standardError.write(Data("avatar request \(number): failed \(target)\n".utf8))
            throw error
        }
    }
}
