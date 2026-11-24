import AppKit
import Avatars
import os

/// What exists once per launch: the app-wide services, built by the composition root in `main.swift` and handed down by initializer. Nothing looks them up globally.
@MainActor
final class AppContext {
    let persistence: Persistence
    let settings: AppSettings
    let pasteboard: Pasteboard
    let avatars: AvatarStore
    let trace: TraceSink
    let sessions: SessionStore
    let discovery: RepositoryDiscoveryStore

    init(persistence: Persistence, settings: AppSettings, pasteboard: Pasteboard, avatarCacheDirectory: URL, avatarTransport: AvatarFetching, trace: TraceSink) {
        self.persistence = persistence
        self.settings = settings
        self.pasteboard = pasteboard
        self.trace = trace
        avatars = AvatarStore(cacheDirectory: avatarCacheDirectory, fetcher: avatarTransport) { settings.avatarMode }
        sessions = SessionStore(defaults: persistence.defaults)
        discovery = RepositoryDiscoveryStore(settings: settings)
    }
}

/// The defaults domain the app keeps its preferences, layouts and session state in.
struct Persistence {
    let defaults: UserDefaults
}

/// Copy and paste of plain text.
struct Pasteboard {
    let pasteboard: NSPasteboard

    func string() -> String? {
        pasteboard.string(forType: .string)
    }

    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Where the app writes its traces in the unified log, subsystem `app.gitbonsai`.
struct TraceSink: Sendable {
    let subsystem: String

    func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}

extension AvatarStore {
    /// Next to the app's other support files.
    static var defaultCacheDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("GitBonsai/Avatars", isDirectory: true)
    }
}
