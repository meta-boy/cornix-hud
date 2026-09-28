import AppKit
import ServiceManagement
import SwiftUI

@main
struct CornixHUDApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @ObservedObject private var state = KeyboardState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state, link: delegate.link, ble: delegate.ble)
        } label: {
            Image(systemName: "keyboard")
            StatusLine(state: state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var link: HUDLink?
    private(set) var ble: KeyboardBLE?
    private var overlay: OverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = KeyboardState.shared
        ble = KeyboardBLE(state: state)
        let link = HUDLink(state: state)
        self.link = link
        overlay = OverlayController(state: state) { [weak link] in link?.requestState() }

        // Never leave a layer showing across sleep or a locked screen.
        let reset: (Notification) -> Void = { _ in state.activeLayer = 0 }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main, using: reset)
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: reset)
    }
}

struct MenuContent: View {
    @ObservedObject var state: KeyboardState
    let link: HUDLink?
    let ble: KeyboardBLE?

    var body: some View {
        Text("Left: \(state.leftBattery.map { "\($0)%" } ?? "not connected")")
        Text("Right: \(state.rightBattery.map { "\($0)%" } ?? "not connected")")
        if let profile = state.profile {
            Text("Bluetooth profile \(profile + 1)\(state.profileConnected ? "" : " (not connected)")")
        }
        Text(state.hudLinked ? "Live layer: \(state.keymap?.layer(id: state.activeLayer)?.name ?? "\(state.activeLayer)")"
                             : "Live layer: waiting for HUD firmware")
        Text("Keymap: \(state.keymapStatus)")
        Divider()
        Button("Reload keymap from keyboard") { ble?.reloadKeymap() }
        Button("Resync layer state") { link?.requestState() }
        Divider()
        Toggle("Open at Login", isOn: Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
        ))
        Divider()
        Button("Quit Cornix HUD") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
