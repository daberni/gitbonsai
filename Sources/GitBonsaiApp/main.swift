import AppKit

// Before the first string is looked up: harness runs pick their language with `GITBONSAI_LANGUAGE=en|de`.
if let language = ProcessInfo.processInfo.environment["GITBONSAI_LANGUAGE"] { AppLanguage.override(language) }
let app = NSApplication.shared
// Screenshot runs stay in the background: no Dock icon, no focus taken from the app in front.
app.setActivationPolicy(ScreenshotHarness.runsInBackground ? .accessory : .regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
