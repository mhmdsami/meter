import SwiftUI
import Combine

@main
struct MeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        if PrintMode.requested {
            PrintMode.runAndExit()
        }
    }

    // Menu bar chrome is AppKit (NSStatusItem + NSPopover): SwiftUI's MenuBarExtra
    // window style draws an internal panel whose rounded mask (a private
    // _cornerMask) stops being applied once the content is tall enough for the
    // panel to be clamped near the screen edge. A popover keeps standard chrome.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []
    private var outsideClickMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuContent())
        // activating the app on click stops .transient from seeing outside clicks
        NotificationCenter.default.addObserver(self, selector: #selector(dismissPopover),
                                               name: NSApplication.didResignActiveNotification,
                                               object: nil)
        // NSPopover has no public API for its anchor arrow; the private
        // shouldHideAnchor flag is the established workaround, guarded so a
        // future OS dropping it just leaves the arrow in place.
        if popover.responds(to: NSSelectorFromString("setShouldHideAnchor:")) {
            popover.setValue(true, forKey: "shouldHideAnchor")
        }
        updateTitle()

        Store.shared.$readings
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        Store.shared.$config
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)

        Store.shared.startPolling()
    }

    private func updateTitle() {
        statusItem?.button?.title = Store.shared.barTitle
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // size to the SwiftUI content so the popover hugs it
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let fitting = view.fittingSize
            popover.contentSize = NSSize(width: max(300, fitting.width), height: max(100, fitting.height))
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()
        startOutsideClickMonitor()
    }

    @objc private func dismissPopover() {
        popover.performClose(nil)
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitor()
    }
}

extension Store {
    var barTitle: String {
        if config.configError != nil { return "meter" }
        return String(format: "$%.2f", totalToday)
    }
}
