import AppKit

// No SwiftUI App/Scene: a menu bar app needs no scene, and SwiftUI's `Settings`
// scene (the only scene an App can have without opening a window) shows its
// empty preferences window on launch.
if PrintMode.requested {
    PrintMode.runAndExit()
}

// top-level code runs on the main thread, which is the main actor
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
