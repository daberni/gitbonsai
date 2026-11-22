import AppKit

// Spike window is implemented in GraphWindow.swift once GitEngine and GraphLayout exist.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
