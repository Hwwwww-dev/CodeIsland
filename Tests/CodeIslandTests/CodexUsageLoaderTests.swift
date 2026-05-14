import Foundation
import XCTest
@testable import CodeIsland

final class CodexUsageLoaderTests: XCTestCase {
    @MainActor
    func testMonitorStopKeepsLastSnapshotVisible() async throws {
        let expected = makeSnapshot(usedPercent: 31)
        let monitor = CodexUsageMonitor(loadSnapshot: { expected })

        await monitor.refresh(force: true)
        monitor.stop()

        XCTAssertEqual(monitor.snapshot, expected)
    }

    @MainActor
    func testMonitorRefreshKeepsExistingSnapshotWhenLoadReturnsNil() async throws {
        let first = makeSnapshot(usedPercent: 45)
        let loader = SnapshotSequence([first, nil])
        let monitor = CodexUsageMonitor(loadSnapshot: { loader.next() })

        await monitor.refresh(force: true)
        await monitor.refresh(force: true)

        XCTAssertEqual(monitor.snapshot, first)
    }

    @MainActor
    func testMonitorRefreshThrottlesNilLoads() async throws {
        let loader = SnapshotSequence([nil, makeSnapshot(usedPercent: 52)])
        let monitor = CodexUsageMonitor(loadSnapshot: { loader.next() })

        await monitor.refresh()
        await monitor.refresh()

        XCTAssertNil(monitor.snapshot)
        XCTAssertEqual(loader.callCount(), 1)
    }

    @MainActor
    func testMonitorForceRefreshBypassesNilThrottle() async throws {
        let expected = makeSnapshot(usedPercent: 52)
        let loader = SnapshotSequence([nil, expected])
        let monitor = CodexUsageMonitor(loadSnapshot: { loader.next() })

        await monitor.refresh()
        await monitor.refresh(force: true)

        XCTAssertEqual(monitor.snapshot, expected)
        XCTAssertEqual(loader.callCount(), 2)
    }

    func testLoadPrefersNewestModifiedFileAcrossDateDirectories() throws {
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

        XCTAssertEqual(canonicalPath(snapshot.sourceFilePath), canonicalPath(yesterday.path))
        XCTAssertEqual(snapshot.windows.first?.usedPercentage, 77)
    }

    func testLoadFindsRecentlyModifiedFileInOlderDateDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let todayDir = dateDirectory(for: Date(), under: tempDir)
        let olderDir = dateDirectory(for: dateByAddingDays(-8), under: tempDir)
        try FileManager.default.createDirectory(at: todayDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: olderDir, withIntermediateDirectories: true)

        let today = todayDir.appendingPathComponent("rollout-today.jsonl")
        let older = olderDir.appendingPathComponent("rollout-older-active.jsonl")
        try validTokenCountLine(usedPercent: 12).write(to: today, atomically: true, encoding: .utf8)
        try validTokenCountLine(usedPercent: 88).write(to: older, atomically: true, encoding: .utf8)

        try setModifiedAt(Date().addingTimeInterval(-120), for: today)
        try setModifiedAt(Date(), for: older)

        let snapshot = try XCTUnwrap(CodexUsageLoader.load(fromRootURL: tempDir))

        XCTAssertEqual(canonicalPath(snapshot.sourceFilePath), canonicalPath(older.path))
        XCTAssertEqual(snapshot.windows.first?.usedPercentage, 88)
    }

    func testLoadFallsBackWhenNewestRolloutHasNoTokenCount() throws {
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

        let snapshot = try XCTUnwrap(CodexUsageLoader.load(fromRootURL: tempDir))

        XCTAssertEqual(canonicalPath(snapshot.sourceFilePath), canonicalPath(older.path))
        XCTAssertEqual(snapshot.windows.first?.usedPercentage, 42)
    }

    func testLoadFallsBackToOlderDateWhenRecentDateHasNoTokenCount() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let todayDir = dateDirectory(for: Date(), under: tempDir)
        let yesterdayDir = dateDirectory(for: dateByAddingDays(-1), under: tempDir)
        try FileManager.default.createDirectory(at: todayDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: yesterdayDir, withIntermediateDirectories: true)

        let today = todayDir.appendingPathComponent("rollout-today.jsonl")
        let yesterday = yesterdayDir.appendingPathComponent("rollout-yesterday.jsonl")
        try #"{"type":"event_msg","payload":{"type":"session_configured"}}"#
            .write(to: today, atomically: true, encoding: .utf8)
        try validTokenCountLine(usedPercent: 66).write(to: yesterday, atomically: true, encoding: .utf8)

        try setModifiedAt(Date(), for: today)
        try setModifiedAt(Date().addingTimeInterval(-120), for: yesterday)

        let snapshot = try XCTUnwrap(CodexUsageLoader.load(fromRootURL: tempDir))

        XCTAssertEqual(canonicalPath(snapshot.sourceFilePath), canonicalPath(yesterday.path))
        XCTAssertEqual(snapshot.windows.first?.usedPercentage, 66)
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

    private func makeSnapshot(usedPercent: Double) -> CodexUsageSnapshot {
        CodexUsageSnapshot(
            sourceFilePath: "/tmp/rollout-test.jsonl",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            planType: "pro",
            limitID: nil,
            windows: [
                CodexUsageWindow(
                    key: "primary",
                    label: "5h",
                    usedPercentage: usedPercent,
                    leftPercentage: 100 - usedPercent,
                    windowMinutes: 300,
                    resetsAt: Date(timeIntervalSince1970: 1_700_003_600)
                )
            ]
        )
    }
}

private final class SnapshotSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [CodexUsageSnapshot?]
    private var calls = 0

    init(_ snapshots: [CodexUsageSnapshot?]) {
        self.snapshots = snapshots
    }

    func next() -> CodexUsageSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        guard !snapshots.isEmpty else { return nil }
        return snapshots.removeFirst()
    }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}
