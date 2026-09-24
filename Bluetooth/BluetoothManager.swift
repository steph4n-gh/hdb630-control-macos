import Foundation
@preconcurrency import IOBluetooth
import Combine
import os.log

private let btLog = OSLog(subsystem: "com.hdb630.control", category: "bluetooth")

private func BTLog(_ format: String, _ args: CVarArg...) {
    let msg = String(format: format, arguments: args)
    os_log("%{private}s", log: btLog, type: .default, msg)
}

private func BTTrace(_ format: String, _ args: CVarArg...) {
    let msg = String(format: format, arguments: args)
    os_log("%{private}s", log: btLog, type: .debug, msg)
}

// MARK: - Bluetooth Manager

final class BluetoothManager: NSObject, ObservableObject, @unchecked Sendable {
    @Published var state: ConnectionState = .disconnected
    @Published var pairedDevices: [IOBluetoothDevice] = []
    @Published private(set) var userDisconnected = false
    private var scanID = UUID()

    private var rfcommChannel: IOBluetoothRFCOMMChannel?
    private var rfcommOpenID = UUID()
    private var receiveBuffer = Data()

    private var pendingCallbacks: [String: (GAIAProtocol.Response) -> Void] = [:]
    var notificationHandler: ((GAIAProtocol.Response) -> Void)?
    private let queue = DispatchQueue(label: "bluetooth.gaia", qos: .userInitiated)

    private var sigTermSource: DispatchSourceSignal?

    override init() {
        super.init()
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            BTLog("[BT] SIGTERM received, disconnecting...")
            self?.disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
        }
        source.resume()
        sigTermSource = source
    }

    // MARK: - Device Discovery

    func scanForDevices() {
        let request = UUID()
        scanID = request
        state = .scanning
        BTLog("[BT] Scanning for paired devices...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.scanID == request, self.state == .scanning else { return }
            self.state = .error("Bluetooth discovery timed out. You can still use the BTD 700 tab.")
        }
        // IOBluetooth can wait for CoreBluetooth initialization. Keep the menu bar UI responsive.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
                DispatchQueue.main.async {
                    BTLog("[BT] ERROR: Cannot access paired devices")
                    guard let self, self.scanID == request else { return }
                    self.state = .error("Cannot access paired devices. Check Bluetooth permission.")
                }
                return
            }

            let matching = devices.filter { device in
                let name = device.name ?? ""
                return name.localizedCaseInsensitiveContains("HDB") ||
                       name.localizedCaseInsensitiveContains("Sennheiser") ||
                       name.localizedCaseInsensitiveContains("630")
            }
            DispatchQueue.main.async {
                guard let self, self.scanID == request else { return }
                BTLog("[BT] Found %d total paired devices", devices.count)
                BTLog("[BT] Filtered to %d matching devices", matching.count)
                self.pairedDevices = matching
                self.state = .disconnected
            }
        }
    }

    // MARK: - SDP Channel Discovery

    private func findGAIAChannel(_ device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        guard let services = device.services as? [IOBluetoothSDPServiceRecord] else {
            BTLog("[BT] No SDP service records available")
            return nil
        }

        // Known GAIA service UUIDs (standard Qualcomm + HDB 630 vendor-specific)
        let knownGAIAUUIDs: [IOBluetoothSDPUUID] = [
            IOBluetoothSDPUUID(data: Data(GAIAProtocol.serviceUUIDBytes)),
            IOBluetoothSDPUUID(data: Data([0x11, 0x07])),
            IOBluetoothSDPUUID(data: Data(GAIAProtocol.hdb630ServiceUUIDBytes)),
        ]

        // Known non-GAIA UUIDs to exclude
        let excludedUUIDs: [IOBluetoothSDPUUID] = [
            IOBluetoothSDPUUID(data: Data([0x11, 0x1E])),  // HFP
            IOBluetoothSDPUUID(data: Data([0x12, 0x03])),  // Generic Audio
            IOBluetoothSDPUUID(data: Data([               // Airoha RACE (DECA-FADE)
                0x00, 0x00, 0x00, 0x00, 0xDE, 0xCA, 0xFA, 0xDE,
                0xDE, 0xCA, 0xDE, 0xAF, 0xDE, 0xCA, 0xCA, 0xFF
            ])),
        ]

        BTLog("[BT] Searching %d SDP services for GAIA UUID...", services.count)

        var candidateChannel: BluetoothRFCOMMChannelID?

        for service in services {
            var channelID: BluetoothRFCOMMChannelID = 0
            guard service.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { continue }

            // Get ServiceClassIDList (attr 0x0001)
            // May be a single UUID or an array of UUIDs
            guard let serviceClassElem = service.getAttributeDataElement(0x0001) else {
                BTLog("[BT] SDP ch%d: no ServiceClassIDList", channelID)
                continue
            }

            // Collect UUIDs from this service record
            var uuids: [IOBluetoothSDPUUID] = []
            if let uuid = serviceClassElem.getUUIDValue() {
                uuids.append(uuid)
            } else if let elements = serviceClassElem.getArrayValue() {
                for elem in elements {
                    if let sdpElem = elem as? IOBluetoothSDPDataElement,
                       let uuid = sdpElem.getUUIDValue() {
                        uuids.append(uuid)
                    }
                }
            }

            for uuid in uuids {
                let uuidHex = (uuid as Data).map { String(format: "%02X", $0) }.joined()
                BTLog("[BT] SDP ch%d: UUID %@", channelID, uuidHex)

                // Check for known GAIA UUIDs
                for gaiaUUID in knownGAIAUUIDs {
                    if uuid.isEqual(to: gaiaUUID) {
                        BTLog("[BT] GAIA service matched on RFCOMM channel %d", channelID)
                        return channelID
                    }
                }

                // Track as candidate if not a known non-GAIA service
                let isExcluded = excludedUUIDs.contains { uuid.isEqual(to: $0) }
                if !isExcluded {
                    BTLog("[BT] SDP ch%d: unknown UUID, marking as candidate", channelID)
                    candidateChannel = channelID
                }
            }
        }

        // If no known GAIA UUID matched but we have a single unidentified RFCOMM service, use it
        if let ch = candidateChannel {
            BTLog("[BT] Using candidate RFCOMM channel %d (unrecognized UUID, likely GAIA)", ch)
            return ch
        }

        BTLog("[BT] GAIA service not found in any SDP record")
        return nil
    }

    // MARK: - Connection

    func connect(to device: IOBluetoothDevice) {
        userDisconnected = false
        if let channel = rfcommChannel {
            channel.setDelegate(nil)
            channel.close()
            rfcommChannel = nil
        }
        state = .connecting
        receiveBuffer = Data()

        BTLog("[BT] Connecting to \"%@\" addr=%@", device.name ?? "<nil>", device.addressString ?? "<nil>")

        if !device.isConnected() {
            state = .error("Headphones not connected. Connect them in Bluetooth settings first.")
            return
        }

        // Try to find GAIA channel from cached SDP records
        if let channelID = findGAIAChannel(device) {
            BTLog("[BT] Found GAIA on cached SDP channel %d", channelID)
            openRFCOMM(device: device, channelID: channelID)
        } else {
            // Do SDP query to discover GAIA service
            BTLog("[BT] GAIA not in cached SDP, querying...")
            device.performSDPQuery(self)
        }
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard !userDisconnected, state == .connecting else { return }
        if status == kIOReturnSuccess, let channelID = findGAIAChannel(device) {
            BTLog("[BT] SDP query found GAIA on channel %d", channelID)
            openRFCOMM(device: device, channelID: channelID)
        } else {
            BTLog("[BT] GAIA service not found in SDP (status=%d)", status)
            DispatchQueue.main.async { self.state = .error("GAIA service not found. Try re-pairing headphones.") }
        }
    }

    private func openRFCOMM(device: IOBluetoothDevice, channelID: BluetoothRFCOMMChannelID) {
        let request = UUID()
        rfcommOpenID = request
        BTLog("[BT] Opening RFCOMM channel %d...", channelID)
        var channel: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: self)

        guard result == kIOReturnSuccess, let channel else {
            BTLog("[BT] ERROR: Failed to open RFCOMM channel: %d", result)
            DispatchQueue.main.async { self.state = .error("Failed to open RFCOMM channel: \(result)") }
            return
        }

        rfcommChannel = channel

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.rfcommOpenID == request, self.state == .connecting else { return }
            BTLog("[BT] Connection timeout")
            self.disconnect()
            self.state = .error("Connection timed out. Try power-cycling headphones.")
        }
    }

    func disconnect(userInitiated: Bool = false) {
        rfcommOpenID = UUID()
        if userInitiated { userDisconnected = true }
        BTLog("[BT] Disconnecting...")
        if let channel = rfcommChannel {
            channel.setDelegate(nil)
            channel.close()
        }
        rfcommChannel = nil
        receiveBuffer = Data()
        queue.async { self.pendingCallbacks.removeAll() }
        state = .disconnected
        BTLog("[BT] Disconnected")
    }

    /// Reconnect the same paired device after an explicitly requested settings restart.
    @MainActor func restartAndReconnect() async throws {
        guard let device = rfcommChannel?.getDevice(), state == .connected else {
            throw BluetoothError.notConnected
        }
        _ = try await sendCommand(vendor: GAIAProtocol.vendorSennheiser, command: GAIAProtocol.cmdReboot)
        disconnect()
        state = .connecting
        do {
            try await Task.sleep(nanoseconds: 6_000_000_000)
            guard !userDisconnected else { throw CancellationError() }
            // IOBluetooth's synchronous connection can wait for paging. Keep it off the UI thread.
            let result: IOReturn = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: device.isConnected() ? kIOReturnSuccess : device.openConnection())
                }
            }
            guard !userDisconnected, !Task.isCancelled else { throw CancellationError() }
            guard result == kIOReturnSuccess, device.isConnected() else {
                state = .error("Headphones restarted, but the Mac could not reconnect. Connect HDB 630 in Bluetooth settings.")
                throw BluetoothError.notConnected
            }
            connect(to: device)
        } catch {
            if state == .connecting { state = .disconnected }
            throw error
        }
    }

    // MARK: - Send GAIA Command

    func sendCommand(vendor: UInt16, command: UInt16, payload: [UInt8] = [], timeout: TimeInterval = 5.0) async throws -> GAIAProtocol.Response {
        guard let channel = rfcommChannel, state == .connected else {
            throw BluetoothError.notConnected
        }

        let packet = GAIAProtocol.buildPacket(vendor: vendor, command: command, payload: payload)
        let responseCmd = GAIAProtocol.responseCommandId(for: command)
        let key = GAIAProtocol.callbackKey(vendor: vendor, responseCmd: responseCmd)

        return try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) var resumed = false
            let registered = queue.sync { () -> Bool in
                guard pendingCallbacks[key] == nil else { return false }
                pendingCallbacks[key] = { response in
                    guard !resumed else { return }
                    resumed = true
                    if response.isError {
                        continuation.resume(throwing: BluetoothError.commandError(command))
                    } else {
                        continuation.resume(returning: response)
                    }
                }
                return true
            }
            guard registered else {
                continuation.resume(throwing: BluetoothError.commandInFlight(command))
                return
            }

            var bytes = [UInt8](packet)
            BTTrace("[BT] TX %d bytes: %@", bytes.count, bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
            let result = channel.writeSync(&bytes, length: UInt16(bytes.count))
            if result != kIOReturnSuccess {
                queue.async { [weak self] in
                    guard !resumed else { return }
                    resumed = true
                    self?.pendingCallbacks.removeValue(forKey: key)
                    continuation.resume(throwing: BluetoothError.writeFailed(result))
                }
                return
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard !resumed else { return }
                resumed = true
                self?.pendingCallbacks.removeValue(forKey: key)
                continuation.resume(throwing: BluetoothError.timeout)
            }
        }
    }
}

// MARK: - RFCOMM Channel Delegate

extension BluetoothManager: IOBluetoothRFCOMMChannelDelegate {
    func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        let newData = Data(bytes: dataPointer, count: dataLength)
        BTTrace("[BT] RX %d bytes: %@", dataLength, newData.map { String(format: "%02X", $0) }.joined(separator: " "))
        queue.async { [weak self] in
            self?.handleReceivedData(newData)
        }
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        BTLog("[BT] rfcommChannelOpenComplete — status: %d (0=success)", error)
        DispatchQueue.main.async {
            guard !self.userDisconnected, self.rfcommChannel === rfcommChannel else { return }
            if error == kIOReturnSuccess {
                BTLog("[BT] RFCOMM channel opened, connected")
                self.state = .connected
            } else {
                BTLog("[BT] ERROR: RFCOMM channel open failed: %d", error)
                rfcommChannel.setDelegate(nil)
                rfcommChannel.close()
                self.rfcommChannel = nil
                self.state = .error("RFCOMM channel open failed: \(error)")
            }
        }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        BTLog("[BT] RFCOMM channel closed")
        DispatchQueue.main.async {
            self.rfcommChannel = nil
            if self.state == .connected {
                self.state = .disconnected
            }
        }
    }

    // MARK: - GAIA v3 Packet Parser

    private func handleReceivedData(_ data: Data) {
        receiveBuffer.append(data)

        while receiveBuffer.count >= GAIAProtocol.headerSize {
            // Look for FF 03 header
            guard receiveBuffer[receiveBuffer.startIndex] == 0xFF,
                  receiveBuffer[receiveBuffer.startIndex + 1] == 0x03 else {
                receiveBuffer = Data(receiveBuffer.dropFirst(1))
                continue
            }

            guard let (response, consumed) = GAIAProtocol.parse(receiveBuffer) else {
                // Not enough data yet — wait for more
                break
            }

            receiveBuffer = Data(receiveBuffer.dropFirst(consumed))

            BTTrace("[BT] GAIA vendor=0x%04X cmd=0x%04X payload=%d bytes",
                  response.vendorId, response.commandId, response.payload.count)

            let key = GAIAProtocol.callbackKey(vendor: response.vendorId, responseCmd: response.commandId)
            let errorKey = GAIAProtocol.callbackKey(vendor: response.vendorId,
                                                    responseCmd: response.commandId & ~UInt16(0x0080))
            if let callback = pendingCallbacks.removeValue(forKey: key)
                ?? (response.commandId & 0x0180 == 0x0180 ? pendingCallbacks.removeValue(forKey: errorKey) : nil) {
                callback(response)
            } else {
                // Unsolicited notification
                DispatchQueue.main.async { [weak self] in
                    self?.notificationHandler?(response)
                }
            }
        }
    }
}

// MARK: - Errors

enum BluetoothError: LocalizedError {
    case notConnected
    case writeFailed(IOReturn)
    case timeout
    case commandError(UInt16)
    case commandInFlight(UInt16)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to headphones"
        case .writeFailed(let code): return "Bluetooth write failed: \(code)"
        case .timeout: return "Command timed out"
        case .commandError(let cmd): return "Headphones rejected command 0x\(String(format: "%04X", cmd))"
        case .commandInFlight(let cmd): return "Command 0x\(String(format: "%04X", cmd)) is already in flight"
        }
    }
}
