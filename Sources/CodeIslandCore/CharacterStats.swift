import Foundation

// MARK: - MascotMood

/// Derived display mood for the active mascot. Orthogonal to AgentStatus.
/// Only applies when AgentStatus == .idle; active statuses always win.
public enum MascotMood: String, Codable, Sendable, Equatable {
    case critical // ≥2 vitals < 30  (priority 0 — highest, composite burnout)
    case sick     // health < 30  (priority 1)
    case tired    // energy < 30  (priority 2)
    case hungry   // hunger < 30  (priority 3)
    case sad      // mood < 30    (priority 4)
    case joyful   // all ≥ 80     (priority 5)
    case neutral  // otherwise    (priority 6 — lowest / default)
}

// MARK: - VitalStats

/// Real-time vital stats, all clamped 0–100.
public struct VitalStats: Codable, Sendable, Equatable {
    public var hunger: Double = 100
    public var mood:   Double = 100
    public var energy: Double = 100
    public var health: Double = 100

    public init(hunger: Double = 100, mood: Double = 100,
                energy: Double = 100, health: Double = 100) {
        self.hunger = hunger
        self.mood   = mood
        self.energy = energy
        self.health = health
    }

    public mutating func clamp() {
        hunger = min(max(hunger, 0), 100)
        mood   = min(max(mood,   0), 100)
        energy = min(max(energy, 0), 100)
        health = min(max(health, 0), 100)
    }
}

// MARK: - CyberStats

/// Permanent accumulation stats. Level = floor(total / 1000).
public struct CyberStats: Codable, Sendable, Equatable {
    public var focus:      Double = 0
    public var diligence:  Double = 0
    public var collab:     Double = 0
    public var taste:      Double = 0
    public var curiosity:  Double = 0

    public init(focus: Double = 0, diligence: Double = 0, collab: Double = 0,
                taste: Double = 0, curiosity: Double = 0) {
        self.focus     = focus
        self.diligence = diligence
        self.collab    = collab
        self.taste     = taste
        self.curiosity = curiosity
    }

    public func level(for value: Double) -> Int { Int(value / 1000) }
    public func progress(for value: Double) -> Double { value.truncatingRemainder(dividingBy: 1000) }
}

// MARK: - LifetimeStats

public struct LifetimeStats: Codable, Sendable, Equatable {
    public var totalSessions:          Int = 0
    public var totalToolCalls:         Int = 0
    public var totalActiveSeconds:     Int = 0
    public var currentDayActiveSeconds: Int = 0
    public var currentDayDate:         String = ""     // yyyy-MM-dd
    public var streakDays:             Int = 0
    public var lastActiveDate:         String = ""     // yyyy-MM-dd
    public var toolUseCount:           [String: Int] = [:]
    public var cliUseCount:            [String: Int] = [:]
    public var overworkStreakDays:     Int = 0
    /// Date (yyyy-MM-dd) the manual "restore all vitals to 100" button was
    /// last used. Empty string means never used. The button's once-per-day
    /// gate compares against `LifetimeStats.todayString`.
    public var lastFullRestoreDate:    String = ""
    // last7DaysActiveSeconds removed; data now lives in character_daily_active SQLite table.
    // Query via CharacterPersistence.last7DaysActive() or CharacterEngine.last7DaysActive().

    public init() {}

    // Shared date formatter
    private static let dayFmt: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    // Convenience: today's date string
    public static var todayString: String {
        dayFmt.string(from: Date())
    }
}

// MARK: - CharacterSettings (embedded in CharacterStats)

public struct CharacterSettings: Codable, Sendable, Equatable {
    public var paused: Bool = false
    /// When false (default), PreToolUse/PostToolUse hook events store a compact
    /// payload (success/sizes/keys only) instead of the full raw JSON. Saves
    /// ~70% of event-table size on tool-heavy users. Toggle ON only if you
    /// need full event replay capability.
    public var logRawHookPayloads: Bool = false
    /// When false (default), internal Tick events (timer-driven decay/recovery)
    /// do NOT write a row to character_event. Mutations still apply and stats
    /// are still snapshotted to character_state. Saves ~1 row every 1–5s of
    /// runtime. Toggle ON only if you want a full ledger of intra-second drift.
    public var logTickEvents: Bool = false
    public init(
        paused: Bool = false,
        logRawHookPayloads: Bool = false,
        logTickEvents: Bool = false
    ) {
        self.paused = paused
        self.logRawHookPayloads = logRawHookPayloads
        self.logTickEvents = logTickEvents
    }
}

// MARK: - CharacterStats (root Codable model)

public struct CharacterStats: Codable, Sendable, Equatable {
    public var version:       Int = 3
    public var lastTickedAt:  Date = Date()
    public var vital:         VitalStats = VitalStats()
    public var cyber:         CyberStats = CyberStats()
    public var stats:         LifetimeStats = LifetimeStats()
    public var settings:      CharacterSettings = CharacterSettings()

    public init() {}

    // MARK: Mood derivation

    /// Derives the current MascotMood from vital stats using priority ordering.
    /// Composite burnout (.critical) takes precedence: when 2 or more vitals
    /// are below 30, single-axis priority becomes misleading ("you're tired"
    /// when you're actually starving AND tired AND sad). Single-axis moods
    /// kick in only when exactly one vital is in the red.
    public var derivedMood: MascotMood {
        let lowCount =
            (vital.health < 30 ? 1 : 0) +
            (vital.energy < 30 ? 1 : 0) +
            (vital.hunger < 30 ? 1 : 0) +
            (vital.mood   < 30 ? 1 : 0)
        if lowCount >= 2 { return .critical }
        if vital.health < 30 { return .sick }
        if vital.energy < 30 { return .tired }
        if vital.hunger < 30 { return .hungry }
        if vital.mood   < 30 { return .sad }
        if vital.hunger >= 80 && vital.mood >= 80 && vital.energy >= 80 && vital.health >= 80 {
            return .joyful
        }
        return .neutral
    }
}
