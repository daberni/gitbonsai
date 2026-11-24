import AppKit
import Avatars

// harness: the out-of-process harness sets git's configuration through the launched process's environment (`HOME`, `GIT_CONFIG_GLOBAL`).
ScreenshotHarness.isolateGitConfig()
// harness: replaced by the launch arguments `-AppleLanguages (en)`; must run before the first string is looked up.
if let language = ScreenshotHarness.language { AppLanguage.override(language) }
let app = NSApplication.shared
// harness: the launched app keeps its normal activation policy; the harness launches it hidden and captures with ScreenCaptureKit.
app.setActivationPolicy(ScreenshotHarness.runsInBackground ? .accessory : .regular)

// The composition root: the app's context is built here once and passed down by initializer.
// harness: the out-of-process harness picks the defaults domain through the environment, and uses the general pasteboard and the real avatar cache and transport of a throwaway user; then these become `.standard`, `.general`, the default cache folder and `URLSessionAvatarFetcher` unconditionally.
let persistence = Persistence(defaults: ScreenshotHarness.defaults)
let settings = AppSettings(persistence: persistence)
// harness: the harness writes these preferences into its defaults domain before launch.
ScreenshotHarness.applySettingSwitches(to: settings)
// harness: see above; these three become the production pasteboard, cache folder and transport.
let context = AppContext(
    persistence: persistence,
    settings: settings,
    pasteboard: Pasteboard(pasteboard: ScreenshotHarness.pasteboard),
    avatarCacheDirectory: ScreenshotHarness.avatarCacheDirectory ?? AvatarStore.defaultCacheDirectory,
    avatarTransport: ScreenshotHarness.avatarFetcher(wrapping: URLSessionAvatarFetcher()),
    trace: TraceSink(subsystem: "app.gitbonsai")
)
let delegate = AppDelegate(context: context)
app.delegate = delegate
app.run()
