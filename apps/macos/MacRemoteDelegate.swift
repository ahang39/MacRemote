import AppKit
import Foundation
import SwiftUI

@MainActor
final class MacRemoteDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var settingsPopover: NSPopover?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var wakeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var reanchorWork: DispatchWorkItem?
    private var shouldReopenAfterModeChange = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "desktopcomputer",
                accessibilityDescription: "MacRemote"
            )
            button.image?.isTemplate = true
            button.toolTip = "MacRemote settings"
            button.target = self
            button.action = #selector(toggleSettingsPopover)
        }
        statusItem = item
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in MacRemoteController.shared.refresh() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reanchorSettingsAfterDisplayChange() }
        }
        MacRemoteController.shared.refresh()
        // Used only for a controlled in-place application update: relaunch
        // the existing native server with the same saved graphics/port settings.
        if ProcessInfo.processInfo.arguments.contains("--start-server") {
            DispatchQueue.main.async {
                MacRemoteController.shared.start()
            }
        }
    }

    // macOS may keep an NSPopover's old screen-relative anchor after a
    // HiDPI mode switch. Recreate it only once the menu bar has settled.
    private func reanchorSettingsAfterDisplayChange() {
        DisplayOutputSettings.shared.refreshDisplayState()
        shouldReopenAfterModeChange = shouldReopenAfterModeChange ||
            (settingsPopover?.isShown == true)
        reanchorWork?.cancel()
        settingsPopover?.close()
        settingsPopover = nil
        removeOutsideClickMonitors()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reanchorWork = nil
            if self.shouldReopenAfterModeChange {
                self.shouldReopenAfterModeChange = false
                self.showSettingsPopover()
            }
        }
        reanchorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    @objc private func toggleSettingsPopover() {
        reanchorWork?.cancel()
        reanchorWork = nil
        shouldReopenAfterModeChange = false
        if settingsPopover?.isShown == true {
            settingsPopover?.performClose(nil)
        } else {
            showSettingsPopover()
        }
    }

    private func showSettingsPopover() {
        guard let button = statusItem?.button else { return }
        if settingsPopover?.isShown == true { return }

        MacRemoteController.shared.refresh()
        if settingsPopover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self
            let hosting = NSHostingController(rootView: MacRemoteMenu())
            hosting.sizingOptions = [.preferredContentSize]
            popover.contentViewController = hosting
            settingsPopover = popover
        }
        settingsPopover?.show(
            relativeTo: button.bounds, of: button, preferredEdge: .minY
        )
        monitorOutsideClicks()
    }

    private func monitorOutsideClicks() {
        removeOutsideClickMonitors()
        let clicks: NSEvent.EventTypeMask =
            [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        // NSPopover.transient handles standard focus changes. A menu bar
        // accessory app can remain inactive while the user clicks in a
        // different app; explicitly close in that situation as well.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) {
            [weak self] _ in
            self?.settingsPopover?.performClose(nil)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) {
            [weak self] event in
            guard let self = self, self.settingsPopover?.isShown == true else {
                return event
            }
            let popoverWindow = self.settingsPopover?.contentViewController?.view.window
            let statusWindow = self.statusItem?.button?.window
            if event.window !== popoverWindow && event.window !== statusWindow {
                self.settingsPopover?.performClose(nil)
            }
            return event
        }
    }

    private func removeOutsideClickMonitors() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitors()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        // Finder/Spotlight and the menu bar icon use the same dismissible UI.
        showSettingsPopover()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        reanchorWork?.cancel()
        removeOutsideClickMonitors()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        MacRemoteController.shared.stop()
    }
}
