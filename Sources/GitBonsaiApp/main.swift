import AppKit

// Before the first git process: harness runs read a git configuration of their own.
ScreenshotHarness.isolateGitConfig()
// Before the first string is looked up: harness runs pick their language with `GITBONSAI_LANGUAGE=en|de`.
if let language = ScreenshotHarness.language { AppLanguage.override(language) }
let app = NSApplication.shared
// Screenshot runs stay in the background: no Dock icon, no focus taken from the app in front.
app.setActivationPolicy(ScreenshotHarness.runsInBackground ? .accessory : .regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
