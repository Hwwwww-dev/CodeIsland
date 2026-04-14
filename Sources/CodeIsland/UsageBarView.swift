//
//  UsageBarView.swift
//  CodeIsland
//
//  Compact usage readout for Claude (Pulse) + Codex (JSONL) monitors.
//

import SwiftUI

struct UsageBarView: View {
    @ObservedObject private var rateLimitMonitor = RateLimitMonitor.shared
    @ObservedObject private var codexUsageMonitor = CodexUsageMonitor.shared

    var body: some View {
        let claude = rateLimitMonitor.rateLimitInfo
        let codex = codexUsageMonitor.snapshot

        if claude == nil && (codex?.isEmpty ?? true) {
            EmptyView()
        } else {
            HStack(spacing: 12) {
                if let info = claude {
                    UsageChip(
                        icon: "clock.fill",
                        label: "Claude",
                        text: info.displayText,
                        color: info.color,
                        tooltip: info.tooltip
                    )
                }
                if let snapshot = codex, !snapshot.isEmpty {
                    CodexUsageChip(snapshot: snapshot)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }
}

private struct UsageChip: View {
    let icon: String
    let label: String
    let text: String
    let color: Color
    let tooltip: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundColor(.white.opacity(0.6))
            Text(text).foregroundColor(color)
        }
        .help(tooltip)
    }
}

private struct CodexUsageChip: View {
    let snapshot: CodexUsageSnapshot

    private var displayText: String {
        snapshot.windows.prefix(2).map { w in
            let remaining = formatRemaining(w.resetsAt)
            let suffix = remaining.isEmpty ? "" : " \(remaining)"
            return "\(w.label) \(w.roundedUsedPercentage)%\(suffix)"
        }.joined(separator: " | ")
    }

    private var maxPct: Int {
        snapshot.windows.map { $0.roundedUsedPercentage }.max() ?? 0
    }

    private var color: Color {
        if maxPct >= 90 { return Color(red: 0.94, green: 0.27, blue: 0.27) }
        if maxPct >= 70 { return Color(red: 1.0, green: 0.6, blue: 0.2) }
        return Color(red: 0.29, green: 0.87, blue: 0.5)
    }

    private var tooltip: String {
        var lines: [String] = []
        if let plan = snapshot.planType { lines.append("Plan: \(plan)") }
        for w in snapshot.windows {
            let reset = formatRemainingLong(w.resetsAt)
            let suffix = reset.isEmpty ? "" : " (resets in \(reset))"
            lines.append("\(w.label): \(w.roundedUsedPercentage)%\(suffix)")
        }
        return lines.isEmpty ? "Codex usage" : lines.joined(separator: "\n")
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

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("Codex").foregroundColor(.white.opacity(0.6))
            Text(displayText).foregroundColor(color)
        }
        .help(tooltip)
    }
}
