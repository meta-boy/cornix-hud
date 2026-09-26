import Foundation

struct PhysicalKey: Codable {
    let w, h, x, y, r, rx, ry: Int
}

struct Layer: Codable {
    let id: Int
    let name: String
    let labels: [String]
    /// What each key types with Shift held.
    let shifted: [String]
}

/// The keymap as read from the keyboard: physical keys in ZMK units
/// (100 = 1u, rotation in hundredths of a degree) and each layer's labels.
struct LoadedKeymap: Codable {
    let keys: [PhysicalKey]
    let layers: [Layer]

    func layer(id: Int) -> Layer? { layers.first { $0.id == id } }
}

/// Everything the UI shows. Written only on the main thread.
final class KeyboardState: ObservableObject {
    static let shared = KeyboardState()

    @Published var leftBattery: Int?
    @Published var rightBattery: Int?

    @Published var keymap: LoadedKeymap?
    @Published var keymapStatus: String

    /// Set once the HUD firmware answers over raw HID.
    @Published var hudLinked = false
    @Published var activeLayer = 0
    @Published var profile: Int?
    @Published var profileConnected = false
    @Published var shiftHeld = false

    init() {
        let cached = KeymapLoader.cached()
        keymap = cached
        keymapStatus = cached == nil ? "not loaded yet" : "from last session"
    }

    /// The overlay shows only while a non-base layer is held.
    var overlayLayer: Layer? {
        guard activeLayer != 0 else { return nil }
        return keymap?.layer(id: activeLayer)
    }
}
