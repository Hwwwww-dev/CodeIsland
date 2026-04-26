import SwiftUI
import CodeIslandCore

/// In-island character panel (L1 layout, surface == .characterPanel).
/// Shows 4 vital bars (2×2 grid) + 5 cyber rows.
struct CharacterPanelView: View {
    var appState: AppState
    @ObservedObject private var l10n = L10n.shared
    @State private var engine = CharacterEngine.shared
    @AppStorage(SettingsKey.defaultSource) private var defaultSource = SettingsDefaults.defaultSource

    private var stats: CharacterStats { engine.characterStats }
    private var currentMood: MascotMood { engine.currentMood }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerRow

            Divider()
                .background(.white.opacity(0.12))
                .padding(.horizontal, 10)

            // Vital bars 2×2 grid
            vitalSection

            // 8pt gap instead of second Divider
            Spacer().frame(height: 8)

            // Cyber rows
            cyberSection
        }
        .padding(.vertical, 6)
        .onAppear { engine.lazyTick() }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Spacer()

            // Mascot as identity — tap to jump into Settings → Status & Stats.
            Button {
                SettingsWindowController.shared.show(page: .mascots, mascotsTab: 1)
            } label: {
                ZStack(alignment: .topTrailing) {
                    MascotView(
                        source: defaultSource,
                        status: .idle,
                        mood: currentMood,
                        size: 22,
                        animated: true
                    )
                    .id("\(defaultSource)-\(currentMood.rawValue)")

                    if currentMood != .neutral {
                        Image(systemName: moodBadgeIcon)
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(moodBadgeColor)
                            .frame(width: 10, height: 10)
                            .background(Circle().fill(.black.opacity(0.85)))
                            .offset(x: 5, y: -4)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 5)
    }

    private var moodBadgeIcon: String {
        switch currentMood {
        case .sick: return "cross.fill"
        case .tired: return "bolt.slash.fill"
        case .hungry: return "fork.knife"
        case .sad: return "cloud.rain.fill"
        case .joyful: return "sparkles"
        case .neutral: return "circle"
        }
    }

    private var moodBadgeColor: Color {
        switch currentMood {
        case .sick: return Color(red: 0.45, green: 1.0, blue: 0.45)
        case .tired: return Color(red: 0.45, green: 0.55, blue: 1.0)
        case .hungry: return Color(red: 1.0, green: 0.72, blue: 0.35)
        case .sad: return Color(red: 0.35, green: 0.6, blue: 1.0)
        case .joyful: return Color(red: 1.0, green: 0.85, blue: 0.25)
        case .neutral: return .white.opacity(0.6)
        }
    }

    // MARK: - Vital Section (2×2 grid)

    private var vitalSection: some View {
        GeometryReader { geo in
            let cellWidth = (geo.size.width - 24 - 8) / 2  // 12px padding each side, 8px gap
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    vitalCell(icon: "heart.fill",
                              label: l10n["character.vital.health"],
                              value: stats.vital.health,
                              color: Color(red: 1.0, green: 0.38, blue: 0.45),
                              width: cellWidth)
                    vitalCell(icon: "face.smiling",
                              label: l10n["character.vital.mood"],
                              value: stats.vital.mood,
                              color: Color(red: 1.0, green: 0.85, blue: 0.3),
                              width: cellWidth)
                }
                HStack(spacing: 8) {
                    vitalCell(icon: "fork.knife",
                              label: l10n["character.vital.hunger"],
                              value: stats.vital.hunger,
                              color: Color(red: 1.0, green: 0.72, blue: 0.35),
                              width: cellWidth)
                    vitalCell(icon: "bolt.fill",
                              label: l10n["character.vital.energy"],
                              value: stats.vital.energy,
                              color: Color(red: 0.3, green: 0.95, blue: 0.7),
                              width: cellWidth)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 60)
        .padding(.top, 6)
    }

    private func vitalCell(icon: String, label: String, value: Double, color: Color, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 0)
                Text(formatStatValue(value))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            // Capsule bar — full rounded ends, 4pt height
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.08))
                    .frame(height: 4)
                GeometryReader { g in
                    Capsule()
                        .fill(color.opacity(0.85))
                        .frame(width: g.size.width * CGFloat(value / 100), height: 4)
                }
                .frame(height: 4)
            }
        }
        .frame(width: width)
    }

    // MARK: - Cyber Section

    private var cyberSection: some View {
        let cyber = stats.cyber
        return VStack(spacing: 1) {
            cyberRow(label: l10n["character.cyber.focus"],
                     value: cyber.focus,
                     color: Color(red: 0.4, green: 0.9, blue: 0.6))
            cyberRow(label: l10n["character.cyber.diligence"],
                     value: cyber.diligence,
                     color: Color(red: 0.5, green: 0.75, blue: 1.0))
            cyberRow(label: l10n["character.cyber.collab"],
                     value: cyber.collab,
                     color: Color(red: 0.75, green: 0.5, blue: 1.0))
            cyberRow(label: l10n["character.cyber.taste"],
                     value: cyber.taste,
                     color: Color(red: 1.0, green: 0.6, blue: 0.4))
            cyberRow(label: l10n["character.cyber.curiosity"],
                     value: cyber.curiosity,
                     color: Color(red: 0.4, green: 0.85, blue: 1.0))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
    }

    private func cyberRow(label: String, value: Double, color: Color) -> some View {
        let lv = Int(value / 1000)
        let progress = value.truncatingRemainder(dividingBy: 1000)
        let progressFrac = min(progress / 1000, 1.0)

        return HStack(spacing: 0) {
            // Fixed-width leading column: dot + label
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
                Text(label)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(width: 64, alignment: .leading)

            // Trailing column: Lv + progress bar + value
            HStack(spacing: 5) {
                Text("Lv\(lv)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(color.opacity(0.9))

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(color.opacity(0.12))
                            .frame(height: 3)
                        Capsule()
                            .fill(color.opacity(0.75))
                            .frame(width: geo.size.width * CGFloat(progressFrac), height: 3)
                    }
                }
                .frame(height: 3)

                Text("\(formatStatValue(progress))/1k")
                    .font(.system(size: 7, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(height: 14)
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
