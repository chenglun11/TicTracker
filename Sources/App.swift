import AppKit
import SwiftUI
import Combine
import UserNotifications

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
    static let generateWeeklyReport = Notification.Name("generateWeeklyReport")
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = DataStore()
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up notification delegate
        UNUserNotificationCenter.current().delegate = self

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "\(store.todayTotal)"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        // Set up popover with MenuBarView
        popover.contentSize = NSSize(width: 340, height: 480)
        popover.behavior = .transient
        let vc = NSHostingController(rootView: MenuBarView(store: store))
        vc.preferredContentSize = NSSize(width: 340, height: 480)
        popover.contentViewController = vc

        // Subscribe to record changes to update status bar title
        store.$records
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.statusItem.button?.title = "\(self.store.todayTotal)"
            }
            .store(in: &cancellables)

        // Listen for openSettings notification
        NotificationCenter.default.publisher(for: .openSettings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.openSettingsWindow()
            }
            .store(in: &cancellables)

        // Listen for generateWeeklyReport notification
        NotificationCenter.default.publisher(for: .generateWeeklyReport)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                WeeklyReport.copyToClipboard(from: self.store)
            }
            .store(in: &cancellables)

        // Initialize services
        NotificationManager.shared.requestPermission()
        NotificationManager.shared.refreshReminderIfNeeded()
        NotificationManager.shared.sendWelcome()
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Settings Window

    private func openSettingsWindow() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(store: store)
        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 460)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.alert, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let actionID = response.actionIdentifier

        switch actionID {
        case NotificationManager.actionOpenDaily:
            NSApp.activate(ignoringOtherApps: true)

        case NotificationManager.actionSnooze:
            NotificationManager.shared.snoozeReminder()

        case NotificationManager.actionCopyWeekly:
            WeeklyReport.copyToClipboard(from: store)

        case NotificationManager.actionViewStats:
            NSApp.activate(ignoringOtherApps: true)

        case UNNotificationDefaultActionIdentifier:
            NSApp.activate(ignoringOtherApps: true)

        default:
            break
        }

        completionHandler()
    }
}
