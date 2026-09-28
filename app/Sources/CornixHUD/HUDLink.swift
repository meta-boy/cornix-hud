import Foundation
import IOKit.hid

/// Receives layer and BLE profile state from the keyboard's raw HID channel.
///
/// Protocol (see firmware/zmk/src/cornix_hud.c), 32-byte reports:
///   keyboard -> host: [0xCD, version, 0x01, layerMask(4, LE), highestLayer, profile, connected]
///   host -> keyboard: [0xCD, 0x01] asks for the current state
final class HUDLink {
    private static let vendorID = 0x1D50  // ZMK Project
    private static let productID = 0x615E
    private static let usagePage = 0xFF60
    private static let usage = 0x61
    private static let reportSize = 32
    private static let magic: UInt8 = 0xCD

    private let state: KeyboardState
    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportSize)
    /// A Bluetooth HID write can block for milliseconds; keep it off the main thread.
    private let sendQueue = DispatchQueue(label: "cornix-hud.hid-send")

    init(state: KeyboardState) {
        self.state = state
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDProductIDKey: Self.productID,
            kIOHIDPrimaryUsagePageKey: Self.usagePage,
            kIOHIDPrimaryUsageKey: Self.usage,
        ] as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<HUDLink>.fromOpaque(context!).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<HUDLink>.fromOpaque(context!).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func attach(_ device: IOHIDDevice) {
        self.device = device
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, Self.reportSize, { context, _, _, _, _, report, length in
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            Unmanaged<HUDLink>.fromOpaque(context!).takeUnretainedValue().handle(bytes)
        }, context)
        requestState()
    }

    private func detach(_ device: IOHIDDevice) {
        guard device == self.device else { return }
        self.device = nil
        state.hudLinked = false
        state.activeLayer = 0
        state.profile = nil
    }

    func requestState() {
        guard let device else { return }
        var request = [UInt8](repeating: 0, count: Self.reportSize)
        request[0] = Self.magic
        request[1] = 0x01
        sendQueue.async {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, request, request.count)
        }
    }

    private func handle(_ report: [UInt8]) {
        guard report.count >= 10, report[0] == Self.magic, report[2] == 0x01 else { return }
        state.lastReport = Date()
        // Only publish changes: the overlay's heartbeat asks four times a second.
        func set<T: Equatable>(_ path: ReferenceWritableKeyPath<KeyboardState, T>, _ value: T) {
            if state[keyPath: path] != value { state[keyPath: path] = value }
        }
        set(\.hudLinked, true)
        set(\.activeLayer, Int(report[7]))
        set(\.profile, Int(report[8]))
        set(\.profileConnected, report[9] != 0)
    }
}
