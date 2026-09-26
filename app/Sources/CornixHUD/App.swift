import AppKit
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
        link = HUDLink(state: state)
        overlay = OverlayController(state: state)
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
        Button("Quit Cornix HUD") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
