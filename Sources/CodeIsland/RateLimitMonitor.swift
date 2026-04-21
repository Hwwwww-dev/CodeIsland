//
//  RateLimitMonitor.swift
//  CodeIsland
//
//  Reads Claude Code 5h/7d rate-limit usage from the Pulse local cache file.
//  Ported from MioIsland (compliant Pulse-only path; no network, no Keychain).
//

import Combine
import Foundation
import SwiftUI

/// Parsed rate limit display info for Claude (5h + 7d windows).
struct RateLimitDisplayInfo: Equatable {
    let fiveHourPercent: Int?
    let sevenDayPercent: Int?
    let fiveHourResetAt: Date?
    let sevenDayResetAt: Date?
    let planName: String?

    var displayText: String {
        var parts: [String] = []
        if let pct = fiveHourPercent {
            let resetStr = formatRemaining(fiveHourResetAt)
            parts.append("\(pct)%\(resetStr.isEmpty ? "" : " \(resetStr)")")
        }
        if let pct = sevenDayPercent, pct >= 5 {
            let resetStr = formatRemaining(sevenDayResetAt)
            parts.append("\(pct)%\(resetStr.isEmpty ? "" : " \(resetStr)")")
        }
        return parts.isEmpty ? "--" : parts.joined(separator: " | ")
    }

    var tooltip: String {
        var lines: [String] = []
        if let plan = planName { lines.append("Plan: \(plan)") }
        if let pct = fiveHourPercent {
            let reset = formatRemainingLong(fiveHourResetAt)
            lines.append("5h window: \(pct)%\(reset.isEmpty ? "" : " (resets in \(reset))")")
        }
        if let pct = sevenDayPercent {
            let reset = formatRemainingLong(sevenDayResetAt)
            lines.append("7d window: \(pct)%\(reset.isEmpty ? "" : " (resets in \(reset))")")
        }
        return lines.isEmpty ? "Claude usage" : lines.joined(separator: "\n")
    }

    var color: Color {
        let maxPct = max(fiveHourPercent ?? 0, sevenDayPercent ?? 0)
        if maxPct >= 90 { return Color(red: 0.94, green: 0.27, blue: 0.27) }
        if maxPct >= 70 { return Color(red: 1.0, green: 0.6, blue: 0.2) }
        return Color(red: 0.29, green: 0.87, blue: 0.5)
    }

    private func formatRemaining(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let remaining = date.timeIntervalSinceNow
        if remaining <= 0 { return "" }
        if remaining < 3600 { return "\(Int(remaining / 60))m" }
        if remaining < 86400 {
            let h = Int(remaining / 3600)
            let m = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)
            return m > 0 ? "\(h)h\(m)m" : "\(h)h"
        }
        let d = Int(remaining / 86400)
        let h = Int(remaining.truncatingRemainder(dividingBy: 86400) / 3600)
        let m = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)
        return h > 0 ? "\(d)d\(h)h\(m)m" : "\(d)d\(m)m"
    }

    private func formatRemainingLong(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let remaining = date.timeIntervalSinceNow
        if remaining <= 0 { return "" }
        if remaining < 3600 { return "\(Int(remaining / 60))min" }
        if remaining < 86400 {
            let h = Int(remaining / 3600)
            let m = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)
            return m > 0 ? "\(h)h\(m)m" : "\(h)h"
        }
        let d = Int(remaining / 86400)
        let h = Int(remaining.truncatingRemainder(dividingBy: 86400) / 3600)
        let m = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)
        return h > 0 ? "\(d)d\(h)h\(m)m" : "\(d)d\(m)min"
    }
}

/// Periodically reads Pulse's local cache file and publishes Claude usage.
/// Compliant: reads only `~/.pulse/.cache/general.json`. No network traffic.
@MainActor
final class RateLimitMonitor: ObservableObject {
    static let shared = RateLimitMonitor()

    @Published private(set) var rateLimitInfo: RateLimitDisplayInfo?
    private var isLoading = false
    private var lastRefreshedAt: Date?
    private static let refreshTTL: TimeInterval = 10

    private var refreshTimer: Timer?
    private(set) var isRunning = false

    private init() {}

    /// Begin polling on a 5-minute interval. Idempotent.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh(force: Bool = false) async {
        guard !isLoading else { return }
        if !force, let last = lastRefreshedAt, Date().timeIntervalSince(last) < Self.refreshTTL {
            return
        }
        isLoading = true
        defer { isLoading = false }

        let info = await Task.detached(priority: .utility) {
            PulseUsageReader.read()
        }.value

        if let info {
            rateLimitInfo = info
            lastRefreshedAt = Date()
            return
        }
        let exists = await Task.detached(priority: .utility) {
            PulseUsageReader.cacheFileExists
        }.value
        if !exists {
            rateLimitInfo = nil
        }
        lastRefreshedAt = Date()
    }
}

// MARK: - Pulse Local Cache Source
//
// Pulse is a third-party Claude Code status-line tool that writes a usage
// snapshot to `~/.pulse/.cache/general.json`. Schema (relevant subset):
//
//     {
//       "schema_version": 2,
//       "updated_at": 1776155142321,              // epoch milliseconds
//       "rate_limits": {
//         "five_hour": { "used_percentage": 31, "resets_at": 1776168000 },
//         "seven_day": { "used_percentage": 22, "resets_at": 1776675600 }
//       }
//     }
//
// Reading this file is fully compliant: data produced locally by a tool
// the user already installed. If Pulse is not installed, read() returns nil.

enum PulseUsageReader {
    static var defaultCachePath: String {
        NSHomeDirectory() + "/.pulse/.cache/general.json"
    }

    static let fiveHourSeconds: TimeInterval = 5 * 3600
    static let sevenDaySeconds: TimeInterval = 7 * 86400

    static var cacheFileExists: Bool {
        FileManager.default.fileExists(atPath: defaultCachePath)
    }

    static func read(from path: String = defaultCachePath) -> RateLimitDisplayInfo? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }

        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let now = Date()
        // Resolve the "last activity" anchor: prefer payload updated_at, fall back to file mtime.
        var updatedAt: Date?
        if let ms = readDouble(json["updated_at"]) {
            updatedAt = Date(timeIntervalSince1970: ms / 1000.0)
        } else if let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date {
            updatedAt = mtime
        }

        let rateLimits = json["rate_limits"] as? [String: Any] ?? [:]
        let fiveHour = rateLimits["five_hour"] as? [String: Any]
        let sevenDay = rateLimits["seven_day"] as? [String: Any]

        let rawFivePct: Int? = readPercent(fiveHour?["used_percentage"])
        let rawSevenPct: Int? = readPercent(sevenDay?["used_percentage"])

        guard rawFivePct != nil || rawSevenPct != nil else { return nil }

        // Reset-time inference: if Pulse's recorded resets_at is missing or already past,
        // derive it from the last activity anchor + the nominal window length. When the
        // window has actually rolled over since the cache was written, percent resets to 0.
        let (fiveHourReset, fiveExpired) = resolveReset(
            raw: readEpochInstant(fiveHour?["resets_at"]),
            anchor: updatedAt,
            window: fiveHourSeconds,
            now: now
        )
        let (sevenDayReset, sevenExpired) = resolveReset(
            raw: readEpochInstant(sevenDay?["resets_at"]),
            anchor: updatedAt,
            window: sevenDaySeconds,
            now: now
        )

        return RateLimitDisplayInfo(
            fiveHourPercent: fiveExpired ? (rawFivePct != nil ? 0 : nil) : rawFivePct,
            sevenDayPercent: sevenExpired ? (rawSevenPct != nil ? 0 : nil) : rawSevenPct,
            fiveHourResetAt: fiveHourReset,
            sevenDayResetAt: sevenDayReset,
            planName: nil
        )
    }

    private static func readPercent(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let d = value as? Double { return Int(d) }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    private static func readDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    /// Epoch from JSON: supports seconds or milliseconds (values above ~year 2001 in "seconds" are treated as ms).
    private static func readEpochInstant(_ value: Any?) -> Date? {
        guard var sec = readDouble(value), sec > 0 else { return nil }
        if sec > 10_000_000_000 { sec /= 1000 }
        return Date(timeIntervalSince1970: sec)
    }

    /// Pick the freshest reset time and report whether the window has rolled over.
    ///
    /// Claude's 5h/7d windows are NOT a fixed wall-clock cadence: the next window only starts
    /// on the first usage after the previous window expires. So once `resets_at` is in the
    /// past, we can't infer the next boundary — there isn't one until the user sends another
    /// message and Pulse rewrites the cache with a fresh `resets_at`. Until then: percent = 0,
    /// reset time = nil.
    private static func resolveReset(raw: Date?, anchor: Date?, window: TimeInterval, now: Date) -> (Date?, Bool) {
        if let raw = raw {
            if raw > now { return (raw, false) }
            return (nil, true)
        }
        guard let anchor = anchor else { return (nil, false) }
        let elapsed = now.timeIntervalSince(anchor)
        if elapsed <= 0 { return (anchor.addingTimeInterval(window), false) }
        if elapsed >= window { return (nil, true) }
        return (anchor.addingTimeInterval(window), false)
    }
}
