import Foundation
import XCTest
@testable import CodeIsland

final class CodexUsageLoaderTests: XCTestCase {
    func testLoadPrefersClosestDateDirectoryOverNewerModifiedAtInOlderDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let todayDir = dateDirectory(for: Date(), under: tempDir)
        let yesterdayDir = dateDirectory(for: dateByAddingDays(-1), under: tempDir)
        try FileManager.default.createDirectory(at: todayDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: yesterdayDir, withIntermediateDirectories: true)

        let today = todayDir.appendingPathComponent("rollout-today.jsonl")
        let yesterday = yesterdayDir.appendingPathComponent("rollout-yesterday.jsonl")
        try validTokenCountLine(usedPercent: 11).write(to: today, atomically: true, encoding: .utf8)
        try validTokenCountLine(usedPercent: 77).write(to: yesterday, atomically: true, encoding: .utf8)

        try setModifiedAt(Date().addingTimeInterval(-120), for: today)
        try setModifiedAt(Date(), for: yesterday)

        let snapshot = try XCTUnwrap(CodexUsageLoader.load(fromRootURL: tempDir))

        XCTAssertEqual(canonicalPath(snapshot.sourceFilePath), canonicalPath(today.path))
        XCTAssertEqual(snapshot.windows.first?.usedPercentage, 11)
    }

    func testLoadReadsOnlyNewestRolloutFileContent() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dayDir = dateDirectory(for: Date(), under: tempDir)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let older = dayDir.appendingPathComponent("rollout-test-old.jsonl")
        let newer = dayDir.appendingPathComponent("rollout-test-new.jsonl")
        try validTokenCountLine(usedPercent: 42).write(to: older, atomically: true, encoding: .utf8)
        try #"{"type":"event_msg","payload":{"type":"session_configured"}}"#
            .write(to: newer, atomically: true, encoding: .utf8)

        try setModifiedAt(Date().addingTimeInterval(-120), for: older)
        try setModifiedAt(Date(), for: newer)

        let snapshot = try CodexUsageLoader.load(fromRootURL: tempDir)

        XCTAssertNil(snapshot)
    }

    private func validTokenCountLine(usedPercent: Int) -> String {
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = timestampFormatter.string(from: Date())
        let reset = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)

        return """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"plan_type":"pro","primary":{"used_percent":\(usedPercent),"window_minutes":300,"resets_at":\(reset)}}}}
        """
    }

    private func setModifiedAt(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func dateByAddingDays(_ days: Int) -> Date {
        Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: Date())!
    }

    private func dateDirectory(for date: Date, under rootURL: URL) -> URL {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: date)

        return rootURL
            .appendingPathComponent(String(format: "%04d", components.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.day!), isDirectory: true)
    }
}
