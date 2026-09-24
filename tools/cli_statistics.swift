// Read-only HDB 630 statistics sampler. Quit the menu bar app before running.
// swiftc -parse-as-library Bluetooth/Models.swift Bluetooth/GAIAProtocol.swift
//   Bluetooth/BluetoothManager.swift tools/cli_statistics.swift
//   -import-objc-header HDB630Control-Bridging-Header.h -o /tmp/hdb-statistics
// /tmp/hdb-statistics [samples=1] [intervalSeconds=5]
import AppKit
import Foundation
import IOBluetooth

@main struct StatisticsSampler {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let bluetooth = BluetoothManager()
        var connecting = false
        var sampling = false
        let start = Date()
        bluetooth.scanForDevices()
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            if Date().timeIntervalSince(start) > 25 && !sampling {
                print("Connection timed out")
                bluetooth.disconnect()
                app.terminate(nil)
            }
            if bluetooth.state == .disconnected && !connecting {
                guard bluetooth.pairedDevices.count == 1, let device = bluetooth.pairedDevices.first else {
                    print("Expected exactly one matching paired headphone")
                    app.terminate(nil)
                    return
                }
                connecting = true
                bluetooth.connect(to: device)
            }
            if bluetooth.state == .connected && !sampling {
                sampling = true
                timer.invalidate()
                Task { @MainActor in
                    await run(bluetooth)
                    bluetooth.disconnect()
                    app.terminate(nil)
                }
            }
            if case .error(let message) = bluetooth.state {
                print("Connection error: \(message)")
                timer.invalidate()
                app.terminate(nil)
            }
        }
        app.run()
    }

    @MainActor static func run(_ bluetooth: BluetoothManager) async {
        let count = min(360, max(1, CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 1))
        let interval = min(60, max(2, CommandLine.arguments.dropFirst(2).first.flatMap(Double.init) ?? 5))
        for sample in 0..<count {
            do {
                var result: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date())]
                var statistics: [String: Any] = [:]
                for category: UInt16 in [1, 0x100] {
                    var last: UInt8 = 0
                    for _ in 0..<255 {
                        let response = try await bluetooth.sendCommand(vendor: 0x001D, command: 0x1801,
                            payload: [UInt8(category >> 8), UInt8(category & 0xff), last])
                        guard let page = GAIAStatisticsPage(response.payload, category: category, after: last) else {
                            throw SampleError.malformed
                        }
                        for item in page.records {
                            var record: [String: Any] = ["flags": item.flags, "length": item.bytes.count,
                                "hex": item.hex.replacingOccurrences(of: " ", with: "")]
                            record["unsignedBE"] = item.unsignedValue
                            statistics[String(format: "%04X:%02X", category, item.id)] = record
                            last = item.id
                        }
                        if !page.more { break }
                    }
                }
                result["statistics"] = statistics
                var state: [String: String] = [:]
                for command: UInt16 in [0x0804, 0x0402, 0x0602, 0x0603, 0x0800, 0x081A, 0x1A01, 0x1A03, 0x1A05] {
                    let response = try await bluetooth.sendCommand(vendor: 0x0495, command: command)
                    state[String(format: "%04X", command)] = response.payload.map { String(format: "%02X", $0) }.joined()
                }
                result["state"] = state
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                fflush(stdout)
            } catch {
                print("Sample error: \(error)")
                fflush(stdout)
                break
            }
            if sample + 1 < count { try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
        }
    }
    enum SampleError: Error { case malformed }
}
