import Foundation

/// Reads the keymap and physical layout from the keyboard over Studio RPC and
/// turns bindings into keycap labels. The last good read is cached on disk so
/// the overlay works before Studio answers, or when it can't.
enum KeymapLoader {
    static func load(_ rpc: StudioRPC) async throws -> LoadedKeymap {
        var list = ProtoWriter()
        list.bool(1)
        let ids = try await rpc.call(.behaviors, list).message(1)?.uints(1) ?? []

        var behaviorNames: [Int: String] = [:]
        for id in ids {
            var details = ProtoWriter()
            var request = ProtoWriter()
            request.varint(1, id)
            details.message(2, request)
            if let reply = try await rpc.call(.behaviors, details).message(2) {
                behaviorNames[Int(id)] = reply.string(2)
            }
        }

        var getKeymap = ProtoWriter()
        getKeymap.bool(1)
        guard let keymap = try await rpc.call(.keymap, getKeymap).message(1) else {
            throw StudioRPC.RPCError(description: "no keymap in reply")
        }

        var getLayouts = ProtoWriter()
        getLayouts.bool(6)
        guard let layouts = try await rpc.call(.keymap, getLayouts).message(6) else {
            throw StudioRPC.RPCError(description: "no physical layouts in reply")
        }
        let allLayouts = layouts.messages(2)
        let active = Int(layouts.uint(1) ?? 0)
        guard active < allLayouts.count else { throw StudioRPC.RPCError(description: "no active layout") }
        let keys = allLayouts[active].messages(2).map { k in
            PhysicalKey(w: k.sint(1) ?? 100, h: k.sint(2) ?? 100, x: k.sint(3) ?? 0, y: k.sint(4) ?? 0,
                        r: k.sint(5) ?? 0, rx: k.sint(6) ?? 0, ry: k.sint(7) ?? 0)
        }

        let rawLayers = keymap.messages(1)
        let layerNames = Dictionary(rawLayers.map { (Int($0.uint(1) ?? 0), $0.string(2) ?? "") },
                                    uniquingKeysWith: { a, _ in a })
        let bindings = rawLayers.map { layer in
            layer.messages(3).map { Binding(behavior: behaviorNames[$0.sint(1) ?? -1] ?? "?",
                                            param1: UInt32($0.uint(2) ?? 0), param2: UInt32($0.uint(3) ?? 0)) }
        }
        let base = bindings.first ?? []
        let layers = zip(rawLayers, bindings).map { raw, layerBindings in
            let id = Int(raw.uint(1) ?? 0)
            // Transparent keys fall through; show what the base layer has there.
            let resolved = layerBindings.enumerated().map { i, b in
                b.behavior == "Transparent" && i < base.count ? base[i] : b
            }
            return Layer(
                id: id,
                name: layerNames[id].flatMap { $0.isEmpty ? nil : $0 } ?? "Layer \(id)",
                labels: resolved.map { $0.label(layerNames: layerNames, shifted: false) },
                shifted: resolved.map { $0.label(layerNames: layerNames, shifted: true) }
            )
        }
        return LoadedKeymap(keys: keys, layers: layers)
    }

    // MARK: Cache

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CornixHUD", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("keymap.json")
    }

    static func cached() -> LoadedKeymap? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(LoadedKeymap.self, from: data)
    }

    static func save(_ keymap: LoadedKeymap) {
        if let data = try? JSONEncoder().encode(keymap) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}

/// One key's binding, with its behavior resolved to Studio's display name.
private struct Binding {
    let behavior: String
    let param1: UInt32
    let param2: UInt32

    func label(layerNames: [Int: String], shifted: Bool) -> String {
        switch behavior {
        case "None", "Transparent":
            return ""
        case "Key Press":
            return HIDLabels.label(param1, shifted: shifted)
        case "Momentary Layer", "Toggle Layer", "To Layer", "Sticky Layer":
            return layerNames[Int(param1)].flatMap { $0.isEmpty ? nil : $0 } ?? "L\(param1)"
        case "Layer-Tap":
            return "\(layerNames[Int(param1)] ?? "L\(param1)")/\(HIDLabels.label(param2, shifted: shifted))"
        case "Mod-Tap":
            return HIDLabels.label(param2, shifted: shifted)
        case "Bluetooth":
            // zmk/bt.h commands: 0 clear, 1 next, 2 prev, 3 select, 4 clear all, 5 disconnect
            switch param1 {
            case 0: return "BT Clr"
            case 1: return "BT →"
            case 2: return "BT ←"
            case 3: return "BT\(param2 + 1)"
            case 4: return "BT Clr All"
            default: return "BT Off\(param2 + 1)"
            }
        case "Mouse Key Press":
            return [1: "Left", 2: "Right", 4: "Mid", 8: "Back", 16: "Fwd"][param1] ?? "Mouse"
        case "Bootloader":
            return "Boot"
        case "Reset":
            return "Reset"
        case "Caps Word":
            return "Caps W"
        default:
            return behavior
        }
    }
}

/// HID usage → keycap label. ZMK packs a usage as (page << 16 | id) with any
/// implicit modifiers (e.g. LS(N1) for "!") in the top byte.
enum HIDLabels {
    private static let keyboard: [UInt32: String] = {
        var m: [UInt32: String] = [:]
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { m[0x04 + UInt32(i)] = String(c) }
        for (i, c) in "1234567890".enumerated() { m[0x1E + UInt32(i)] = String(c) }
        for i in 0 ..< 12 { m[0x3A + UInt32(i)] = "F\(i + 1)" }
        for i in 0 ..< 12 { m[0x68 + UInt32(i)] = "F\(i + 13)" }
        let named: [UInt32: String] = [
            0x28: "⏎", 0x29: "Esc", 0x2A: "⌫", 0x2B: "⇥", 0x2C: "␣", 0x2D: "-", 0x2E: "=",
            0x2F: "[", 0x30: "]", 0x31: "\\", 0x33: ";", 0x34: "'", 0x35: "`", 0x36: ",",
            0x37: ".", 0x38: "/", 0x39: "⇪", 0x46: "PrtSc", 0x47: "ScrLk", 0x48: "Pause",
            0x49: "Ins", 0x4A: "Home", 0x4B: "PgUp", 0x4C: "⌦", 0x4D: "End", 0x4E: "PgDn",
            0x4F: "→", 0x50: "←", 0x51: "↓", 0x52: "↑", 0x65: "Menu",
            0xE0: "⌃", 0xE1: "⇧", 0xE2: "⌥", 0xE3: "⌘", 0xE4: "⌃", 0xE5: "⇧", 0xE6: "⌥", 0xE7: "⌘",
        ]
        m.merge(named) { $1 }
        return m
    }()

    private static let shiftedKeyboard: [UInt32: String] = {
        var m: [UInt32: String] = [:]
        for (i, c) in "!@#$%^&*()".enumerated() { m[0x1E + UInt32(i)] = String(c) }
        let pairs: [UInt32: String] = [0x2D: "_", 0x2E: "+", 0x2F: "{", 0x30: "}", 0x31: "|", 0x33: ":",
                                       0x34: "\"", 0x35: "~", 0x36: "<", 0x37: ">", 0x38: "?"]
        m.merge(pairs) { $1 }
        return m
    }()

    private static let consumer: [UInt32: String] = [
        0xE2: "Mute", 0xE9: "Vol+", 0xEA: "Vol−", 0xCD: "⏯", 0xB5: "⏭", 0xB6: "⏮", 0xB7: "⏹",
        0x6F: "Bri+", 0x70: "Bri−",
    ]

    static func label(_ usage: UInt32, shifted: Bool) -> String {
        let mods = usage >> 24
        let page = (usage >> 16) & 0xFF
        let id = usage & 0xFFFF
        let shift = shifted || mods & 0x22 != 0
        var text: String
        switch page {
        case 0x07:
            text = (shift ? shiftedKeyboard[id] : nil) ?? keyboard[id] ?? String(format: "0x%02X", id)
        case 0x0C:
            text = consumer[id] ?? String(format: "C%02X", id)
        default:
            text = String(format: "%X", usage)
        }
        // Implicit modifiers other than Shift (e.g. LG(C)) as a prefix.
        let prefix = [(0x11, "⌃"), (0x44, "⌥"), (0x88, "⌘")].filter { mods & UInt32($0.0) != 0 }.map(\.1).joined()
        return prefix + text
    }
}
