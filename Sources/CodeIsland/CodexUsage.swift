//
//  CodexUsage.swift
//  CodeIsland
//
//  Reads Codex rate-limit / usage data from the most recently updated
//  ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl file.
//  Ported from MioIsland.
//

import Combine
import Foundation

struct CodexUsageWindow: Equatable, Codable, Sendable, Identifiable {
    var key: String
    var label: String
    var usedPercentage: Double
    var leftPercentage: Double
    var windowMinutes: Int
    var resetsAt: Date?

    var id: String { key }

    var roundedUsedPercentage: Int { Int(usedPercentage.rounded()) }
}

struct CodexUsageSnapshot: Equatable, Codable, Sendable {
    var sourceFilePath: String
    var capturedAt: Date?
    var planType: String?
    var limitID: String?
    var windows: [CodexUsageWindow]

    var isEmpty: Bool { windows.isEmpty }
}

// MARK: - Usage Monitor

/// Periodically loads the latest Codex usage snapshot and publishes it.
@MainActor
final class CodexUsageMonitor: ObservableObject {
    static let shared = CodexUsageMonitor()

    @Published private(set) var snapshot: CodexUsageSnapshot?
    private var isLoading = false
    private var lastRefreshedAt: Date?
    private static let refreshTTL: TimeInterval = 10
    private let loadSnapshot: @Sendable () -> CodexUsageSnapshot?

    private var refreshTimer: Timer?

    init(loadSnapshot: @escaping @Sendable () -> CodexUsageSnapshot? = {
        (try? CodexUsageLoader.load()) ?? nil
    }) {
        self.loadSnapshot = loadSnapshot
    }

    func start() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh(force: Bool = false) async {
        guard !isLoading else { return }
        if !force, snapshot != nil, let last = lastRefreshedAt, Date().timeIntervalSince(last) < Self.refreshTTL {
            return
        }
        isLoading = true
        defer { isLoading = false }
        let loader = loadSnapshot
        let loadedSnapshot = await Task.detached(priority: .utility) {
            loader()
        }.value
        if let loadedSnapshot {
            snapshot = loadedSnapshot
        }
        lastRefreshedAt = Date()
    }
}

// MARK: - Usage Loader

enum CodexUsageLoader {
    static let defaultRootURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)

    /// Files older than this are skipped — token_count events beyond a week are stale
    /// and not worth the stat/parse budget on every hover-triggered refresh.
    private static let candidateMaxAge: TimeInterval = 7 * 24 * 3600
    private static let tailReadByteLimit = 512 * 1024

    private struct Candidate {
        var fileURL: URL
        var modifiedAt: Date
    }

    static func load(
        fromRootURL rootURL: URL = defaultRootURL,
        fileManager: FileManager = .default
    ) throws -> CodexUsageSnapshot? {
        guard fileManager.fileExists(atPath: rootURL.path) else { return nil }

        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.candidateMaxAge)

        for candidate in candidates(inRootURL: rootURL, cutoff: cutoff, fileManager: fileManager) {
            if let snapshot = loadLatestSnapshot(from: candidate.fileURL, modifiedAt: candidate.modifiedAt) {
                return snapshot
            }
        }

        return nil
    }

    private static func isNewer(_ lhs: Candidate, than rhs: Candidate) -> Bool {
        if lhs.modifiedAt == rhs.modifiedAt {
            return lhs.fileURL.path.localizedStandardCompare(rhs.fileURL.path) == .orderedDescending
        }
        return lhs.modifiedAt > rhs.modifiedAt
    }

    private static func candidates(inRootURL rootURL: URL, cutoff: Date, fileManager: FileManager) -> [Candidate] {
        var candidates: [Candidate] = []
        for dayURL in dateDirectoryURLs(rootURL: rootURL, fileManager: fileManager) {
            guard let fileURLs = try? fileManager.contentsOfDirectory(
                at: dayURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for fileURL in fileURLs {
                guard fileURL.lastPathComponent.hasPrefix("rollout-"),
                      fileURL.pathExtension == "jsonl",
                      let resourceValues = try? fileURL.resourceValues(
                        forKeys: [.contentModificationDateKey, .isRegularFileKey]
                      ),
                      resourceValues.isRegularFile == true,
                      let modifiedAt = resourceValues.contentModificationDate,
                      modifiedAt >= cutoff else { continue }

                candidates.append(Candidate(fileURL: fileURL, modifiedAt: modifiedAt))
            }
        }

        return candidates.sorted { isNewer($0, than: $1) }
    }

    private static func dateDirectoryURLs(rootURL: URL, fileManager: FileManager) -> [URL] {
        var dayURLs: [URL] = []
        for yearURL in directoryURLs(at: rootURL, fileManager: fileManager)
            where isDecimalComponent(yearURL.lastPathComponent, digitCount: 4) {
            for monthURL in directoryURLs(at: yearURL, fileManager: fileManager)
                where isDecimalComponent(monthURL.lastPathComponent, digitCount: 2) {
                for dayURL in directoryURLs(at: monthURL, fileManager: fileManager)
                    where isDecimalComponent(dayURL.lastPathComponent, digitCount: 2) {
                    dayURLs.append(dayURL)
                }
            }
        }
        return dayURLs
    }

    private static func directoryURLs(at url: URL, fileManager: FileManager) -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private static func isDecimalComponent(_ value: String, digitCount: Int) -> Bool {
        let utf8 = value.utf8
        return utf8.count == digitCount && utf8.allSatisfy { byte in
            byte >= CharacterCodes.zero && byte <= CharacterCodes.nine
        }
    }

    private enum CharacterCodes {
        static let zero = UInt8(ascii: "0")
        static let nine = UInt8(ascii: "9")
    }

    private static func loadLatestSnapshot(from fileURL: URL, modifiedAt: Date) -> CodexUsageSnapshot? {
        let tail = tailContents(of: fileURL)
        if let snapshot = tail.flatMap({
            latestSnapshot(in: $0.text, filePath: fileURL.path, fallbackTimestamp: modifiedAt)
        }) {
            return snapshot
        }

        guard tail?.isCompleteFile != true,
              let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        return latestSnapshot(in: contents, filePath: fileURL.path, fallbackTimestamp: modifiedAt)
    }

    private struct TailContents {
        var text: String
        var isCompleteFile: Bool
    }

    private static func tailContents(of fileURL: URL) -> TailContents? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else { return nil }
        let readSize = Int(min(fileSize, UInt64(Self.tailReadByteLimit)))
        let startOffset = fileSize - UInt64(readSize)

        do {
            try handle.seek(toOffset: startOffset)
            guard let data = try handle.read(upToCount: readSize) else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            return TailContents(text: text, isCompleteFile: startOffset == 0)
        } catch {
            return nil
        }
    }

    private static func latestSnapshot(
        in contents: String,
        filePath: String,
        fallbackTimestamp: Date
    ) -> CodexUsageSnapshot? {
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            if let snapshot = snapshot(
                from: String(line),
                filePath: filePath,
                fallbackTimestamp: fallbackTimestamp
            ) {
                return snapshot
            }
        }
        return nil
    }

    private static func snapshot(from line: String, filePath: String, fallbackTimestamp: Date) -> CodexUsageSnapshot? {
        guard let object = jsonObject(for: line),
              object["type"] as? String == "event_msg" else { return nil }

        let payload = object["payload"] as? [String: Any] ?? [:]
        guard payload["type"] as? String == "token_count",
              let rateLimits = payload["rate_limits"] as? [String: Any] else { return nil }

        let capturedAt = timestamp(from: object["timestamp"]) ?? fallbackTimestamp
        let windows = ["primary", "secondary"].compactMap { key in
            usageWindow(for: key, in: rateLimits, anchor: capturedAt)
        }
        guard !windows.isEmpty else { return nil }

        return CodexUsageSnapshot(
            sourceFilePath: filePath,
            capturedAt: capturedAt,
            planType: string(from: rateLimits["plan_type"]),
            limitID: string(from: rateLimits["limit_id"]),
            windows: windows
        )
    }

    private static func usageWindow(for key: String, in rateLimits: [String: Any], anchor: Date) -> CodexUsageWindow? {
        guard let payload = rateLimits[key] as? [String: Any],
              let rawUsed = number(from: payload["used_percent"]),
              let windowMinutes = integer(from: payload["window_minutes"]) else { return nil }

        let rawReset = date(from: payload["resets_at"])
        let (resetsAt, expired) = resolveReset(raw: rawReset, anchor: anchor, windowMinutes: windowMinutes)
        let usedPercentage = expired ? 0.0 : rawUsed

        return CodexUsageWindow(
            key: key,
            label: windowLabel(forMinutes: windowMinutes),
            usedPercentage: usedPercentage,
            leftPercentage: max(0, 100 - usedPercentage),
            windowMinutes: windowMinutes,
            resetsAt: resetsAt
        )
    }

    /// Derive the reset timestamp AND detect whether the window has rolled over.
    ///
    /// Codex windows don't advance on a fixed wall-clock cadence — a new window only starts
    /// when the user sends another message after the previous `resets_at`. So once the raw
    /// value is in the past we return `(nil, true)`: caller zeroes `used_percent` and we show
    /// no "resets in …" until a fresh rollout event provides a future `resets_at`.
    private static func resolveReset(raw: Date?, anchor: Date, windowMinutes: Int) -> (Date?, Bool) {
        let now = Date()
        let window = TimeInterval(windowMinutes) * 60
        guard window > 0 else { return (raw, raw != nil) }

        if let raw = raw {
            if raw > now { return (raw, false) }
            return (nil, true)
        }

        let elapsed = now.timeIntervalSince(anchor)
        if elapsed <= 0 { return (anchor.addingTimeInterval(window), false) }
        if elapsed >= window { return (nil, true) }
        return (anchor.addingTimeInterval(window), false)
    }

    private static func windowLabel(forMinutes minutes: Int) -> String {
        let days = minutes / 1_440
        let remainingMinutesAfterDays = minutes % 1_440
        let hours = remainingMinutesAfterDays / 60
        let remainingMinutes = remainingMinutesAfterDays % 60

        if days > 0, hours == 0, remainingMinutes == 0 { return "\(days)d" }
        if days > 0, hours > 0 { return "\(days)d \(hours)h" }
        if hours > 0, remainingMinutes == 0 { return "\(hours)h" }
        if hours > 0 { return "\(hours)h \(remainingMinutes)m" }
        return "\(minutes)m"
    }

    private static func jsonObject(for line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }

    private static func timestamp(from value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    private static func number(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    private static func integer(from value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string)
        default: return nil
        }
    }

    private static func date(from value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            var sec = number.doubleValue
            if sec > 10_000_000_000 { sec /= 1000 }
            return Date(timeIntervalSince1970: sec)
        case let string as String:
            guard var sec = Double(string) else { return nil }
            if sec > 10_000_000_000 { sec /= 1000 }
            return Date(timeIntervalSince1970: sec)
        default: return nil
        }
    }

    private static func string(from value: Any?) -> String? {
        switch value {
        case let string as String: return string.isEmpty ? nil : string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }
}
