import Foundation
import IOKit.hid
import Combine

// BTD 700 vendor HID report 0x34. Command IDs and packet layout were documented
// by btd700ctl (https://github.com/sobalap/btd700ctl); this is a native IOKit implementation.
@MainActor
final class DongleController: ObservableObject {
    enum AudioMode: UInt8, CaseIterable, Identifiable {
        case highQuality = 0
        case gaming = 1
        case broadcast = 2

        var id: UInt8 { rawValue }
        var title: String {
            switch self {
            case .highQuality: "High Quality"
            case .gaming: "Gaming / Low Latency"
            case .broadcast: "Auracast Broadcast"
            }
        }
    }

    enum Codec: UInt16, CaseIterable, Identifiable {
        case automatic = 0x003F
        case sbc = 0x0001
        case aptX = 0x0002
        case aptXAdaptive = 0x0004
        case aptXLossless = 0x0008
        case aptXLite = 0x0010
        case lc3 = 0x0020

        var id: UInt16 { rawValue }
        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .sbc: "SBC"
            case .aptX: "aptX"
            case .aptXAdaptive: "aptX Adaptive"
            case .aptXLossless: "aptX Lossless"
            case .aptXLite: "aptX Lite"
            case .lc3: "LC3"
            }
        }
    }

    @Published private(set) var available = false
    @Published private(set) var busy = false
    private var activeOperations = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var firmware = ""
    @Published private(set) var connectionState: UInt8 = 0
    @Published private(set) var audioMode: AudioMode = .highQuality
    @Published private(set) var transport: UInt8 = 1
    @Published private(set) var supportedCodecMask: UInt16 = 0
    @Published private(set) var activeCodecMask: UInt16 = 0
    @Published private(set) var bitDepth: UInt8 = 0
    @Published private(set) var sampleRate: UInt8 = 0
    @Published private(set) var leAudioState: UInt8?
    @Published private(set) var sinkTransport: UInt8?

    var connectionDescription: String {
        switch connectionState {
        case 0, 1: "Disconnected"
        case 2: "Connected"
        case 3: "Streaming audio"
        case 4: "Streaming voice"
        default: "Unknown"
        }
    }

    var qualityDescription: String {
        guard connectionState >= 2 else { return "—" }
        let bits = bitDepth == 2 ? "24 bit" : bitDepth == 1 ? "16 bit" : "unknown depth"
        let rate: String
        switch sampleRate {
        case 1: rate = "44.1 kHz"
        case 2: rate = "48 kHz"
        case 3: rate = "96 kHz"
        default: rate = "unknown rate"
        }
        return "\(bits) / \(rate)"
    }

    var activeCodecDescription: String {
        guard activeCodecMask != 0 else { return "None" }
        return Codec.allCases.first(where: { $0 != .automatic && $0.rawValue == activeCodecMask })?.title
            ?? String(format: "0x%04X", activeCodecMask)
    }

    private struct Pending {
        let id: UUID
        let command: UInt8
        let continuation: CheckedContinuation<[UInt8], Error>
    }

    private enum DongleError: LocalizedError {
        case unavailable
        case timeout
        case malformedResponse
        case io(IOReturn)
        case rejected(UInt8)

        var errorDescription: String? {
            switch self {
            case .unavailable: "BTD 700 is not available. Check its USB connection."
            case .timeout: "The dongle did not respond. Close Sennheiser Dongle Control and retry."
            case .malformedResponse: "The dongle returned an incomplete response."
            case .io(let code): "USB control failed (\(code))."
            case .rejected(let code): "The dongle rejected that setting (code \(code))."
            }
        }
    }

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    private var device: IOHIDDevice?
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var pending: Pending?
    private var eventRefreshTask: Task<Void, Never>?

    init() {
        reportBuffer.initialize(repeating: 0, count: 64)
        let matching = [kIOHIDVendorIDKey: 0x3542, kIOHIDProductIDKey: 0x3001] as NSDictionary
        IOHIDManagerSetDeviceMatching(manager, matching)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let owner = Unmanaged<DongleController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                let wasAvailable = owner.available
                owner.connect()
                if !wasAvailable && owner.available { Task { await owner.refresh() } }
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, removed in
            guard let context else { return }
            let owner = Unmanaged<DongleController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                if let current = owner.device, CFEqual(current, removed) {
                    owner.detach()
                }
            }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        _ = IOHIDManagerOpen(manager, 0)
        connect()
        Task { await refresh() }
    }

    deinit {
        if let device {
            IOHIDDeviceClose(device, 0)
        }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, 0)
        reportBuffer.deinitialize(count: 64)
        reportBuffer.deallocate()
    }

    private func connect() {
        guard device == nil, let devices = IOHIDManagerCopyDevices(manager) else { return }
        let count = CFSetGetCount(devices)
        guard count > 0 else { return }
        let values = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: count)
        defer { values.deallocate() }
        CFSetGetValues(devices, values)

        for index in 0..<count {
            guard let value = values[index] else { continue }
            let candidate = Unmanaged<IOHIDDevice>.fromOpaque(value).takeUnretainedValue()
            let pairs = IOHIDDeviceGetProperty(candidate, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] ?? []
            guard pairs.contains(where: {
                ($0["DeviceUsagePage"] as? Int) == 0xFFA2 && ($0["DeviceUsage"] as? Int) == 1
            }) else { continue }
            guard IOHIDDeviceOpen(candidate, 0) == kIOReturnSuccess else { continue }

            device = candidate
            IOHIDDeviceRegisterInputReportCallback(candidate, reportBuffer, 64, { context, _, _, _, _, report, length in
                guard let context else { return }
                let bytes = Array(UnsafeBufferPointer(start: report, count: min(length, 64)))
                DispatchQueue.main.async {
                    let owner = Unmanaged<DongleController>.fromOpaque(context).takeUnretainedValue()
                    owner.receive(bytes)
                }
            }, Unmanaged.passUnretained(self).toOpaque())
            available = true
            errorMessage = nil
            return
        }
        available = false
    }

    private func detach() {
        eventRefreshTask?.cancel()
        eventRefreshTask = nil
        if let pending {
            self.pending = nil
            pending.continuation.resume(throwing: DongleError.unavailable)
        }
        if let device { IOHIDDeviceClose(device, 0) }
        device = nil
        available = false
        firmware = ""
        connectionState = 0
        activeCodecMask = 0
        supportedCodecMask = 0
        bitDepth = 0
        sampleRate = 0
        leAudioState = nil
        sinkTransport = nil
        errorMessage = nil
    }

    func recoverAfterWake() async {
        if available {
            await refresh()
            if errorMessage == nil { return }
        }
        detach()
        for attempt in 0..<3 {
            connect()
            if available {
                await refresh()
                if errorMessage == nil { return }
                detach()
            }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        }
    }

    private func receive(_ bytes: [UInt8]) {
        guard bytes.count >= 4, bytes[0] == 0x34 else { return }
        if bytes[1] == 0xFC {
            eventRefreshTask?.cancel()
            eventRefreshTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
            return
        }
        guard bytes[1] == 0xFF, let pending, bytes[2] == pending.command else { return }
        self.pending = nil
        let length = Int(bytes[3])
        guard length <= 60, bytes.count >= 4 + length else {
            pending.continuation.resume(throwing: DongleError.malformedResponse)
            return
        }
        pending.continuation.resume(returning: Array(bytes[4..<(4 + length)]))
    }

    private func command(_ id: UInt8, payload: [UInt8] = []) async throws -> [UInt8] {
        while pending != nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if device == nil { connect() }
        guard let device, available else { throw DongleError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            let requestID = UUID()
            pending = Pending(id: requestID, command: id, continuation: continuation)
            var report = [UInt8](repeating: 0, count: 64)
            report[0] = 0x34
            report[1] = 0xFE
            report[2] = id
            report[3] = UInt8(payload.count)
            for (index, byte) in payload.enumerated() { report[4 + index] = byte }
            let result = report.withUnsafeBytes { data in
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x34,
                                     data.baseAddress!.assumingMemoryBound(to: UInt8.self), 64)
            }
            if result != kIOReturnSuccess {
                pending = nil
                continuation.resume(throwing: DongleError.io(result))
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.pending?.id == requestID else { return }
                self.pending = nil
                continuation.resume(throwing: DongleError.timeout)
            }
        }
    }

    func refresh() async {
        if device == nil { connect() }
        guard available else { return }
        beginOperation()
        defer { endOperation() }
        do {
            let version = try await command(0x12)
            if version.count >= 3 { firmware = "\(version[0]).\(version[1]).\(version[2])" }
            let state = try await command(0x06)
            if let first = state.first { connectionState = first }
            let mode = try await command(0x01)
            if mode.count >= 2 {
                audioMode = AudioMode(rawValue: mode[0]) ?? .highQuality
                transport = mode[1]
            }
            let selected = try await command(0x03)
            if let first = selected.first {
                supportedCodecMask = UInt16(first) | (selected.count > 1 ? UInt16(selected[1]) << 8 : 0)
            }
            let active = try await command(0x05)
            if let first = active.first {
                activeCodecMask = UInt16(first) | (active.count > 1 ? UInt16(active[1]) << 8 : 0)
            }
            let quality = try await command(0x08)
            if quality.count >= 2 {
                bitDepth = quality[0]
                sampleRate = quality[1]
            }
            if let value = try? await command(0x07), let first = value.first, first <= 4 {
                leAudioState = first
            }
            if let value = try? await command(0x15), let first = value.first, first <= 3 {
                sinkTransport = first
            }
            errorMessage = nil
        } catch is CancellationError {
            // A newer device event superseded this refresh.
        } catch {
            if available { errorMessage = error.localizedDescription }
        }
    }

    @discardableResult func setAudioMode(_ mode: AudioMode) async -> Bool {
        beginOperation()
        defer { endOperation() }
        do {
            let response = try await command(0x02, payload: [mode.rawValue, transport])
            try checkAck(response)
            await refresh()
            if audioMode != mode {
                errorMessage = "The dongle did not switch to \(mode.title)."
                return false
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func setCodec(_ codec: Codec) async {
        beginOperation()
        defer { endOperation() }
        do {
            let response = try await command(0x04, payload: [UInt8(codec.rawValue & 0xFF), UInt8(codec.rawValue >> 8)])
            try checkAck(response)
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func setConnected(_ connected: Bool) async {
        beginOperation()
        defer { endOperation() }
        do {
            let response = try await command(0x14, payload: [connected ? 1 : 0])
            try checkAck(response)
            for attempt in 0...10 {
                await refresh()
                if connected ? connectionState >= 2 : connectionState <= 1 { return }
                if attempt < 10 { try await Task.sleep(nanoseconds: 2_000_000_000) }
            }
            errorMessage = connected ? "The headphones did not reconnect within 20 seconds."
                                     : "The headphones did not disconnect."
        } catch { errorMessage = error.localizedDescription }
    }

    private func checkAck(_ response: [UInt8]) throws {
        guard let status = response.first else { throw DongleError.malformedResponse }
        guard status == 0 else { throw DongleError.rejected(status) }
    }

    private func beginOperation() {
        activeOperations += 1
        busy = true
    }

    private func endOperation() {
        activeOperations -= 1
        busy = activeOperations > 0
    }
}
