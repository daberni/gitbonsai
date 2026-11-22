import AppKit

let app = NSApplication.shared
// Screenshot runs stay in the background: no Dock icon, no focus taken from the app in front.
app.setActivationPolicy(ScreenshotHarness.runsInBackground ? .accessory : .regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
