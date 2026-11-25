import AppKit
import Avatars

// The composition root of the release app: its context is built here once and passed down by initializer.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let persistence = Persistence(defaults: .standard)
let settings = AppSettings(persistence: persistence)
let context = AppContext(persistence: persistence, settings: settings, pasteboard: Pasteboard(pasteboard: .general), avatarCacheDirectory: AvatarStore.defaultCacheDirectory, avatarTransport: URLSessionAvatarFetcher(), trace: TraceSink(subsystem: "app.gitbonsai"))
let delegate = AppDelegate(context: context)
app.delegate = delegate
app.run()
