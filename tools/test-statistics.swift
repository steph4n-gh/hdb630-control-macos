// swiftc -parse-as-library Bluetooth/Models.swift tools/test-statistics.swift -o /tmp/test-statistics
import Foundation

@main struct StatisticsTests {
    static func data(_ hex: String) -> Data {
        Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    static func main() {
        let captured = data("00 00 01 01 00 01 05 02 00 01 00 03 00 00 04 00 02 FF CF 05 00 02 FF 78")
        let page = GAIAStatisticsPage(captured, category: 1)!
        let stream = HeadphoneStreamingStatistics(records: page.records, sampledAt: Date())
        precondition(page.records.count == 5 && !page.more)
        precondition(stream.codec == "aptX Adaptive" && stream.lossless == false)
        precondition(stream.bitrate == nil) // Empty is unavailable, not 0 bps.
        precondition(stream.primaryRSSI == -49)
        precondition(abs(stream.primaryLinkQuality! - 99.7940032043946) < 0.000001)
        precondition(GAIAStatisticsPage(captured, category: 256) == nil)
        precondition(GAIAStatisticsPage(captured, category: 1, after: 1) == nil)
        precondition(GAIAStatisticsPage(Data(captured.dropLast()), category: 1) == nil)
        precondition(GAIAStatisticsPage(data("00 00 01 01 00"), category: 1) == nil)
        precondition(GAIAStatisticsPage(data("01 00 01"), category: 1) == nil)
        precondition(GAIAStatisticsPage(data("02 00 01"), category: 1) == nil)
        precondition(GAIAStatisticsPage(data("00 00 01 01 00 00 01 00 00"), category: 1) == nil)

        let pages = [
            "01 01 00 01 00 02 00 64 02 00 04 00 00 2A 08 03 00 02 01 DD 04 00 04 00 00 18 D7 05 00 02 00 04",
            "01 01 00 06 00 04 00 00 00 0F 07 00 04 00 00 00 00 08 00 02 00 4B 09 00 04 00 00 2A 07 0A 00 02 00 06",
            "01 01 00 0B 00 04 00 00 0A 49 0C 00 02 00 2A 0D 00 02 00 00 0E 00 04 00 00 00 00 0F 00 04 00 00 01 19",
            "00 01 00 10 00 04 00 00 00 01 11 00 04 00 00 17 BA 12 00 04 00 00 00 00 13 00 04 00 00 00 03"
        ]
        var last: UInt8 = 0
        var records: [GAIAStatistic] = []
        for (index, payload) in pages.enumerated() {
            let page = GAIAStatisticsPage(data(payload), category: 256, after: last)!
            precondition(page.more == (index < 3))
            records += page.records
            last = page.records.last!.id
        }
        precondition(records.count == 19 && last == 19)
        precondition(records[1].unsignedValue == 10760)
        precondition(records[14...18].compactMap(\.unsignedValue).reduce(0, +) == records[3].unsignedValue)
        let flags = GAIAStatistic(id: 1, flags: 1, bytes: [5])
        precondition(flags.unsignedValue == nil)
        let maximum = GAIAStatistic(id: 3, flags: 0, bytes: [255, 255, 255, 255])
        precondition(maximum.unsignedValue == UInt32.max && maximum.unsignedValue(length: 2) == nil)
        print("Statistics tests passed: captured pages, signedness, units, empty fields and malformed input")
    }
}
