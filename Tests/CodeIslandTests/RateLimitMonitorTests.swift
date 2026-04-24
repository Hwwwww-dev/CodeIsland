import Foundation
import XCTest
@testable import CodeIsland

final class RateLimitMonitorTests: XCTestCase {
    func testDisplayTextShowsSevenDayWindowAtZeroPercent() {
        let info = RateLimitDisplayInfo(
            fiveHourPercent: 2,
            sevenDayPercent: 0,
            fiveHourResetAt: nil,
            sevenDayResetAt: nil,
            planName: nil
        )

        XCTAssertEqual(info.displayText, "2% | 0%")
        XCTAssertTrue(info.tooltip.contains("7d window: 0%"))
    }

    func testPulseUsageReaderPreservesZeroSevenDayPercent() throws {
        let now = Date()
        let updatedAt = Int(now.timeIntervalSince1970 * 1000)
        let fiveHourReset = Int(now.addingTimeInterval(3600).timeIntervalSince1970)
        let sevenDayReset = Int(now.addingTimeInterval(5 * 24 * 3600).timeIntervalSince1970)
        let json = """
        {
          "schema_version": 2,
          "updated_at": \(updatedAt),
          "rate_limits": {
            "five_hour": { "used_percentage": 2, "resets_at": \(fiveHourReset) },
            "seven_day": { "used_percentage": 0, "resets_at": \(sevenDayReset) }
          }
        }
        """

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("general.json")
        try Data(json.utf8).write(to: fileURL)

        let info = PulseUsageReader.read(from: fileURL.path)

        XCTAssertEqual(info?.fiveHourPercent, 2)
        XCTAssertEqual(info?.sevenDayPercent, 0)
    }
}
