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
        return "\(Int(remaining / 86400))d"
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
        return "\(Int(remaining / 86400))d"
    }
}

/// Periodically reads Pulse's local cache file and publishes Claude usage.
/// Compliant: reads only `~/.pulse/.cache/general.json`. No network traffic.
@MainActor
final class RateLimitMonitor: ObservableObject {
    static let shared = RateLimitMonitor()

    @Published private(set) var rateLimitInfo: RateLimitDisplayInfo?
    @Published private(set) var isLoading = false

    private var refreshTimer: Timer?
    private(set) var isRunning = false

    private init() {}

    /// Begin polling on a 5-minute interval. Idempotent.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
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

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        if let info = PulseUsageReader.read() {
            rateLimitInfo = info
            return
        }
        if !PulseUsageReader.cacheFileExists {
            rateLimitInfo = nil
        }
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

    /// Max cache age trusted. Older than 15 min is considered stale.
    static let freshnessWindow: TimeInterval = 15 * 60

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
        if let updatedAtMs = readDouble(json["updated_at"]) {
            let updatedAt = Date(timeIntervalSince1970: updatedAtMs / 1000.0)
            if now.timeIntervalSince(updatedAt) > freshnessWindow { return nil }
        } else if let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date,
                  now.timeIntervalSince(mtime) > freshnessWindow {
            return nil
        }

        let rateLimits = json["rate_limits"] as? [String: Any] ?? [:]
        let fiveHour = rateLimits["five_hour"] as? [String: Any]
        let sevenDay = rateLimits["seven_day"] as? [String: Any]

        let fiveHourPct: Int? = readPercent(fiveHour?["used_percentage"])
        let sevenDayPct: Int? = readPercent(sevenDay?["used_percentage"])

        guard fiveHourPct != nil || sevenDayPct != nil else { return nil }

        let fiveHourReset = readEpochSeconds(fiveHour?["resets_at"])
        let sevenDayReset = readEpochSeconds(sevenDay?["resets_at"])

        return RateLimitDisplayInfo(
            fiveHourPercent: fiveHourPct,
            sevenDayPercent: sevenDayPct,
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

    private static func readEpochSeconds(_ value: Any?) -> Date? {
        guard let seconds = readDouble(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
