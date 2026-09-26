import CoreBluetooth

/// One GATT connection to the keyboard for two jobs:
///
/// - Battery: ZMK's split battery proxy exposes two Battery Level
///   characteristics, the central's own and one per peripheral tagged with a
///   User Description ("Peripheral 0"). The left half is the central here.
/// - Keymap: the ZMK Studio RPC service, read on connect and again whenever
///   Studio reports the keymap was saved.
final class KeyboardBLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")
    private static let userDescription = CBUUID(string: CBUUIDCharacteristicUserDescriptionString)

    private let state: KeyboardState
    private var central: CBCentralManager!
    private var keyboard: CBPeripheral?
    private var isRightHalf: [CBCharacteristic: Bool] = [:]
    private var studio: StudioRPC?
    private var loading: Task<Void, Never>?
    private var retry: Timer?

    init(state: KeyboardState) {
        self.state = state
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func reloadKeymap() {
        guard let studio else {
            state.keymapStatus = "keyboard not connected"
            return
        }
        loading?.cancel()
        state.keymapStatus = "reading from keyboard…"
        loading = Task { @MainActor [state] in
            do {
                let keymap = try await KeymapLoader.load(studio)
                state.keymap = keymap
                state.keymapStatus = "read from keyboard"
                KeymapLoader.save(keymap)
            } catch {
                state.keymapStatus = "read failed (\(error)); \(state.keymap == nil ? "none cached" : "using last read")"
            }
        }
    }

    private func findKeyboard() {
        guard central.state == .poweredOn, keyboard == nil else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.batteryService])
        guard let found = connected.first(where: { $0.name == "Cornix" }) else { return }
        keyboard = found
        found.delegate = self
        central.connect(found)
    }

    private func reset() {
        keyboard = nil
        isRightHalf = [:]
        studio?.cancelAll()
        studio = nil
        state.leftBattery = nil
        state.rightBattery = nil
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            findKeyboard()
            // The keyboard connects to macOS on its own schedule; keep looking.
            retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.findKeyboard()
            }
        } else {
            retry?.invalidate()
            reset()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.batteryService, StudioRPC.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        reset()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        reset()
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            switch service.uuid {
            case Self.batteryService: peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
            case StudioRPC.service: peripheral.discoverCharacteristics([StudioRPC.characteristic], for: service)
            default: break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.batteryLevel:
                peripheral.discoverDescriptors(for: characteristic)
            case StudioRPC.characteristic:
                let rpc = StudioRPC(peripheral: peripheral, characteristic: characteristic)
                rpc.onKeymapNotification = { [weak self] notification in
                    // unsaved_changes_status_changed = false means Studio just saved.
                    if notification.uint(1) == 0 { self?.reloadKeymap() }
                }
                studio = rpc
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == StudioRPC.characteristic, characteristic.isNotifying {
            reloadKeymap()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        isRightHalf[characteristic] = characteristic.descriptors?.contains { $0.uuid == Self.userDescription } ?? false
        peripheral.setNotifyValue(true, for: characteristic)
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        if characteristic.uuid == StudioRPC.characteristic {
            studio?.receive(value)
            return
        }
        guard let level = value.first, let right = isRightHalf[characteristic] else { return }
        if right {
            state.rightBattery = Int(level)
        } else {
            state.leftBattery = Int(level)
        }
    }
}
