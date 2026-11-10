import AppKit
import Darwin

// No SwiftUI App/Scene: a menu bar app needs no scene, and SwiftUI's `Settings`
// scene (the only scene an App can have without opening a window) shows its
// empty preferences window on launch.
if PrintMode.requested {
    PrintMode.runAndExit()
}

// One menu bar item: the LaunchAgent, `open -a`, and a direct run must not each
// contribute an instance. The lock is held for the process lifetime.
let lockPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/meter/app.lock")
try? FileManager.default.createDirectory(at: lockPath.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
// O_CLOEXEC matters: agy and other helpers are exec'd children, and an
// inherited descriptor would keep the flock held after meter exits.
let lockFD = open(lockPath.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    exit(0)
}

// top-level code runs on the main thread, which is the main actor
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
