import SwiftUI
import CodeIslandCore

/// Settings tab 2: vital stats, cyber stats, lifetime statistics, and controls.
struct CharacterStatsPage: View {
    @ObservedObject private var l10n = L10n.shared
    @State private var showResetConfirm = false
    @State private var showRestoreConfirm = false
    @State private var engine = CharacterEngine.shared
    private var stats: CharacterStats { engine.characterStats }

    var body: some View {
        Form {
            // MARK: - Vital Section
            Section {
                VStack(spacing: 8) {
                    bigVitalRow(icon: "heart.fill",
                                label: l10n["character.vital.health"],
                                desc: l10n["character.vital.health.desc"],
                                value: stats.vital.health,
                                color: Color(red: 1.0, green: 0.38, blue: 0.45))
                    bigVitalRow(icon: "face.smiling",
                                label: l10n["character.vital.mood"],
                                desc: l10n["character.vital.mood.desc"],
                                value: stats.vital.mood,
                                color: Color(red: 1.0, green: 0.85, blue: 0.3))
                    bigVitalRow(icon: "fork.knife",
                                label: l10n["character.vital.hunger"],
                                desc: l10n["character.vital.hunger.desc"],
                                value: stats.vital.hunger,
                                color: Color(red: 1.0, green: 0.72, blue: 0.35))
                    bigVitalRow(icon: "bolt.fill",
                                label: l10n["character.vital.energy"],
                                desc: l10n["character.vital.energy.desc"],
                                value: stats.vital.energy,
                                color: Color(red: 0.3, green: 0.95, blue: 0.7))
                }
            } header: {
                Text(l10n["character.section.vitals"])
            }

            // MARK: - Cyber Section
            Section {
                VStack(spacing: 6) {
                    cyberStatRow(label: l10n["character.cyber.focus"],
                                 desc: l10n["character.cyber.focus.desc"],
                                 value: stats.cyber.focus,
                                 color: Color(red: 0.4, green: 0.9, blue: 0.6))
                    cyberStatRow(label: l10n["character.cyber.diligence"],
                                 desc: l10n["character.cyber.diligence.desc"],
                                 value: stats.cyber.diligence,
                                 color: Color(red: 0.5, green: 0.75, blue: 1.0))
                    cyberStatRow(label: l10n["character.cyber.collab"],
                                 desc: l10n["character.cyber.collab.desc"],
                                 value: stats.cyber.collab,
                                 color: Color(red: 0.75, green: 0.5, blue: 1.0))
                    cyberStatRow(label: l10n["character.cyber.taste"],
                                 desc: l10n["character.cyber.taste.desc"],
                                 value: stats.cyber.taste,
                                 color: Color(red: 1.0, green: 0.6, blue: 0.4))
                    cyberStatRow(label: l10n["character.cyber.curiosity"],
                                 desc: l10n["character.cyber.curiosity.desc"],
                                 value: stats.cyber.curiosity,
                                 color: Color(red: 0.4, green: 0.85, blue: 1.0))
                }
            } header: {
                Text(l10n["character.section.cyber"])
            }

            // MARK: - Statistics Section
            Section {
                LabeledContent(l10n["character.stats.totalSessions"],
                               value: "\(stats.stats.totalSessions)")
                LabeledContent(l10n["character.stats.totalToolCalls"],
                               value: "\(stats.stats.totalToolCalls)")
                LabeledContent(l10n["character.stats.totalActive"],
                               value: formatDuration(stats.stats.totalActiveSeconds))
                LabeledContent(l10n["character.stats.todayActive"],
                               value: formatDuration(stats.stats.currentDayActiveSeconds))
                LabeledContent(l10n["character.stats.streak"],
                               value: "\(stats.stats.streakDays)\(l10n["character.stats.streakSuffix"])")
                LabeledContent(l10n["character.stats.overwork"],
                               value: "\(stats.stats.overworkStreakDays)\(l10n["character.stats.streakSuffix"])")
            } header: {
                Text(l10n["character.section.lifetime"])
            }

            // Tool Ranking
            if !stats.stats.toolUseCount.isEmpty {
                Section {
                    let top10 = stats.stats.toolUseCount
                        .sorted { $0.value > $1.value }
                        .prefix(10)
                    ForEach(Array(top10.enumerated()), id: \.element.key) { i, kv in
                        HStack {
                            Text(String(format: "%2d.", i + 1))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(kv.key)
                                .font(.system(size: 11, design: .monospaced))
                            Spacer()
                            Text("\(kv.value)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(l10n["character.stats.toolRanking"])
                }
            }

            // CLI Ranking
            if !stats.stats.cliUseCount.isEmpty {
                Section {
                    let sorted = stats.stats.cliUseCount.sorted { $0.value > $1.value }
                    ForEach(sorted, id: \.key) { kv in
                        LabeledContent(CLIProcessResolver.displayName(forSource: kv.key),
                                       value: "\(kv.value)")
                    }
                } header: {
                    Text(l10n["character.stats.cliRanking"])
                }
            }

            // Last 7 Days bar chart
            Section {
                last7DaysChart
            } header: {
                Text(l10n["character.stats.last7Days"])
            }

            // MARK: - Controls Section
            Section {
                Toggle(l10n["character.settings.pause"], isOn: Binding(
                    get: { engine.characterStats.settings.paused },
                    set: { engine.setPaused($0) }
                ))

                // Once-per-day full vital restore. Engine guards on
                // `canFullRestoreToday` (compares lastFullRestoreDate to
                // today's natural-day string) — UI mirrors that gate so the
                // disabled state and the confirm action stay in sync.
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        showRestoreConfirm = true
                    } label: {
                        Label(l10n["character.settings.fullRestore"],
                              systemImage: "heart.circle.fill")
                    }
                    .disabled(!engine.canFullRestoreToday)

                    if !engine.canFullRestoreToday {
                        Text(l10n["character.settings.fullRestore.usedToday"])
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .confirmationDialog(l10n["character.settings.fullRestore.confirm"],
                                    isPresented: $showRestoreConfirm,
                                    titleVisibility: .visible) {
                    Button(l10n["character.settings.fullRestore"]) {
                        _ = engine.tryFullRestore()
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        _ = engine.rebuild()
                    } label: {
                        Label(l10n["character.settings.rebuild"], systemImage: "arrow.clockwise")
                    }

                    Spacer(minLength: 0)

                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label(l10n["character.settings.reset"], systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .tint(.red)
                }
                .confirmationDialog(l10n["character.settings.resetConfirm"],
                                    isPresented: $showResetConfirm,
                                    titleVisibility: .visible) {
                    Button(l10n["character.settings.reset"], role: .destructive) {
                        engine.reset()
                    }
                }
            } header: {
                Text(l10n["character.section.controls"])
            }
        }
        .formStyle(.grouped)
        .onAppear { engine.lazyTick() }
    }

    // MARK: - Sub-views

    private func bigVitalRow(icon: String, label: String, desc: String,
                              value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(label)
                    .font(.body)
                    .fontWeight(.medium)
                Spacer()
                Text("\(formatStatValue(value)) / 100")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: max(0, min(value / 100, 1)))
                .tint(color)
            Text(desc)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func cyberStatRow(label: String, desc: String,
                               value: Double, color: Color) -> some View {
        let lv = Int(value / 1000)
        let progress = value.truncatingRemainder(dividingBy: 1000)
        let frac = max(0, min(progress / 1000, 1))

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.body)
                    .fontWeight(.medium)
                Spacer()
                HStack(spacing: 6) {
                    Text("Lv \(lv)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(color)
                    Text("·")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(formatStatValue(progress)) / 1000")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            ProgressView(value: frac)
                .tint(color)
            Text(desc)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private static let chartDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()

    private var last7DaysChart: some View {
        let rows = engine.last7DaysActive()

        if rows.isEmpty || rows.allSatisfy({ $0.seconds <= 0 }) {
            return AnyView(
                Text(l10n["character.stats.last7days.empty"])
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            )
        }

        let maxSeconds = rows.map { $0.seconds }.max().map { max($0, 1) } ?? 1
        let chartHeight: CGFloat = 64
        let barColor = Color(red: 0.3, green: 0.85, blue: 0.5)

        return AnyView(
            HStack(alignment: .top, spacing: 8) {
                // Y-axis labels: max / mid / 0
                VStack(alignment: .trailing, spacing: 0) {
                    Text(formatDurationShort(maxSeconds))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(formatDurationShort(maxSeconds / 2))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Spacer(minLength: 0)
                    Text("0")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 28, height: chartHeight, alignment: .trailing)

                // Bars + X-axis baseline + date labels
                VStack(spacing: 3) {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            let isToday = Calendar.current.isDateInToday(row.date)
                            let height = CGFloat(row.seconds) / CGFloat(maxSeconds) * chartHeight
                            VStack {
                                Spacer(minLength: 0)
                                Rectangle()
                                    .fill(barColor.opacity(isToday ? 0.9 : 0.55))
                                    .frame(width: 16, height: max(height, 2))
                                    .cornerRadius(2)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: chartHeight, alignment: .bottom)

                    // X-axis baseline
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)

                    // X-axis date labels
                    HStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            let isToday = Calendar.current.isDateInToday(row.date)
                            let label = isToday
                                ? l10n["character.stats.last7days.today"]
                                : Self.chartDateFmt.string(from: row.date)
                            Text(label)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(isToday ? .primary : .secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        )
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// Compact axis-friendly duration: "0", "30m", "2h", "2h30m". Drops trailing
    /// zero minutes so the y-axis labels stay tight at small widths.
    private func formatDurationShort(_ seconds: Int) -> String {
        if seconds <= 0 { return "0" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return m == 0 ? "\(h)h" : "\(h)h\(m)m" }
        return "\(m)m"
    }
}

/// Show integers when the value has no meaningful fractional part, otherwise show one decimal.
/// Uses string-suffix trim instead of float equality to avoid `100.0001` slipping through as "100.0".
fileprivate func formatStatValue(_ value: Double) -> String {
    let s = String(format: "%.1f", value)
    if s.hasSuffix(".0") {
        return String(s.dropLast(2))
    }
    return s
}
