import AppKit
import Combine
import SwiftUI

/// What the panel draws. Kept apart from the live state so that releasing a
/// layer key fades out the layer that was shown instead of redrawing the base
/// layer during the fade.
final class OverlayContent: ObservableObject {
    @Published var layer: Layer?
    @Published var keys: [PhysicalKey] = []
}

/// Floating, click-through panel that shows the held layer's keymap.
final class OverlayController {
    private let panel: NSPanel
    private let state: KeyboardState
    private let content = OverlayContent()
    private let requestState: () -> Void
    private var subscription: AnyCancellable?
    private var watch: Timer?
    private var fadingOut = false
    private var forceHide: DispatchWorkItem?

    init(state: KeyboardState, requestState: @escaping () -> Void) {
        self.state = state
        self.requestState = requestState
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 380),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: OverlayView(state: state, content: content))

        subscription = state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.update() }
    }

    private func update() {
        if let layer = state.overlayLayer, let keymap = state.keymap {
            if content.layer?.id != layer.id || content.layer?.labels != layer.labels { content.layer = layer }
            if content.keys.count != keymap.keys.count { content.keys = keymap.keys }
            setVisible(true)
        } else {
            setVisible(false)
        }
    }

    private func setVisible(_ visible: Bool) {
        watchWhileVisible(visible)
        guard visible != (panel.isVisible && !fadingOut) else { return }
        fadingOut = !visible
        forceHide?.cancel()
        forceHide = nil
        if !visible {
            // Finally: whatever the fade does, the panel is off screen shortly after.
            let hide = DispatchWorkItem { [weak self] in
                guard let self, self.state.overlayLayer == nil else { return }
                self.panel.alphaValue = 0
                self.panel.orderOut(nil)
                self.fadingOut = false
            }
            forceHide = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: hide)
        }
        if visible, !panel.isVisible {
            positionOnActiveScreen()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = visible ? 0.08 : 0.15
            panel.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self, !visible, self.fadingOut else { return }
            self.panel.orderOut(nil)
            self.fadingOut = false
        })
    }

    /// While the overlay is up:
    /// - Shift: it reaches macOS as an ordinary modifier, so read the session's
    ///   modifier state (no Input Monitoring permission needed, unlike an event tap).
    /// - Heartbeat: ask the keyboard for its layer four times a second, so a
    ///   lost "released" report can't leave the overlay up.
    /// - Staleness: if the keyboard stops answering for a second, assume the
    ///   layer was released and hide.
    private func watchWhileVisible(_ visible: Bool) {
        guard visible != (watch != nil) else { return }
        watch?.invalidate()
        watch = nil
        guard visible else {
            if state.shiftHeld { state.shiftHeld = false }
            return
        }
        var tick = 0
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let held = CGEventSource.flagsState(.combinedSessionState).contains(.maskShift)
            if held != self.state.shiftHeld { self.state.shiftHeld = held }

            tick += 1
            if tick % 8 == 0 { self.requestState() }
            if let last = self.state.lastReport, Date().timeIntervalSince(last) > 1.0 {
                self.state.activeLayer = 0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timer.fire()
        watch = timer
    }

    /// Bottom centre of the screen the pointer is on.
    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 40))
    }
}

struct OverlayView: View {
    @ObservedObject var state: KeyboardState
    @ObservedObject var content: OverlayContent

    var body: some View {
        if let layer = content.layer {
            panel(layer)
        }
    }

    private func panel(_ layer: Layer) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text(state.shiftHeld ? "\(layer.name) + ⇧" : layer.name).font(.system(size: 17, weight: .semibold))
                Spacer()
                StatusLine(state: state).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            KeyboardCanvas(keys: content.keys, labels: state.shiftHeld ? layer.shifted : layer.labels)
        }
        .padding(18)
        .frame(width: 860, height: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
    }
}

struct StatusLine: View {
    @ObservedObject var state: KeyboardState

    var body: some View {
        HStack(spacing: 12) {
            if let profile = state.profile {
                Text("BT\(profile + 1)")
            }
            Text("L \(state.leftBattery.map { "\($0)%" } ?? "–")")
            Text("R \(state.rightBattery.map { "\($0)%" } ?? "–")")
        }
        .monospacedDigit()
    }
}

/// Draws the physical layout, rotating keys the way ZMK's physical layout
/// does: each key's rect is rotated by `r` around (`rx`, `ry`).
struct KeyboardCanvas: View {
    let keys: [PhysicalKey]
    let labels: [String]

    var body: some View {
        Canvas { context, size in
            let bounds = Self.bounds(of: keys)
            guard !bounds.isEmpty else { return }
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            let inset = CGSize(
                width: (size.width - bounds.width * scale) / 2,
                height: (size.height - bounds.height * scale) / 2
            )
            for (i, key) in keys.enumerated() {
                var ctx = context
                ctx.translateBy(x: inset.width - bounds.minX * scale, y: inset.height - bounds.minY * scale)
                ctx.scaleBy(x: scale, y: scale)
                if key.r != 0 {
                    ctx.translateBy(x: CGFloat(key.rx), y: CGFloat(key.ry))
                    ctx.rotate(by: .degrees(Double(key.r) / 100))
                    ctx.translateBy(x: -CGFloat(key.rx), y: -CGFloat(key.ry))
                }
                let rect = CGRect(x: key.x, y: key.y, width: key.w, height: key.h).insetBy(dx: 5, dy: 5)
                let label = i < labels.count ? labels[i] : ""
                let path = Path(roundedRect: rect, cornerRadius: 12)
                ctx.fill(path, with: .color(.white.opacity(label.isEmpty ? 0.05 : 0.14)))
                ctx.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: 1.5)
                if !label.isEmpty {
                    let fontSize: CGFloat = label.count > 3 ? 22 : 32
                    ctx.draw(
                        Text(label).font(.system(size: fontSize, weight: .medium)).foregroundColor(.white),
                        at: CGPoint(x: rect.midX, y: rect.midY)
                    )
                }
            }
        }
    }

    /// Union of every key's rotated corners, in layout units.
    static func bounds(of keys: [PhysicalKey]) -> CGRect {
        var box = CGRect.null
        for key in keys {
            var transform = CGAffineTransform.identity
            if key.r != 0 {
                transform = transform
                    .translatedBy(x: CGFloat(key.rx), y: CGFloat(key.ry))
                    .rotated(by: CGFloat(key.r) / 100 * .pi / 180)
                    .translatedBy(x: -CGFloat(key.rx), y: -CGFloat(key.ry))
            }
            box = box.union(CGRect(x: key.x, y: key.y, width: key.w, height: key.h).applying(transform))
        }
        return box
    }
}
