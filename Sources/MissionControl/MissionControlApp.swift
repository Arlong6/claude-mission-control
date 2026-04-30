import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement

/// Bridge so the global hotkey (Carbon callback) can drive SwiftUI window opening.
final class WindowBridge {
    static let shared = WindowBridge()
    var openMain: (() -> Void)?

    func bringToFront() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { ($0.identifier?.rawValue ?? "").contains("main") || $0.title == "Mission Control" }) {
            if !window.isVisible { window.makeKeyAndOrderFront(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMain?()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        GlobalHotkey.shared.registerCmdShiftM { WindowBridge.shared.bringToFront() }
        AttachmentStore.sweepOld()
    }
}

@main
struct MissionControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = ProjectStore()
    @StateObject private var settings = AppSettings()

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    var body: some Scene {
        // Real movable window — opens on launch and can be re-opened from menubar
        Window("Mission Control", id: "main") {
            RootView()
                .environmentObject(store)
                .environmentObject(settings)
                .frame(minWidth: 760, minHeight: 480)
                .onAppear {
                    store.startAutoRefresh()
                    settings.applyLoginItem()
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .background(WindowOpenerCapture())
        }
        .defaultSize(width: 1000, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {} // no "New Window"
        }

        // Menubar launcher (just a menu, not a popover)
        MenuBarExtra("Claude", systemImage: "sparkles") {
            MenuBarLauncher()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Hidden helper view that captures the SwiftUI openWindow action into WindowBridge,
/// so the Carbon hotkey can re-open the window after it's been closed.
struct WindowOpenerCapture: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                WindowBridge.shared.openMain = { openWindow(id: "main") }
            }
    }
}

struct MenuBarLauncher: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        Button("Open Mission Control  ⌘⇧M") {
            WindowBridge.shared.openMain = { openWindow(id: "main") }
            WindowBridge.shared.bringToFront()
        }

        Divider()

        if store.hasAnyError {
            Text("⚠️ \(store.projects.filter { $0.meta.hasError }.count) project(s) with errors")
                .foregroundStyle(.red)
        }
        Text("\(store.projects.count) projects")

        Divider()

        Button("Refresh") { store.refresh() }
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}

final class AppSettings: ObservableObject {
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = true {
        didSet { applyLoginItem() }
    }

    func applyLoginItem() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            // self-use: silently swallow — user can toggle in Settings
        }
    }
}
