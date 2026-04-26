import SwiftUI
import CodeIslandCore

// MARK: - Mascot Animation Speed Environment

private struct MascotSpeedKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var mascotSpeed: Double {
        get { self[MascotSpeedKey.self] }
        set { self[MascotSpeedKey.self] = newValue }
    }
}

/// Routes a CLI source identifier to the correct pixel mascot view.
struct MascotView: View {
    let source: String
    let status: AgentStatus
    var mood: MascotMood = .neutral
    var size: CGFloat = 27
    var animated: Bool = true
    @AppStorage(SettingsKey.mascotSpeed) private var speedPct = SettingsDefaults.mascotSpeed

    /// Sources that have implemented the 5 mood scenes (sick/tired/hungry/sad/joyful).
    /// Other mascots ignore the `mood` parameter and render the default idle scene.
    /// Update this set when adding mood scenes to a new mascot.
    static let moodSupportedSources: Set<String> = [
        "antigravity",
        "claude",
        "codebuddy",
        "codex",
        "copilot",
        "codybuddycn",
        "cursor",
        "droid",
        "gemini",
        "hermes",
        "kimi",
        "opencode",
        "qoder",
        "qwen",
        "stepfun",
        "trae",
        "traecli",
        "traecn",
        "workbuddy",
    ]

    /// Effective mood: only applied when status == .idle; active statuses override to neutral.
    private var effectiveMood: MascotMood {
        status == .idle ? mood : .neutral
    }

    var body: some View {
        Group {
            switch source {
            case "codex":
                DexView(status: status, mood: effectiveMood, size: size, animated: animated)
            case "gemini":
                GeminiView(status: status, mood: effectiveMood, size: size, animated: animated)
            case "cursor":
                CursorView(status: status, mood: effectiveMood, size: size, animated: animated)
            case "trae", "traecn", "traecli":
                TraeView(status: status, mood: effectiveMood, size: size, animated: animated)
            case "copilot":
                CopilotView(status: status, mood: effectiveMood, size: size, animated: animated)
            case "qoder":
                QoderView(status: status, mood: effectiveMood, size: size, animated: animated)
            case "droid":
                DroidView(status: status, mood: effectiveMood, size: size, animated: animated)
            case "codebuddy":
                BuddyView(status: status, mood: effectiveMood, size: size, animated: animated)
            case "codybuddycn":
                BuddyView(status: status, mood: effectiveMood, size: size, animated: animated)
            case "stepfun":
                StepFunView(status: status, mood: effectiveMood, size: size, animated: animated)
            case "opencode":
                OpenCodeView(status: status, mood: effectiveMood, size: size, animated: animated)
            case "qwen":
                QwenView(status: status, mood: effectiveMood, size: size, animated: animated)
            case "antigravity":
                AntiGravityView(status: status, mood: effectiveMood, size: size, animated: animated)
            case "workbuddy":
                WorkBuddyView(status: status, mood: effectiveMood, size: size, animated: animated)
            case "hermes":
                HermesView(status: status, mood: effectiveMood, size: size, animated: animated)
            case "kimi":
                KimiView(status: status, mood: effectiveMood, size: size)
            default:
                ClawdView(status: status, mood: effectiveMood, size: size, animated: animated)
            }
        }
        .environment(\.mascotSpeed, effectiveSpeed)
    }

    /// Mood scenes run at 1.5× base so the personality reads quickly even at
    /// the default speed setting. Multiplier preserves the "off" (0%) case —
    /// 0 × anything is still 0, so users who turned animation off stay off.
    private var effectiveSpeed: Double {
        let base = Double(speedPct) / 100.0
        return effectiveMood != .neutral ? base * 1.5 : base
    }
}
