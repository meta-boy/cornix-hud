import CoreBluetooth
import Foundation

/// Minimal ZMK Studio RPC client over the Studio GATT characteristic.
///
/// Wire format (zmk/app/src/studio/msg_framing.c): each protobuf message is
/// framed as SOF, payload, EOF, with any SOF/ESC/EOF byte in the payload
/// preceded by ESC. Responses arrive as indications of ~20 bytes that are
/// reassembled here. Messages follow zmk-studio-messages' studio.proto.
final class StudioRPC {
    static let service = CBUUID(string: "00000000-0196-6107-C967-C5CFB1C2482A")
    static let characteristic = CBUUID(string: "00000001-0196-6107-C967-C5CFB1C2482A")

    enum Subsystem: Int { case core = 3, behaviors = 4, keymap = 5 }

    struct RPCError: Error, CustomStringConvertible {
        let description: String
    }

    private static let sof: UInt8 = 0xAB, esc: UInt8 = 0xAC, eof: UInt8 = 0xAD

    private let peripheral: CBPeripheral
    private let rpc: CBCharacteristic
    private var nextID: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<ProtoMessage, Error>] = [:]
    private var frame: [UInt8]?
    private var escaped = false

    /// Called with the keymap subsystem's notification payload.
    var onKeymapNotification: ((ProtoMessage) -> Void)?

    init(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        self.peripheral = peripheral
        rpc = characteristic
    }

    /// Sends one request and returns the subsystem's response message.
    func call(_ subsystem: Subsystem, _ request: ProtoWriter) async throws -> ProtoMessage {
        let id = nextID
        nextID += 1
        var envelope = ProtoWriter()
        envelope.varint(1, UInt64(id))
        envelope.message(subsystem.rawValue, request)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            peripheral.writeValue(Self.frame(envelope.data), for: rpc, type: .withResponse)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.pending.removeValue(forKey: id)?.resume(throwing: RPCError(description: "request \(id) timed out"))
            }
        }
    }

    func cancelAll() {
        let waiting = pending
        pending = [:]
        waiting.values.forEach { $0.resume(throwing: RPCError(description: "disconnected")) }
    }

    /// Feed bytes from each indication of the RPC characteristic.
    func receive(_ data: Data) {
        for byte in data {
            if frame == nil {
                if byte == Self.sof { frame = [] }
                continue
            }
            if escaped {
                frame!.append(byte)
                escaped = false
            } else if byte == Self.esc {
                escaped = true
            } else if byte == Self.eof {
                let payload = frame!
                frame = nil
                handle(ProtoMessage(Data(payload)))
            } else if byte == Self.sof {
                frame = []
            } else {
                frame!.append(byte)
            }
        }
    }

    private func handle(_ response: ProtoMessage) {
        if let reply = response.message(1) {
            let id = UInt32(reply.uint(1) ?? 0)
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let meta = reply.message(2) {
                let code = meta.uint(2).map { "error \($0)" } ?? "no response"
                continuation.resume(throwing: RPCError(description: "request \(id): \(code)"))
            } else if let body = reply.message(3) ?? reply.message(4) ?? reply.message(5) {
                continuation.resume(returning: body)
            } else {
                continuation.resume(throwing: RPCError(description: "request \(id): empty reply"))
            }
        } else if let notification = response.message(2), let keymap = notification.message(5) {
            onKeymapNotification?(keymap)
        }
    }

    private static func frame(_ payload: Data) -> Data {
        var out = Data([sof])
        for byte in payload {
            if byte == sof || byte == esc || byte == eof { out.append(esc) }
            out.append(byte)
        }
        out.append(eof)
        return out
    }
}

// MARK: - Protobuf, just enough for Studio's messages

struct ProtoWriter {
    private(set) var data = Data()

    mutating func varint(_ field: Int, _ value: UInt64) {
        key(field, wire: 0)
        Self.appendVarint(value, to: &data)
    }

    mutating func bool(_ field: Int) { varint(field, 1) }

    mutating func message(_ field: Int, _ message: ProtoWriter) {
        key(field, wire: 2)
        Self.appendVarint(UInt64(message.data.count), to: &data)
        data.append(message.data)
    }

    private mutating func key(_ field: Int, wire: Int) {
        Self.appendVarint(UInt64(field << 3 | wire), to: &data)
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }
}

/// Decoded fields of one message: varints and length-delimited bytes, by
/// field number, in wire order. Fixed32/64 fields are skipped (Studio has none).
struct ProtoMessage {
    private var varints: [Int: [UInt64]] = [:]
    private var bytes: [Int: [Data]] = [:]

    init(_ data: Data) {
        let b = [UInt8](data)
        var i = 0
        func readVarint() -> UInt64? {
            var value: UInt64 = 0, shift: UInt64 = 0
            while i < b.count {
                let byte = b[i]
                i += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while i < b.count, let key = readVarint() {
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = readVarint() else { return }
                varints[field, default: []].append(v)
            case 2:
                guard let len = readVarint(), i + Int(len) <= b.count else { return }
                bytes[field, default: []].append(Data(b[i ..< i + Int(len)]))
                i += Int(len)
            case 5: i += 4
            case 1: i += 8
            default: return
            }
        }
    }

    func uint(_ field: Int) -> UInt64? { varints[field]?.last }
    func sint(_ field: Int) -> Int? { uint(field).map(Self.zigzag) }
    func string(_ field: Int) -> String? { bytes[field]?.last.flatMap { String(data: $0, encoding: .utf8) } }
    func message(_ field: Int) -> ProtoMessage? { bytes[field]?.last.map(ProtoMessage.init) }
    func messages(_ field: Int) -> [ProtoMessage] { (bytes[field] ?? []).map(ProtoMessage.init) }

    /// Packed repeated varints (proto3 default) or unpacked ones.
    func uints(_ field: Int) -> [UInt64] {
        (varints[field] ?? []) + (bytes[field] ?? []).flatMap(Self.unpack)
    }

    private static func unpack(_ data: Data) -> [UInt64] {
        var out: [UInt64] = [], value: UInt64 = 0, shift: UInt64 = 0
        for byte in data {
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                out.append(value)
                value = 0
                shift = 0
            } else {
                shift += 7
            }
        }
        return out
    }

    private static func zigzag(_ v: UInt64) -> Int {
        Int(Int64(bitPattern: (v >> 1) ^ (0 &- (v & 1))))
    }
}
