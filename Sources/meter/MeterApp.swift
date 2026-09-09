import SwiftUI

@main
struct MeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var store = Store.shared

    init() {
        if CommandLine.arguments.contains("--print") {
            PrintMode.runAndExit()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            Text(store.barTitle)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Store.shared.startPolling()
    }
}

extension Store {
    var barTitle: String {
        if config.configError != nil { return "meter" }
        return String(format: "$%.2f", totalToday)
    }
}
