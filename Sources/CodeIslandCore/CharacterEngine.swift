
import Foundation
import Observation
import os.log

private let log = Logger(subsystem: "com.codeisland", category: "CharacterEngine")

/// Lightweight context passed from AppState into CharacterEngine.handle().
/// Distinct from the existing SessionSnapshot used by AppState to avoid conflicts.
public struct CharacterSessionContext: Sendable {
    public let source: String?
    public let toolSuccessRate: Double   // 0.0–1.0
    public let totalTools: Int
    public let activeSessionCount: Int
    public let hasActiveSession: Bool

    public init(source: String? = nil,
                toolSuccessRate: Double = 1.0,
                totalTools: Int = 0,
                activeSessionCount: Int = 0,
                hasActiveSession: Bool = false) {
        self.source = source
        self.toolSuccessRate = toolSuccessRate
        self.totalTools = totalTools
        self.activeSessionCount = activeSessionCount
        self.hasActiveSession = hasActiveSession
    }
}

/// Maximum elapsed time used for decay computation.
/// Clamps "you've been away 30 days" devastation to a 7-day maximum.
private let maxDecayHours: Double = 7 * 24

/// Hunger decay per hour while a session is active. Hunger here = "needs
/// feeding via activity + tool calls" (work feeds the character), not biological
/// hunger. 100 → hungry threshold (30) takes ~17.5h of sustained work; one 8h
/// workday tops up easily via meal rewards.
private let hungerDecayPerHour: Double = 4.0
/// Energy decay per hour while a session is active. The new baseline drain;
/// calibrated to match `hungerDecayPerHour` so the two drivers move in
/// lockstep — an 8h workday without meals lands both at ~70, a 24h grind
/// drives both into the hungry/tired zone.
private let energyDecayPerHourActive: Double = 4.0
/// Per-tool energy cost on successful PostToolUse. Down from `-0.2` (which
/// could spike `-10` per turn under 50-tool parallel-agent batches) to
/// `-0.1`, retained on top of the time-based `energyDecayPerHourActive`
/// baseline so heavy tool usage still feels heavier than light prompts —
/// just no longer crashing energy in a single turn.
private let energyCostPerToolSuccess: Double = 0.1

/// Idle recovery rates (exp approach toward each vital's natural ceiling).
/// Different τ per vital is deliberate — anthropomorphic: rest restores energy
/// fastest, mood medium, health slowly; hunger only refills marginally without
/// food. All four share the same exponential shape (consistent UI feel) but
/// land at different ceilings without explicit refill events.
///
///   ceiling < 100 means "rest alone gets you to OK, not great";
///   pushing past the ceiling requires the matching event channel
///   (meal for hunger/energy beyond ceiling, prompts/PostStop for mood beyond
///   70, daily-roll healthy-day for health beyond 80).
private let idleHungerRecoveryPerMinute: Double = 0.0167   // τ ≈ 60 min
private let idleHungerCeiling:           Double = 60
private let idleEnergyRecoveryPerMinute: Double = 0.075    // τ ≈ 13 min
private let idleEnergyCeiling:           Double = 100
private let idleMoodRecoveryPerMinute:   Double = 0.033    // τ ≈ 30 min
private let idleMoodCeiling:             Double = 70
private let idleHealthRecoveryPerMinute: Double = 0.00417  // τ ≈ 240 min
private let idleHealthCeiling:           Double = 80

/// Snap-to-ceiling epsilon shared across all four idle recoveries. Pure exp
/// approach only ever asymptotes; when within ε we pin exactly to the ceiling
/// so values terminate (resolution-invisible at ~1 gauge unit).
private let idleRecoverySnapThreshold: Double = 0.1
/// Cooldown after the last active session before idle recovery starts (seconds).
/// Brief task-switching pauses (<60s) shouldn't count as rest. If a session resumes
/// within the cooldown, the buffer just resets — no recovery happened anyway.
private let idleRecoveryBufferSeconds: TimeInterval = 60

/// Damping applied to idle-recovery rates while a session is active. The body
/// is still healing while you're working — just much slower than at rest. At
/// 0.1× the effective τ stretches 10× (e.g. mood τ 30min idle → 5h while
/// active), making the recovery visually imperceptible per-minute but real
/// over a multi-hour stretch. Set to 0 to make active = pure decay (the prior
/// behavior); set to 1 to make rest and work indistinguishable.
private let activeRecoveryDamping: Double = 0.1

/// Minimum interval between lazy ticks (avoids per-frame recomputes).
private let lazyTickMinInterval: TimeInterval = 1.0
/// Active prompt sampling interval. Keeps active time from depending on Stop delivery.
private let activePromptSampleInterval: TimeInterval = 5.0
/// Meal reward bands, ordered from largest to smallest so the first match wins.
/// Calibrated against hungerDecayPerHour=4: a typical 8h workday (mix of long
/// focused turns and short interactions) refills the gauge to full, short
/// interactions top up generously, and pure idle/slacking still drifts hungry.
private let mealRewardBands: [(seconds: Int, tools: Int, reward: Double)] = [
    (30 * 60, 30, 12),
    (20 * 60, 20, 9),
    (10 * 60, 10, 6),
    (5 * 60, 5, 4),
    (2 * 60, 3, 2),
    (1 * 60, 2, 1),
]

/// Vital-coupling weights: when source vital changes by ΔX, each target
/// vital receives ΔX × weight in the same direction.
///
/// Disabled (all zero) under the Sims-style model — mood follows body via
/// `applyMoodFollowsBody` (target = (hunger+energy)/2 with τ=1h), and
/// health is computed from a `body_score` threshold integrator
/// (`applyHealthFromBodyScore`). Direct event-time propagation would
/// double-count those continuous channels.
///
/// Kept as a structural hook so future event handlers can opt back in
/// without redesigning the delta plumbing.
private enum VitalKey { case hunger, mood, energy, health }
private let vitalCouplingWeights: [VitalKey: [VitalKey: Double]] = [
    .hunger: [:],
    .mood:   [:],
    .energy: [:],
    .health: [:],
]

/// Asymmetric propagation multiplier from driver vitals (hunger, energy) to
/// mood/health. Negative branch is now flat 1.0× across all driver levels —
/// the previous 2.0× critical-zone amplification created a death spiral
/// (already-low body received double damage on top of normal decay) that no
/// human physiology mirrors. Positive multiplier still rewards maintaining
/// good shape (1.5× when driver ≥ 60), so healthy bodies still amplify
/// recovery into mood/health.
///
///   any driver value, negative delta  →  1.0×
///   driver < 30  (critical)  →  positive 1.0×
///   30 ≤ d < 60  (low)       →  positive 1.2×
///   driver ≥ 60  (normal)    →  positive 1.5×
///
/// Applied in `applyVitalDelta` to (delta · weight), not to the driver's own
/// delta. Single-pass — the amplified propagation does NOT recurse.
private func propagationMultiplier(driverBefore v: Double, deltaSign: Double) -> Double {
    if deltaSign < 0 { return 1.0 }
    if v < 30 { return 1.0 }
    if v < 60 { return 1.2 }
    return 1.5
}
/// Mood follows body state — specifically the average of hunger and energy,
/// the two drivers. Health is excluded: it's the long-arc accumulator and
/// its slow drift would muddle mood's fast-twitch character. Arithmetic
/// mean (50/50) for simplicity — Sims-style: cranky if either hungry OR
/// tired, fine if both okay.
private let moodFollowsBodyWeights = (hunger: 0.5, energy: 0.5)
/// Drift rate (per hour) for mood toward the weighted geometric mean of
/// hunger/energy/health. Set to 1.0 (τ=1h) so mood reacts quickly to body
/// state — drops to ~63% of the gap within 1h, ~95% within 3h. Mood is the
/// fast-twitch indicator (the user-visible expression of "how the body is
/// doing right now"); hunger/energy are the slow-twitch drivers, health is
/// the long-arc accumulator. Event spikes (prompts +2 / PostStop +3 / fail
/// -2 / deny -3) ride on top, capped above target by `moodOvershootCap`.
private let moodEquilibriumRatePerHour: Double = 1.0
/// Maximum amount mood is allowed to sit ABOVE the equilibrium target.
/// Event-driven mood rewards (UserPromptSubmit +2, PostStop +3, success bonus)
/// can spike mood above what the body deserves, but only by this much; any
/// excess is yanked down to `target + cap` immediately on the next tick. No
/// lower cap — feeling worse than the body deserves is allowed (bad streak
/// emotions persist), and positive events naturally pull it back.
private let moodOvershootCap: Double = 8
/// Health threshold integrator parameters (Sims-style "long-arc accumulator"):
/// each tick computes body_score = (hunger + energy + mood) / 3 and steers
/// health based on whether the body is sustaining a deficit or a surplus.
/// Calibrated so health barely moves under typical mixed days, but a long
/// burnout grind drains it noticeably and a sustained healthy stretch lifts
/// it. Sub-hour transients (one bad lunch) don't show up.
private let bodyScoreLowThreshold:           Double = 30
private let bodyScoreHighThreshold:          Double = 70
private let healthDecayPerHourLowBody:       Double = 0.3
private let healthRecoveryPerHourHighBody:   Double = 0.2

/// Snap-to-target epsilon for mood equilibrium drift. Same rationale as
/// `idleEnergyRecoveryFullThreshold` — exp drift only ever asymptotes; we
/// pin to the geometric-mean target when within ε so the gauge can actually
/// reach 100 (or any other steady-state target) instead of asymptoting forever.
private let moodEquilibriumSnapThreshold: Double = 0.1
private let minLoggedVitalFraction: Double = 0.01

private let characterRuleVersion = 1

// MARK: -

private enum PromptTurnOrigin {
    case explicitPrompt
    case activityFallback
}

private struct EventMutationMetadata {
    var derived: [String: AnyCodableLike]
    var dailyActiveWrites: [String: Int] = [:]
}

private struct TrackedSessionMetadata: Equatable {
    var source: String?
    var providerSessionID: String?
    var cwd: String?
    var model: String?
    var permissionMode: String?
    var sessionTitle: String?
    var remoteHostID: String?
    var remoteHostName: String?

    var hasMeaningfulValue: Bool {
        source != nil
            || providerSessionID != nil
            || cwd != nil
            || model != nil
            || permissionMode != nil
            || sessionTitle != nil
            || remoteHostID != nil
            || remoteHostName != nil
    }
}

private struct EngineTransientStateSnapshot {
    let lastActiveSource: String?
    let sessionMetadataByID: [String: TrackedSessionMetadata]
    let sessionFocusThresholdFired: [String: Bool]
    let promptStartTimes: [String: Date]
    let promptLastSampleTimes: [String: Date]
    let promptTurnOrigins: [String: PromptTurnOrigin]
    let sessionMealActiveSeconds: [String: Int]
    let sessionActiveSeconds: [String: Int]
    let sessionLastFocusActiveSeconds: [String: Int]
    let lastToolEventTime: [String: Date]
    let sessionsCounted: Set<String>
    let lastLazyTickAt: Date
    let lastActiveAt: Date
}

@MainActor
@Observable
public final class CharacterEngine {

    public static let shared = CharacterEngine()

    // Publicly observable — SwiftUI views access these fields to trigger re-render.
    public private(set) var characterStats: CharacterStats

    /// Tracks last seen CLI source for collab +2 on source switch.
    private var lastActiveSource: String?
    /// Per-session CLI/session metadata used to make derived events traceable.
    private var sessionMetadataByID: [String: TrackedSessionMetadata] = [:]
    /// Tracks per-session focus threshold to fire the 10-minute bonus only once per session.
    private var sessionFocusThresholdFired: [String: Bool] = [:]
    /// Per-session start time for the current user prompt turn.
    private var promptStartTimes: [String: Date] = [:]
    /// Per-session timestamp of the last credited active prompt sample.
    private var promptLastSampleTimes: [String: Date] = [:]
    /// Tracks whether the active turn came from a real prompt hook or fallback activity.
    private var promptTurnOrigins: [String: PromptTurnOrigin] = [:]
    /// Per-session explicit prompt active seconds used for meal gates.
    private var sessionMealActiveSeconds: [String: Int] = [:]
    /// Per-session seconds credited from tool spacing, used only for focus rewards.
    private var sessionActiveSeconds: [String: Int] = [:]
    /// Per-session tool-spacing marker for the last focus streak reward.
    private var sessionLastFocusActiveSeconds: [String: Int] = [:]
    /// Per-session timestamp of the most recent tool event, used for focus rewards.
    private var lastToolEventTime: [String: Date] = [:]
    /// Sessions that have already contributed to totalSessions. Prevents double-count
    /// when both SessionStart and UserPromptSubmit (or first PostToolUse) arrive.
    private var sessionsCounted: Set<String> = []
    /// Last time tick() ran (guards lazy ticks).
    private var lastLazyTickAt: Date = .distantPast
    /// Last moment a tick saw `isAnySessionActive == true`. Idle energy recovery is
    /// gated on `now - lastActiveAt > idleEnergyRecoveryBufferSeconds`. Initialized
    /// to `characterStats.lastTickedAt` in init so offline rest still credits.
    private var lastActiveAt: Date = .distantPast

    private var tickTimer: Timer?
    private let persistence: CharacterPersistence?
    private let nowProvider: () -> Date
    private var runningSessionProvider: () -> Set<String> = { [] }

    private init() {
        self.persistence = CharacterPersistence.shared
        self.nowProvider = Date.init
        var loaded = CharacterPersistence.shared.load()
        // First launch: ensure lastTickedAt is set to now if zero
        if loaded.lastTickedAt == Date(timeIntervalSinceReferenceDate: 0) {
            loaded.lastTickedAt = nowProvider()
        }
        // Apply offline decay immediately
        characterStats = loaded
        // Use last tick as last-active proxy so offline rest still recovers energy.
        lastActiveAt = loaded.lastTickedAt
        tick(now: nowProvider())
        startTimer()
    }

    /// Factory for unit tests — starts with given stats, no timer, no persistence I/O.
    static func makeForTesting(stats: CharacterStats = CharacterStats(),
                               now: @escaping () -> Date = Date.init,
                               persistence: CharacterPersistence? = nil) -> CharacterEngine {
        let engine = CharacterEngine(testStats: stats, now: now, persistence: persistence)
        return engine
    }

    private init(testStats: CharacterStats, now: @escaping () -> Date, persistence: CharacterPersistence?) {
        self.persistence = persistence
        self.nowProvider = now
        characterStats = testStats
        // Mirror production init: last-active proxy from last tick.
        lastActiveAt = testStats.lastTickedAt
        // No timer, no persistence load — isolated for tests
    }

    // MARK: - Public API

    /// Current derived mood from vital stats.
    public var currentMood: MascotMood { characterStats.derivedMood }

    /// Trigger a lazy tick from a SwiftUI view (cheap when called frequently).
    /// Pass `isAnySessionActive` so the tick can skip idle energy recovery when a session is running.
    public func lazyTick(isAnySessionActive: Bool = false) {
        let now = Date()
        guard now.timeIntervalSince(lastLazyTickAt) >= lazyTickMinInterval else { return }
        tick(now: now, isAnySessionActive: isAnySessionActive)
    }

    /// Handle a hook event from AppState. Call AFTER existing AppState mutation
    /// so session snapshot reflects latest state.
    public func handle(event: HookEvent, sessionContext: CharacterSessionContext?) {
        guard !characterStats.settings.paused else { return }

        let eventName = normalize(event.eventName)
        let toolName = event.toolName ?? ""
        let sessionId = event.sessionId ?? "default"
        let now = nowProvider()
        let shouldRunSessionEndCleanup = eventName == "SessionEnd"
        let sessionMetadata = resolveSessionMetadata(
            sessionId: sessionId,
            event: event,
            sessionContext: sessionContext
        )
        var derived = baseDerivedContext(from: sessionContext)
        if let toolDescription = event.toolDescription {
            derived["toolDescription"] = .string(toolDescription)
        }
        if let toolInput = event.toolInput {
            derived["hasToolInput"] = .bool(!toolInput.isEmpty)
        }

        _ = runLoggedEvent(
            kind: .externalHook,
            name: eventName,
            sessionID: sessionId,
            source: sessionMetadata?.source,
            providerSessionID: sessionMetadata?.providerSessionID,
            cwd: sessionMetadata?.cwd,
            model: sessionMetadata?.model,
            permissionMode: sessionMetadata?.permissionMode,
            sessionTitle: sessionMetadata?.sessionTitle,
            remoteHostID: sessionMetadata?.remoteHostID,
            remoteHostName: sessionMetadata?.remoteHostName,
            toolName: event.toolName,
            toolUseID: event.toolUseId,
            agentID: event.agentId,
            occurredAt: now,
            payload: shouldStoreRawHookPayload(eventName: eventName)
                ? wrappedJSON(event.rawJSON)
                : compactedHookPayload(eventName: eventName, raw: event.rawJSON),
            derived: derived,
            recordWhenNoDeltas: true,
            reasonPrefix: normalizedReasonPrefix(for: eventName)
        ) { metadata in
            applyHookEventMutations(
                eventName: eventName,
                toolName: toolName,
                sessionId: sessionId,
                now: now,
                rawJSON: event.rawJSON,
                toolInput: event.toolInput,
                source: sessionContext?.source,
                toolSuccessRate: sessionContext?.toolSuccessRate ?? 0,
                totalTools: sessionContext?.totalTools ?? 0,
                metadata: &metadata
            )
        }

        if shouldRunSessionEndCleanup {
            endSession(sessionId: sessionId)
        }

        // Track last source for diagnostics — switching CLIs is a tool choice, not collaboration.
        if let source = sessionContext?.source, !source.isEmpty {
            lastActiveSource = source
        }

        characterStats.vital.clamp()
        let active = sessionContext.map { $0.hasActiveSession } ?? false
        tick(now: nowProvider(), isAnySessionActive: active)
    }

    internal func replay(event ledgerEvent: CharacterLedgerEvent) {
        let now = ledgerEvent.occurredAt
        replayRestoreSessionMetadata(from: ledgerEvent)

        switch ledgerEvent.eventKind {
        case .externalHook:
            replayExternalHook(ledgerEvent, now: now)
        case .derivedEffect:
            replayDerivedEffect(ledgerEvent, now: now)
        case .systemControl:
            replaySystemControl(ledgerEvent)
        }

        characterStats.vital.clamp()
    }

    private func applyHookEventMutations(
        eventName: String,
        toolName: String,
        sessionId: String,
        now: Date,
        rawJSON: [String: Any],
        toolInput: [String: Any]?,
        source: String?,
        toolSuccessRate: Double,
        totalTools: Int,
        metadata: inout EventMutationMetadata
    ) {
        switch eventName {
        case "SessionStart":
            countSessionIfFirst(sessionId: sessionId)

        case "UserPromptSubmit":
            countSessionIfFirst(sessionId: sessionId)
            applyVitalDelta(.mood, 2)
            characterStats.cyber.collab += 2
            startPromptTurn(sessionId: sessionId, now: now)

        case "PostToolUse":
            countSessionIfFirst(sessionId: sessionId)
            _ = ensurePromptTurnStarted(sessionId: sessionId, now: now)
            handlePostToolUse(
                toolName: toolName,
                sessionId: sessionId,
                source: source,
                now: now,
                toolInput: toolInput,
                rawJSON: rawJSON,
                metadata: &metadata
            )

        case "PostStop":
            countSessionIfFirst(sessionId: sessionId)
            handlePostStop(
                sessionId: sessionId,
                now: now,
                toolSuccessRate: toolSuccessRate,
                totalTools: totalTools,
                metadata: &metadata
            )

        case "SessionEnd":
            countSessionIfFirst(sessionId: sessionId)

        case "PermissionRequest":
            handlePermissionRequest(rawJSON: rawJSON, metadata: &metadata)

        case "Notification":
            handleNotification(rawJSON: rawJSON, metadata: &metadata)

        case "SubagentStart":
            countSessionIfFirst(sessionId: sessionId)
            characterStats.cyber.collab += 4
            // Subagent events share the parent session_id. Do NOT call
            // startPromptTurn here — it would overwrite the parent's
            // promptStartTimes and discard accumulated meal active seconds.
            // ensurePromptTurnStarted is a no-op when a turn is already running
            // (the normal case after UserPromptSubmit) and only seeds a
            // fallback turn when the CLI never emitted UserPromptSubmit.
            _ = ensurePromptTurnStarted(sessionId: sessionId, now: now)

        case "SubagentStop":
            countSessionIfFirst(sessionId: sessionId)
            // Force-credit the elapsed slice into the parent's prompt turn so
            // long subagent runs are reflected promptly, but DO NOT clear
            // tracking — the parent prompt turn is still alive and PostStop
            // will close it. Clearing here would zero out
            // sessionMealActiveSeconds and starve the meal reward.
            _ = creditPromptActiveTime(sessionId: sessionId, now: now, force: true)

        default:
            break
        }
    }

    private func applyTickMutation(now: Date, isAnySessionActive: Bool, metadata: inout EventMutationMetadata) {
        var dt = now.timeIntervalSince(characterStats.lastTickedAt) / 3600
        metadata.derived["rawHours"] = .double(dt)

        if dt < 0 {
            characterStats.lastTickedAt = now
            metadata.derived["clockWentBackward"] = .bool(true)
            return
        }

        dt = min(dt, maxDecayHours)
        metadata.derived["hours"] = .double(dt)
        guard !characterStats.settings.paused else {
            characterStats.lastTickedAt = now
            metadata.derived["paused"] = .bool(true)
            return
        }

        // ── Drivers: hunger and energy ──────────────────────────────────
        // Hunger decays unconditionally (active OR idle) — being idle doesn't
        // make you less hungry; only `meal` events at PostStop fill it.
        applyVitalDelta(.hunger, -dt * hungerDecayPerHour)

        // Energy decays only while a session is active. Idle is "rest", and
        // energy refills exponentially toward 100 during rest.
        if isAnySessionActive {
            lastActiveAt = now
            applyVitalDelta(.energy, -dt * energyDecayPerHourActive)
        } else {
            // Energy idle recovery — gated by the 60s task-switch buffer so
            // brief pauses don't count as rest.
            let bufferEnd = lastActiveAt.addingTimeInterval(idleRecoveryBufferSeconds)
            let recoveryStart = max(bufferEnd, characterStats.lastTickedAt)
            if now > recoveryStart {
                let dtMinutes = now.timeIntervalSince(recoveryStart) / 60
                applyIdleRecovery(.energy, ratePerMinute: idleEnergyRecoveryPerMinute,
                                  ceiling: idleEnergyCeiling, dtMinutes: dtMinutes,
                                  metadataPrefix: "idleEnergy", metadata: &metadata)
                // Mood self-soothes during rest — even if body state is bad,
                // sitting quietly nudges mood toward 70. Active path leaves
                // this off; mood there is governed by body-follow + events.
                applyIdleRecovery(.mood, ratePerMinute: idleMoodRecoveryPerMinute,
                                  ceiling: idleMoodCeiling, dtMinutes: dtMinutes,
                                  metadataPrefix: "idleMood", metadata: &metadata)
            } else {
                metadata.derived["idleRecoveryBuffered"] = .bool(true)
            }
        }

        // Order matters: mood follows the JUST-updated hunger/energy values,
        // then health observes the JUST-updated mood (its third input).
        applyMoodFollowsBody(elapsedHours: dt, metadata: &metadata)
        applyHealthFromBodyScore(elapsedHours: dt, metadata: &metadata)
        evaluateDailyRoll(now: now, metadata: &metadata)
        characterStats.lastTickedAt = now
    }

    private func applyPromptActiveSampleMutation(
        sessionId: String,
        now: Date,
        isRunning: Bool,
        metadata: inout EventMutationMetadata
    ) {
        let changed = creditPromptActiveTime(sessionId: sessionId, now: now, force: !isRunning)
        metadata.derived["force"] = .bool(!isRunning)
        metadata.derived["changed"] = .bool(changed)
        if !isRunning {
            clearPromptTurn(sessionId: sessionId)
            metadata.derived["closedPromptTurn"] = .bool(true)
        }
    }

    private func applySessionCleanupMutation(
        sessionId: String,
        now: Date,
        metadata: inout EventMutationMetadata
    ) {
        _ = creditPromptActiveTime(sessionId: sessionId, now: now, force: true)
        clearSessionTracking(sessionId: sessionId)
        metadata.derived["sessionEnded"] = .bool(true)
    }

    private func applyPauseChangedMutation(_ paused: Bool) {
        characterStats.settings.paused = paused
    }

    private func replayRestoreSessionMetadata(from ledgerEvent: CharacterLedgerEvent) {
        guard let sessionID = ledgerEvent.sessionID else { return }

        var metadata = sessionMetadataByID[sessionID] ?? TrackedSessionMetadata()
        if let source = ledgerEvent.source { metadata.source = source }
        if let providerSessionID = ledgerEvent.providerSessionID { metadata.providerSessionID = providerSessionID }
        if let cwd = ledgerEvent.cwd { metadata.cwd = cwd }
        if let model = ledgerEvent.model { metadata.model = model }
        if let permissionMode = ledgerEvent.permissionMode { metadata.permissionMode = permissionMode }
        if let sessionTitle = ledgerEvent.sessionTitle { metadata.sessionTitle = sessionTitle }
        if let remoteHostID = ledgerEvent.remoteHostID { metadata.remoteHostID = remoteHostID }
        if let remoteHostName = ledgerEvent.remoteHostName { metadata.remoteHostName = remoteHostName }

        guard metadata.hasMeaningfulValue else { return }
        sessionMetadataByID[sessionID] = metadata
    }

    private func replayExternalHook(_ ledgerEvent: CharacterLedgerEvent, now: Date) {
        let eventName = normalize(ledgerEvent.eventName)
        let sessionId = ledgerEvent.sessionID ?? "default"
        let rawJSON = ledgerPayloadToRawJSON(ledgerEvent.payload)
        let toolInput = toolInput(from: rawJSON)
        let derived = ledgerEvent.derived

        let toolSuccessRate = ledgerDouble(derived["toolSuccessRate"]) ?? 0
        let totalTools = ledgerInt(derived["totalTools"]) ?? 0
        let semanticOverride = toolSemantic(from: ledgerString(derived["semantic"]))
        let displayNameOverride = ledgerString(derived["displayName"])
        let focusDeltaOverride = ledgerInt(derived["focusDeltaSeconds"])

        var metadata = EventMutationMetadata(derived: derived)

        switch eventName {
        case "PostToolUse":
            countSessionIfFirst(sessionId: sessionId)
            _ = ensurePromptTurnStarted(sessionId: sessionId, now: now)
            handlePostToolUse(
                toolName: ledgerEvent.toolName ?? "",
                sessionId: sessionId,
                source: ledgerEvent.source,
                now: now,
                toolInput: toolInput,
                rawJSON: rawJSON,
                successOverride: ledgerBool(derived["success"]),
                semanticOverride: semanticOverride,
                displayNameOverride: displayNameOverride,
                focusDeltaOverride: focusDeltaOverride,
                metadata: &metadata
            )

        default:
            applyHookEventMutations(
                eventName: eventName,
                toolName: ledgerEvent.toolName ?? "",
                sessionId: sessionId,
                now: now,
                rawJSON: rawJSON,
                toolInput: toolInput,
                source: ledgerEvent.source,
                toolSuccessRate: toolSuccessRate,
                totalTools: totalTools,
                metadata: &metadata
            )
        }
    }

    private func replayDerivedEffect(_ ledgerEvent: CharacterLedgerEvent, now: Date) {
        switch normalize(ledgerEvent.eventName) {
        case "Tick":
            var metadata = EventMutationMetadata(derived: ledgerEvent.derived)
            if ledgerBool(ledgerEvent.derived["clockWentBackward"]) == true {
                characterStats.lastTickedAt = now
                return
            }
            let seededHours = ledgerDouble(ledgerEvent.derived["rawHours"])
                ?? ledgerDouble(ledgerEvent.derived["hours"])
                ?? 0
            characterStats.lastTickedAt = now.addingTimeInterval(-(seededHours * 3600))
            let isAnySessionActive = ledgerBool(ledgerEvent.payload["isAnySessionActive"]) ?? false
            applyTickMutation(now: now, isAnySessionActive: isAnySessionActive, metadata: &metadata)

        case "PromptActiveSample":
            guard let sessionId = ledgerEvent.sessionID else { return }
            let force = ledgerBool(ledgerEvent.derived["force"]) ?? false
            let shouldClose = ledgerBool(ledgerEvent.derived["closedPromptTurn"]) ?? false
            var metadata = EventMutationMetadata(derived: ledgerEvent.derived)
            applyPromptActiveSampleMutation(
                sessionId: sessionId,
                now: now,
                isRunning: !(force || shouldClose),
                metadata: &metadata
            )

        case "SessionCleanup":
            guard let sessionId = ledgerEvent.sessionID else { return }
            var metadata = EventMutationMetadata(derived: ledgerEvent.derived)
            applySessionCleanupMutation(sessionId: sessionId, now: now, metadata: &metadata)

        default:
            break
        }
    }

    private func replaySystemControl(_ ledgerEvent: CharacterLedgerEvent) {
        switch normalize(ledgerEvent.eventName) {
        case "PauseChanged":
            let paused = ledgerBool(ledgerEvent.payload["paused"]) ?? false
            applyPauseChangedMutation(paused)

        default:
            break
        }
    }

    /// Force-save immediately. Call from applicationWillTerminate / applicationDidResignActive.
    public func forceSave() {
        persistence?.saveNow(characterStats)
    }

    /// Returns (date, activeSeconds) for the last 7 calendar days, ascending.
    /// Always 7 entries: missing days are zero-filled so the chart can render
    /// a stable 7-column layout. Merges in-memory currentDayActiveSeconds for
    /// today if not yet flushed to the DB.
    public func last7DaysActive() -> [(date: Date, seconds: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: nowProvider())
        let stored = persistence?.last7DaysActive() ?? []
        var byDay: [String: Int] = [:]
        for row in stored {
            byDay[Self.dayFmt.string(from: row.date)] = row.seconds
        }

        // In-memory today overrides DB value (may not be flushed yet)
        let inMemoryToday = characterStats.stats.currentDayActiveSeconds
        if inMemoryToday > 0 {
            byDay[Self.dayFmt.string(from: today)] = inMemoryToday
        }

        var result: [(date: Date, seconds: Int)] = []
        for offset in (0...6).reversed() {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = Self.dayFmt.string(from: day)
            result.append((date: day, seconds: byDay[key] ?? 0))
        }
        return result
    }

    /// `true` if the once-per-day "restore all vitals to 100" button is
    /// available right now. Compares `lastFullRestoreDate` against today's
    /// natural-day string — resets at midnight local time.
    public var canFullRestoreToday: Bool {
        characterStats.stats.lastFullRestoreDate != LifetimeStats.todayString
    }

    /// Try to fully restore hunger/energy/mood/health to 100. No-op (returns
    /// `false`) if already used today. Logs a `FullRestore` event to the
    /// ledger with deltas so the change is auditable. Persists immediately.
    @discardableResult
    public func tryFullRestore() -> Bool {
        guard canFullRestoreToday else { return false }
        let now = nowProvider()
        let todayStr = LifetimeStats.todayString
        let eventName = "FullRestore"
        _ = runLoggedEvent(
            kind: .systemControl,
            name: eventName,
            sessionID: nil,
            source: nil,
            providerSessionID: nil,
            cwd: nil,
            model: nil,
            permissionMode: nil,
            sessionTitle: nil,
            remoteHostID: nil,
            remoteHostName: nil,
            toolName: nil,
            toolUseID: nil,
            agentID: nil,
            occurredAt: now,
            payload: ["date": .string(todayStr)],
            derived: [:],
            recordWhenNoDeltas: true,
            reasonPrefix: normalizedReasonPrefix(for: eventName)
        ) { _ in
            // Set vitals to 100 via direct assignment (bypassing applyVitalDelta
            // since we want a hard set, not a propagated delta). The diff vs
            // before-snapshot is captured by runLoggedEvent's surrounding
            // delta-recording, so the ledger still shows ±X per vital.
            characterStats.vital.hunger = 100
            characterStats.vital.energy = 100
            characterStats.vital.mood = 100
            characterStats.vital.health = 100
            characterStats.stats.lastFullRestoreDate = todayStr
        }
        return true
    }

    /// Set paused state and persist immediately.
    public func setPaused(_ paused: Bool) {
        let now = nowProvider()
        let payload: [String: AnyCodableLike] = [
            "paused": .bool(paused)
        ]
        let eventName = "PauseChanged"
        _ = runLoggedEvent(
            kind: .systemControl,
            name: eventName,
            sessionID: nil,
            source: nil,
            providerSessionID: nil,
            cwd: nil,
            model: nil,
            permissionMode: nil,
            sessionTitle: nil,
            remoteHostID: nil,
            remoteHostName: nil,
            toolName: nil,
            toolUseID: nil,
            agentID: nil,
            occurredAt: now,
            payload: payload,
            derived: [:],
            recordWhenNoDeltas: true,
            reasonPrefix: normalizedReasonPrefix(for: eventName)
        ) { _ in
            applyPauseChangedMutation(paused)
        }
    }

    public func listEvents(
        limit: Int = 100,
        beforeEventID: Int64? = nil,
        filter: CharacterEventQueryFilter = CharacterEventQueryFilter()
    ) -> [CharacterLedgerEvent] {
        persistence?.listEvents(limit: limit, beforeEventID: beforeEventID, filter: filter) ?? []
    }

    public func listEventDeltas(eventID: Int64) -> [CharacterLedgerDelta] {
        persistence?.listEventDeltas(eventID: eventID) ?? []
    }

    public func listSessions(
        limit: Int = 100,
        filter: CharacterSessionQueryFilter = CharacterSessionQueryFilter()
    ) -> [CharacterLedgerSession] {
        persistence?.listSessions(limit: limit, filter: filter) ?? []
    }

    @discardableResult
    public func rebuild() -> CharacterStats {
        clearAllTransientTracking()
        let rebuilt = persistence?.rebuild() ?? characterStats
        characterStats = rebuilt
        lastLazyTickAt = .distantPast
        return rebuilt
    }

    /// Supplies the current set of sessions that AppState can still prove are running.
    public func setRunningSessionProvider(_ provider: @escaping () -> Set<String>) {
        runningSessionProvider = provider
    }

    #if DEBUG
    internal func testInject_sessionMealSeconds(sessionId: String, seconds: Int) {
        sessionMealActiveSeconds[sessionId] = seconds
    }

    internal func testInject_sessionFocusActiveSeconds(sessionId: String, seconds: Int) {
        sessionActiveSeconds[sessionId] = seconds
    }
    #endif

    /// Finalizes any active prompt turn and clears all per-session tracking.
    public func endSession(sessionId: String) {
        guard !characterStats.settings.paused else {
            clearSessionTracking(sessionId: sessionId)
            return
        }
        let now = nowProvider()
        let eventName = "SessionCleanup"
        let sessionMetadata = trackedSessionMetadata(for: sessionId)
        _ = runLoggedEvent(
            kind: .derivedEffect,
            name: eventName,
            sessionID: sessionId,
            source: sessionMetadata?.source,
            providerSessionID: sessionMetadata?.providerSessionID,
            cwd: sessionMetadata?.cwd,
            model: sessionMetadata?.model,
            permissionMode: sessionMetadata?.permissionMode,
            sessionTitle: sessionMetadata?.sessionTitle,
            remoteHostID: sessionMetadata?.remoteHostID,
            remoteHostName: sessionMetadata?.remoteHostName,
            toolName: nil,
            toolUseID: nil,
            agentID: nil,
            occurredAt: now,
            payload: [:],
            derived: [:],
            recordWhenNoDeltas: false,
            reasonPrefix: normalizedReasonPrefix(for: eventName)
        ) { metadata in
            applySessionCleanupMutation(sessionId: sessionId, now: now, metadata: &metadata)
        }
    }

    /// Samples active prompt time. Running sessions are credited every 5 seconds; sessions
    /// no longer reported as running are credited once more and then closed.
    public func sampleActivePromptTime(runningSessionIds: Set<String>, now: Date = Date()) {
        guard !characterStats.settings.paused else { return }

        for sessionId in Array(promptStartTimes.keys) {
            let isRunning = runningSessionIds.contains(sessionId)
            let eventName = "PromptActiveSample"
            let sessionMetadata = trackedSessionMetadata(for: sessionId)
            let eventRecorded = runLoggedEvent(
                kind: .derivedEffect,
                name: eventName,
                sessionID: sessionId,
                source: sessionMetadata?.source,
                providerSessionID: sessionMetadata?.providerSessionID,
                cwd: sessionMetadata?.cwd,
                model: sessionMetadata?.model,
                permissionMode: sessionMetadata?.permissionMode,
                sessionTitle: sessionMetadata?.sessionTitle,
                remoteHostID: sessionMetadata?.remoteHostID,
                remoteHostName: sessionMetadata?.remoteHostName,
                toolName: nil,
                toolUseID: nil,
                agentID: nil,
                occurredAt: now,
                payload: [:],
                derived: [:],
                recordWhenNoDeltas: false,
                reasonPrefix: normalizedReasonPrefix(for: eventName)
            ) { metadata in
                applyPromptActiveSampleMutation(sessionId: sessionId, now: now, isRunning: isRunning, metadata: &metadata)
            }
            if !eventRecorded && !isRunning {
                clearPromptTurn(sessionId: sessionId)
            }
        }
    }

    /// Reset all character data back to defaults.
    public func reset() {
        stopTimer()
        clearAllTransientTracking()
        persistence?.resetAllCharacterData()
        characterStats = persistence?.load() ?? CharacterStats()
        startTimer()
    }

    // MARK: - Delta-coupled vital helpers

    /// Apply a delta to a single vital and propagate to the other three by weight.
    /// Single-pass: propagation does NOT recurse. Clamps all vitals at the end.
    /// For hunger/energy drivers, applies an asymmetric propagation multiplier
    /// (see `propagationMultiplier`) so a depleted body transmits damage harshly
    /// and absorbs recovery weakly, while a healthy body shrugs off damage and
    /// amplifies recovery.
    private func applyVitalDelta(_ key: VitalKey, _ delta: Double) {
        guard delta != 0 else { return }
        let driverBefore = currentValue(of: key)
        addVital(key, delta)
        let weights = vitalCouplingWeights[key] ?? [:]
        let propMultiplier: Double = {
            switch key {
            case .hunger, .energy:
                return propagationMultiplier(driverBefore: driverBefore, deltaSign: delta)
            case .mood, .health:
                return 1.0  // indicators don't propagate anyway, but keep symmetric
            }
        }()
        for (target, w) in weights {
            addVital(target, delta * w * propMultiplier)
        }
        characterStats.vital.clamp()
    }

    /// Generic exponential idle recovery toward a per-vital ceiling. Already
    /// at or above ceiling → no-op. Snaps to ceiling within ε so values
    /// actually terminate (exp asymptote alone never reaches the ceiling).
    /// Goes through `applyVitalDelta` so the standard coupling propagation
    /// still fires (driver-vital recoveries trickle into mood/health).
    private func applyIdleRecovery(
        _ key: VitalKey,
        ratePerMinute: Double,
        ceiling: Double,
        dtMinutes: Double,
        metadataPrefix: String,
        metadata: inout EventMutationMetadata
    ) {
        let current = currentValue(of: key)
        guard current < ceiling else { return }
        let decayFactor = exp(-ratePerMinute * dtMinutes)
        let proposed = ceiling - (ceiling - current) * decayFactor
        let target = (proposed >= ceiling - idleRecoverySnapThreshold) ? ceiling : proposed
        let delta = target - current
        guard delta > 0 else { return }
        metadata.derived["\(metadataPrefix)RecoveryDelta"] = .double(delta)
        if target == ceiling {
            metadata.derived["\(metadataPrefix)RecoverySnappedCeiling"] = .bool(true)
        }
        applyVitalDelta(key, delta)
    }

    private func currentValue(of key: VitalKey) -> Double {
        switch key {
        case .hunger: return characterStats.vital.hunger
        case .mood:   return characterStats.vital.mood
        case .energy: return characterStats.vital.energy
        case .health: return characterStats.vital.health
        }
    }

    private func addVital(_ key: VitalKey, _ amount: Double) {
        switch key {
        case .hunger: characterStats.vital.hunger += amount
        case .mood:   characterStats.vital.mood   += amount
        case .energy: characterStats.vital.energy += amount
        case .health: characterStats.vital.health += amount
        }
    }

    // MARK: - Tick (decay + daily roll)

    public func tick(now: Date, isAnySessionActive: Bool = false) {
        lastLazyTickAt = now

        _ = runLoggedEvent(
            kind: .derivedEffect,
            name: "Tick",
            sessionID: nil,
            source: nil,
            providerSessionID: nil,
            cwd: nil,
            model: nil,
            permissionMode: nil,
            sessionTitle: nil,
            remoteHostID: nil,
            remoteHostName: nil,
            toolName: nil,
            toolUseID: nil,
            agentID: nil,
            occurredAt: now,
            payload: [
                "isAnySessionActive": .bool(isAnySessionActive)
            ],
            derived: [:],
            recordWhenNoDeltas: false,
            reasonPrefix: "tick"
        ) { metadata in
            applyTickMutation(now: now, isAnySessionActive: isAnySessionActive, metadata: &metadata)
        }
    }

    // MARK: - Private handlers

    private func handlePostToolUse(
        toolName: String,
        sessionId: String,
        source: String?,
        now: Date,
        toolInput: [String: Any]?,
        rawJSON: [String: Any],
        successOverride: Bool? = nil,
        semanticOverride: ToolSemantic? = nil,
        displayNameOverride: String? = nil,
        focusDeltaOverride: Int? = nil,
        metadata: inout EventMutationMetadata
    ) {
        let success = successOverride ?? isSuccess(rawJSON: rawJSON)
        let classification = ToolSemanticMapper.classify(
            source: source,
            rawToolName: toolName,
            toolInput: toolInput
        )
        let semantic = semanticOverride ?? classification.semantic
        let displayName = displayNameOverride ?? classification.displayName
        metadata.derived["success"] = .bool(success)
        metadata.derived["semantic"] = .string(semantic.rawValue)
        metadata.derived["displayName"] = .string(displayName)

        characterStats.stats.totalToolCalls += 1
        characterStats.stats.toolUseCount[displayName, default: 0] += 1
        if let source, !source.isEmpty {
            characterStats.stats.cliUseCount[source, default: 0] += 1
        }

        // Inter-tool spacing for focus ladder (unchanged).
        let delta: Int = {
            if let focusDeltaOverride { return focusDeltaOverride }
            if let last = lastToolEventTime[sessionId] {
                return min(120, max(0, Int(now.timeIntervalSince(last))))
            }
            return 30
        }()
        metadata.derived["focusDeltaSeconds"] = .int(Int64(delta))
        if delta > 0 {
            sessionActiveSeconds[sessionId, default: 0] += delta
        }
        lastToolEventTime[sessionId] = now

        if success {
            // Per-tool energy cost: kept (signal: tools-have-a-cost) but
            // halved from -0.2 → -0.1 so a 50-tool parallel-agent batch
            // costs ~-5 instead of ~-10. Time-based baseline decay
            // (`energyDecayPerHourActive`) handles the steady drain.
            applyVitalDelta(.energy, -energyCostPerToolSuccess)

            // Cyber attribution — exactly one dimension per successful event, by semantic.
            switch semantic {
            case .write:
                characterStats.cyber.diligence += 2
            case .read, .search, .network:
                characterStats.cyber.curiosity += 1.5
            case .execute:
                characterStats.cyber.diligence += 1
            case .manage, .unknown:
                break
            }

            let focusGranted = handleFocusProgress(sessionId: sessionId)
            metadata.derived["focusGranted"] = .double(focusGranted)
        } else {
            applyVitalDelta(.mood, -2)
        }
    }

    private func handlePostStop(
        sessionId: String,
        now: Date,
        toolSuccessRate: Double,
        totalTools: Int,
        metadata: inout EventMutationMetadata
    ) {
        // Mood +3 unconditionally (the small "session-done satisfaction")
        applyVitalDelta(.mood, 3)
        _ = creditPromptActiveTime(sessionId: sessionId, now: now, force: true)

        // Hunger meal — gated by BOTH explicit prompt active time AND tool count. Pure-time gate
        // would let "open session, sit idle, close" loop refill hunger for free.
        // Read active seconds BEFORE cleanup at the bottom of this method.
        let activeSeconds = sessionMealActiveSeconds[sessionId] ?? 0
        let meal = mealRewardBands.first {
            activeSeconds >= $0.seconds && totalTools >= $0.tools
        }?.reward ?? 0
        metadata.derived["activeSeconds"] = .int(Int64(activeSeconds))
        metadata.derived["totalTools"] = .int(Int64(totalTools))
        metadata.derived["mealReward"] = .double(meal)
        if meal > 0 {
            applyVitalDelta(.hunger, meal)
            // Eating restores energy too (humans eat for fuel, not just satiety).
            // 1x ratio: meal reward directly maps to energy recovery.
            applyVitalDelta(.energy, meal)
        }

        // Taste: linear from 90%→+5 to 100%→+10 (requires ≥5 tools).
        if toolSuccessRate >= 0.90 && totalTools >= 5 {
            let scaled = 5.0 + (toolSuccessRate - 0.90) * 50.0  // 0.90 → 5, 1.00 → 10
            characterStats.cyber.taste += scaled
            metadata.derived["tasteReward"] = .double(scaled)
        }

        // Cleanup session tracking
        clearSessionTracking(sessionId: sessionId)
    }

    private func handlePermissionRequest(rawJSON: [String: Any], metadata: inout EventMutationMetadata) {
        // Decision field varies by CLI:
        //   Claude Code:  rawJSON["decision"] in {"allow", "deny", "ask"}
        //   Codex:        rawJSON["decision"] OR rawJSON["permission_decision"]
        //   Traecli:      rawJSON["decision"]
        let decision = (rawJSON["decision"] as? String)
            ?? (rawJSON["permission_decision"] as? String)
            ?? ""
        metadata.derived["decision"] = .string(decision)
        switch decision.lowercased() {
        case "allow", "approved":
            characterStats.cyber.collab += 1
        case "deny", "denied", "rejected":
            applyVitalDelta(.mood, -3)
        default:
            break  // "ask" or unknown — no scoring effect
        }
    }

    private func handleNotification(rawJSON: [String: Any], metadata: inout EventMutationMetadata) {
        // Permission handling moved to handlePermissionRequest (case "PermissionRequest").
        // Notification is retained for other notification types (e.g., Cursor afterAgentThought).
        metadata.derived["ignored"] = .bool(true)
    }

    @discardableResult
    private func grantFocus(_ amount: Double) -> Double {
        characterStats.cyber.focus += amount
        return amount
    }

    private func handleFocusProgress(sessionId: String) -> Double {
        guard let activeSeconds = sessionActiveSeconds[sessionId] else { return 0 }
        var granted = 0.0

        // Focus is based on credited tool activity, not SessionStart. This keeps
        // CLIs that omit lifecycle hooks from being permanently stuck at zero.
        if activeSeconds >= 600 && sessionFocusThresholdFired[sessionId] != true {
            sessionFocusThresholdFired[sessionId] = true
            granted += grantFocus(4)
        }

        let lastRewardAt = sessionLastFocusActiveSeconds[sessionId] ?? 0
        let currentRewardAt = (activeSeconds / 300) * 300
        if currentRewardAt > lastRewardAt {
            let rewardCount = (currentRewardAt - lastRewardAt) / 300
            granted += grantFocus(Double(rewardCount * 2))
            sessionLastFocusActiveSeconds[sessionId] = currentRewardAt
        }
        return granted
    }

    private func evaluateDailyRoll(now: Date, metadata: inout EventMutationMetadata) {
        let calendar = Calendar.current
        let lastDay = calendar.startOfDay(for: characterStats.lastTickedAt)
        let today = calendar.startOfDay(for: now)
        guard today > lastDay else { return }

        // Roll yesterday's daily active seconds
        let seconds = characterStats.stats.currentDayActiveSeconds
        let healthyBandLow = 3600        // 1h
        let healthyBandHigh = 28800      // 8h
        let overworkThreshold = 28800    // 8h
        let overworkStreakNeeded = 3     // 3 consecutive overwork days
        metadata.derived["rolledDaySeconds"] = .int(Int64(seconds))

        if seconds >= healthyBandLow && seconds <= healthyBandHigh {
            applyVitalDelta(.health, 3)
            metadata.derived["healthyDay"] = .bool(true)
        }

        if seconds > overworkThreshold {
            characterStats.stats.overworkStreakDays += 1
            if characterStats.stats.overworkStreakDays >= overworkStreakNeeded {
                applyVitalDelta(.health, -3)
                metadata.derived["overworkPenaltyApplied"] = .bool(true)
            }
        } else {
            characterStats.stats.overworkStreakDays = 0
        }
        // Rest days (seconds < healthyBandLow) are deliberately neutral — humans need recovery.

        // Flush yesterday's active seconds to the daily_active table
        let yesterdayStr = Self.dayFmt.string(from: lastDay)
        metadata.dailyActiveWrites[yesterdayStr] = seconds
        metadata.derived["flushedDate"] = .string(yesterdayStr)

        // Streak: continuous active days. Yesterday must have been active (seconds > 0)
        // AND lastActiveDate must be the day-before-yesterday for the streak to extend.
        let todayStr = Self.dayFmt.string(from: now)
        if seconds > 0 {
            if characterStats.stats.lastActiveDate == yesterdayStr {
                characterStats.stats.streakDays += 1
            } else {
                characterStats.stats.streakDays = 1
            }
            characterStats.stats.lastActiveDate = todayStr
        } else {
            characterStats.stats.streakDays = 0
        }

        // Reset today counter
        characterStats.stats.currentDayActiveSeconds = 0
        characterStats.stats.currentDayDate = todayStr
    }

    /// Mood follows the body — pulls toward `(hunger + energy) / 2` at
    /// τ=1h. Fast-twitch indicator: 1h closes ~63% of the gap, 3h ~95%.
    /// Event rewards (UserPromptSubmit +2, PostStop +3) can push mood above
    /// the body target, but only by `moodOvershootCap`; sustained spikes
    /// get yanked back as soon as the body underwrites them.
    private func applyMoodFollowsBody(elapsedHours: Double, metadata: inout EventMutationMetadata) {
        guard elapsedHours > 0 else { return }

        let targetMood =
            characterStats.vital.hunger * moodFollowsBodyWeights.hunger +
            characterStats.vital.energy * moodFollowsBodyWeights.energy

        // Single-sided overshoot clamp: events can spike mood above target,
        // but only by `moodOvershootCap`. No symmetric floor — feeling worse
        // than the body warrants is allowed and self-corrects via events.
        let upperCap = min(100.0, targetMood + moodOvershootCap)
        if characterStats.vital.mood > upperCap {
            let yank = characterStats.vital.mood - upperCap
            metadata.derived["moodOvershootCapApplied"] = .double(yank)
            characterStats.vital.mood = upperCap
        }

        let rate = 1 - exp(-moodEquilibriumRatePerHour * elapsedHours)
        var moodDelta = (targetMood - characterStats.vital.mood) * rate

        // Snap-to-target: exp asymptote — within ε, land exactly on target.
        let proposedGap = targetMood - (characterStats.vital.mood + moodDelta)
        var snapped = false
        if abs(proposedGap) <= moodEquilibriumSnapThreshold {
            moodDelta = targetMood - characterStats.vital.mood
            snapped = true
        }

        metadata.derived["moodFollowTarget"] = .double(targetMood)
        metadata.derived["moodFollowRate"] = .double(rate)
        metadata.derived["moodFollowDelta"] = .double(moodDelta)
        if snapped {
            metadata.derived["moodFollowSnapped"] = .bool(true)
        }

        guard abs(moodDelta) > 0.000_000_1 else { return }
        characterStats.vital.mood += moodDelta
    }

    private func weightedGeometricVitalMean(hunger hungerWeight: Double,
                                            energy energyWeight: Double,
                                            health healthWeight: Double) -> Double {
        let hunger = max(min(characterStats.vital.hunger / 100, 1), minLoggedVitalFraction)
        let energy = max(min(characterStats.vital.energy / 100, 1), minLoggedVitalFraction)
        let health = max(min(characterStats.vital.health / 100, 1), minLoggedVitalFraction)

        let weightedLogSum =
            Foundation.log(hunger) * hungerWeight
            + Foundation.log(energy) * energyWeight
            + Foundation.log(health) * healthWeight

        return exp(weightedLogSum) * 100
    }

    /// Health from the body-score threshold integrator. Each tick:
    ///   body_score = (hunger + energy + mood) / 3
    ///   body_score < 30 → health -= 0.3 × elapsedHours  (long-arc burnout)
    ///   body_score > 70 → health += 0.2 × elapsedHours  (long-arc upkeep)
    ///   30 ≤ score ≤ 70 → no change                     (transient zone)
    /// Asymmetric: easier to lose than to gain (a bad streak burns the
    /// reserve faster than a good one rebuilds it). Healthy-day +3 / overwork
    /// -3 still fire on day boundaries via `evaluateDailyRoll` for clear
    /// long-period signals; this function is the continuous component.
    private func applyHealthFromBodyScore(elapsedHours: Double, metadata: inout EventMutationMetadata) {
        guard elapsedHours > 0 else { return }
        let bodyScore = (characterStats.vital.hunger
                       + characterStats.vital.energy
                       + characterStats.vital.mood) / 3.0
        metadata.derived["bodyScore"] = .double(bodyScore)

        let delta: Double
        if bodyScore < bodyScoreLowThreshold {
            delta = -healthDecayPerHourLowBody * elapsedHours
        } else if bodyScore > bodyScoreHighThreshold {
            delta = healthRecoveryPerHourHighBody * elapsedHours
        } else {
            return
        }
        metadata.derived["healthBodyScoreDelta"] = .double(delta)
        applyVitalDelta(.health, delta)
    }

    private func startPromptTurn(sessionId: String, now: Date) {
        creditPromptActiveTime(sessionId: sessionId, now: now, force: true)
        promptStartTimes[sessionId] = now
        promptLastSampleTimes[sessionId] = now
        promptTurnOrigins[sessionId] = .explicitPrompt
    }

    @discardableResult
    private func ensurePromptTurnStarted(sessionId: String, now: Date) -> Bool {
        guard promptStartTimes[sessionId] == nil else { return false }
        promptStartTimes[sessionId] = now
        promptLastSampleTimes[sessionId] = now
        promptTurnOrigins[sessionId] = .activityFallback
        // Fallback path: CLI never emitted UserPromptSubmit (Gemini-class). Grant the
        // same mood/collab bonus once so these users aren't permanently penalised.
        applyVitalDelta(.mood, 2)
        characterStats.cyber.collab += 2
        return true
    }

    @discardableResult
    private func endFallbackPromptTurnIfNeeded(sessionId: String, now: Date) -> Bool {
        guard promptTurnOrigins[sessionId] == .activityFallback else { return false }
        creditPromptActiveTime(sessionId: sessionId, now: now, force: true)
        clearPromptTurn(sessionId: sessionId)
        return true
    }

    @discardableResult
    private func creditPromptActiveTime(sessionId: String, now: Date, force: Bool) -> Bool {
        guard let startedAt = promptStartTimes[sessionId] else { return false }
        let lastSample = promptLastSampleTimes[sessionId] ?? startedAt

        let elapsed = now.timeIntervalSince(lastSample)
        if elapsed < 0 {
            promptLastSampleTimes[sessionId] = now
            return false
        }
        guard force || elapsed >= activePromptSampleInterval else { return false }

        let seconds = Int(elapsed)
        guard seconds > 0 else { return false }

        updateDailyActiveSeconds(now: now, addSeconds: seconds)
        if promptTurnOrigins[sessionId] == .explicitPrompt {
            sessionMealActiveSeconds[sessionId, default: 0] += seconds
        }
        promptLastSampleTimes[sessionId] = lastSample.addingTimeInterval(TimeInterval(seconds))
        return true
    }

    private func clearPromptTurn(sessionId: String) {
        promptStartTimes.removeValue(forKey: sessionId)
        promptLastSampleTimes.removeValue(forKey: sessionId)
        promptTurnOrigins.removeValue(forKey: sessionId)
    }

    private func countSessionIfFirst(sessionId: String) {
        guard !sessionsCounted.contains(sessionId) else { return }
        sessionsCounted.insert(sessionId)
        characterStats.stats.totalSessions += 1
    }

    private func clearSessionTracking(sessionId: String) {
        sessionMetadataByID.removeValue(forKey: sessionId)
        sessionFocusThresholdFired.removeValue(forKey: sessionId)
        clearPromptTurn(sessionId: sessionId)
        sessionMealActiveSeconds.removeValue(forKey: sessionId)
        sessionActiveSeconds.removeValue(forKey: sessionId)
        sessionLastFocusActiveSeconds.removeValue(forKey: sessionId)
        lastToolEventTime.removeValue(forKey: sessionId)
        sessionsCounted.remove(sessionId)
    }

    private func updateDailyActiveSeconds(now: Date, addSeconds: Int) {
        let todayStr = Self.dayFmt.string(from: now)
        if characterStats.stats.currentDayDate != todayStr {
            characterStats.stats.currentDayDate = todayStr
            characterStats.stats.currentDayActiveSeconds = 0
        }
        characterStats.stats.currentDayActiveSeconds += addSeconds
        characterStats.stats.totalActiveSeconds += addSeconds
    }

    private func trackedSessionMetadata(for sessionId: String?) -> TrackedSessionMetadata? {
        guard let sessionId else { return nil }
        return sessionMetadataByID[sessionId]
    }

    private func resolveSessionMetadata(
        sessionId: String?,
        event: HookEvent,
        sessionContext: CharacterSessionContext?
    ) -> TrackedSessionMetadata? {
        guard let sessionId else { return nil }
        var metadata = sessionMetadataByID[sessionId] ?? TrackedSessionMetadata()

        if let source = sessionContext?.source
            ?? SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String) {
            metadata.source = source
        }
        if let providerSessionID = firstNonEmptyString(event.rawJSON, keys: ["session_id", "sessionId"]) {
            metadata.providerSessionID = providerSessionID
        }
        if let cwd = firstNonEmptyString(event.rawJSON, keys: ["cwd"]) {
            metadata.cwd = cwd
        } else if metadata.cwd == nil,
                  let roots = event.rawJSON["workspace_roots"] as? [String],
                  let first = roots.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !first.isEmpty {
            metadata.cwd = first
        }
        if let model = firstNonEmptyString(event.rawJSON, keys: ["model"]) {
            metadata.model = model
        }
        if let permissionMode = firstNonEmptyString(event.rawJSON, keys: ["permission_mode"]) {
            metadata.permissionMode = permissionMode
        }
        if let sessionTitle = firstNonEmptyString(event.rawJSON, keys: ["session_title"]) {
            metadata.sessionTitle = sessionTitle
        }
        if let remoteHostID = firstNonEmptyString(event.rawJSON, keys: ["_remote_host_id"]) {
            metadata.remoteHostID = remoteHostID
        }
        if let remoteHostName = firstNonEmptyString(event.rawJSON, keys: ["_remote_host_name"]) {
            metadata.remoteHostName = remoteHostName
        }

        guard metadata.hasMeaningfulValue else { return nil }
        sessionMetadataByID[sessionId] = metadata
        return metadata
    }

    private func baseDerivedContext(from sessionContext: CharacterSessionContext?) -> [String: AnyCodableLike] {
        guard let sessionContext else { return [:] }
        var derived: [String: AnyCodableLike] = [
            "toolSuccessRate": .double(sessionContext.toolSuccessRate),
            "totalTools": .int(Int64(sessionContext.totalTools)),
            "activeSessionCount": .int(Int64(sessionContext.activeSessionCount)),
            "hasActiveSession": .bool(sessionContext.hasActiveSession),
        ]
        if let source = sessionContext.source, !source.isEmpty {
            derived["source"] = .string(source)
        }
        return derived
    }

    private func wrappedJSON(_ rawJSON: [String: Any]) -> [String: AnyCodableLike] {
        var wrapped: [String: AnyCodableLike] = [:]
        for (key, value) in rawJSON {
            wrapped[key] = AnyCodableLike.from(value)
        }
        return wrapped
    }

    /// Returns true if a hook event should write its FULL raw JSON to
    /// payload_json. When false, callers should substitute `compactedHookPayload`.
    /// Currently only PreToolUse / PostToolUse are gated — those carry tool
    /// input/output bodies that can be tens of KB each.
    private func shouldStoreRawHookPayload(eventName: String) -> Bool {
        if characterStats.settings.logRawHookPayloads { return true }
        switch eventName {
        case "PreToolUse", "PostToolUse", "PostToolUseFailure":
            return false
        default:
            return true
        }
    }

    /// Returns true if a high-volume derived-effect row should be persisted.
    /// Stat mutations still apply regardless; this only gates audit-log writes.
    private func shouldPersistEventRow(kind: CharacterEventKind, name: String) -> Bool {
        guard kind == .derivedEffect else { return true }
        switch name {
        case "Tick":
            return characterStats.settings.logTickEvents
        default:
            return true
        }
    }

    /// Reduces a hook payload to a small audit summary (success / sizes / a
    /// handful of structural keys) instead of the full input/output bodies.
    /// Drops the lion's share of disk usage on tool-heavy users — empirically
    /// avg PostToolUse payload of ~7 KB collapses to ~200 B.
    private func compactedHookPayload(eventName: String, raw: [String: Any]) -> [String: AnyCodableLike] {
        var out: [String: AnyCodableLike] = [:]
        out["compact"] = .bool(true)

        if let toolName = raw["tool_name"] as? String {
            out["tool_name"] = .string(toolName)
        }
        if let exitCode = raw["exit_code"] as? Int {
            out["exitCode"] = .int(Int64(exitCode))
        }
        if let success = raw["success"] as? Bool {
            out["success"] = .bool(success)
        }

        if let toolInput = raw["tool_input"] {
            out["toolInputBytes"] = .int(Int64(approxJSONByteCount(toolInput)))
            if let dict = toolInput as? [String: Any] {
                let keys = dict.keys.sorted().prefix(20).map { AnyCodableLike.string($0) }
                out["toolInputKeys"] = .array(Array(keys))
            }
        }
        if let toolResponse = raw["tool_response"] {
            out["toolResponseBytes"] = .int(Int64(approxJSONByteCount(toolResponse)))
            if let dict = toolResponse as? [String: Any] {
                if let isError = dict["is_error"] as? Bool {
                    out["isError"] = .bool(isError)
                }
                if let exit = dict["exit_code"] as? Int {
                    out["responseExitCode"] = .int(Int64(exit))
                }
            }
        }
        return out
    }

    private func approxJSONByteCount(_ value: Any) -> Int {
        let serializable: Any = (value is [String: Any] || value is [Any]) ? value : [value]
        return (try? JSONSerialization.data(withJSONObject: serializable, options: [])).map { $0.count } ?? 0
    }

    private func firstNonEmptyString(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private func normalizedReasonPrefix(for eventName: String) -> String {
        var output = ""
        for scalar in eventName.unicodeScalars {
            if CharacterSet.uppercaseLetters.contains(scalar), !output.isEmpty {
                output.append("_")
            }
            if CharacterSet.alphanumerics.contains(scalar) {
                output.append(String(scalar).lowercased())
            } else {
                output.append("_")
            }
        }
        while output.contains("__") {
            output = output.replacingOccurrences(of: "__", with: "_")
        }
        return output.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    @discardableResult
    private func runLoggedEvent(
        kind: CharacterEventKind,
        name: String,
        sessionID: String?,
        source: String?,
        providerSessionID: String?,
        cwd: String?,
        model: String?,
        permissionMode: String?,
        sessionTitle: String?,
        remoteHostID: String?,
        remoteHostName: String?,
        toolName: String?,
        toolUseID: String?,
        agentID: String?,
        occurredAt: Date,
        payload: [String: AnyCodableLike],
        derived: [String: AnyCodableLike],
        recordWhenNoDeltas: Bool,
        reasonPrefix: String,
        body: (inout EventMutationMetadata) -> Void
    ) -> Bool {
        let statsBefore = characterStats
        let transientBefore = captureTransientState()
        var metadata = EventMutationMetadata(derived: derived)
        body(&metadata)
        characterStats.vital.clamp()

        // Settings-gated row suppression: stat mutations still apply, but the
        // event row + its deltas are NOT persisted. Used to keep the ledger
        // small for high-frequency derived-effect events (Tick, sampling).
        // The character_state snapshot is still flushed so decay/recovery
        // results survive a restart.
        if !shouldPersistEventRow(kind: kind, name: name) {
            persistence?.saveNow(characterStats, dailyActiveWrites: metadata.dailyActiveWrites)
            return false
        }

        let deltas = makeEventDeltas(
            before: statsBefore,
            after: characterStats,
            dailyActiveWrites: metadata.dailyActiveWrites,
            reasonPrefix: reasonPrefix
        )

        guard recordWhenNoDeltas || !deltas.isEmpty else { return false }
        guard let persistence else { return true }

        let draft = CharacterLedgerEventDraft(
            batchID: UUID().uuidString,
            occurredAt: occurredAt,
            eventKind: kind,
            eventName: name,
            sessionID: sessionID,
            source: source,
            providerSessionID: providerSessionID,
            cwd: cwd,
            model: model,
            permissionMode: permissionMode,
            sessionTitle: sessionTitle,
            remoteHostID: remoteHostID,
            remoteHostName: remoteHostName,
            toolName: toolName,
            toolUseID: toolUseID,
            agentID: agentID,
            ruleVersion: characterRuleVersion,
            payload: payload,
            derived: metadata.derived
        )

        guard persistence.append(event: draft, deltas: deltas, snapshot: characterStats) != nil else {
            characterStats = statsBefore
            restoreTransientState(transientBefore)
            return false
        }

        return true
    }

    private func makeEventDeltas(
        before: CharacterStats,
        after: CharacterStats,
        dailyActiveWrites: [String: Int],
        reasonPrefix: String
    ) -> [CharacterLedgerDeltaDraft] {
        var deltas: [CharacterLedgerDeltaDraft] = []

        appendDoubleDelta(&deltas, domain: .meta, name: "lastTickedAt",
                          before: before.lastTickedAt.timeIntervalSince1970,
                          after: after.lastTickedAt.timeIntervalSince1970,
                          reasonPrefix: reasonPrefix)

        appendDoubleDelta(&deltas, domain: .vital, name: "hunger",
                          before: before.vital.hunger, after: after.vital.hunger, reasonPrefix: reasonPrefix)
        appendDoubleDelta(&deltas, domain: .vital, name: "mood",
                          before: before.vital.mood, after: after.vital.mood, reasonPrefix: reasonPrefix)
        appendDoubleDelta(&deltas, domain: .vital, name: "energy",
                          before: before.vital.energy, after: after.vital.energy, reasonPrefix: reasonPrefix)
        appendDoubleDelta(&deltas, domain: .vital, name: "health",
                          before: before.vital.health, after: after.vital.health, reasonPrefix: reasonPrefix)

        appendDoubleDelta(&deltas, domain: .cyber, name: "focus",
                          before: before.cyber.focus, after: after.cyber.focus, reasonPrefix: reasonPrefix)
        appendDoubleDelta(&deltas, domain: .cyber, name: "diligence",
                          before: before.cyber.diligence, after: after.cyber.diligence, reasonPrefix: reasonPrefix)
        appendDoubleDelta(&deltas, domain: .cyber, name: "collab",
                          before: before.cyber.collab, after: after.cyber.collab, reasonPrefix: reasonPrefix)
        appendDoubleDelta(&deltas, domain: .cyber, name: "taste",
                          before: before.cyber.taste, after: after.cyber.taste, reasonPrefix: reasonPrefix)
        appendDoubleDelta(&deltas, domain: .cyber, name: "curiosity",
                          before: before.cyber.curiosity, after: after.cyber.curiosity, reasonPrefix: reasonPrefix)

        appendIntDelta(&deltas, domain: .lifetime, name: "totalSessions",
                       before: before.stats.totalSessions, after: after.stats.totalSessions, reasonPrefix: reasonPrefix)
        appendIntDelta(&deltas, domain: .lifetime, name: "totalToolCalls",
                       before: before.stats.totalToolCalls, after: after.stats.totalToolCalls, reasonPrefix: reasonPrefix)
        appendIntDelta(&deltas, domain: .lifetime, name: "totalActiveSeconds",
                       before: before.stats.totalActiveSeconds, after: after.stats.totalActiveSeconds, reasonPrefix: reasonPrefix)
        appendIntDelta(&deltas, domain: .lifetime, name: "currentDayActiveSeconds",
                       before: before.stats.currentDayActiveSeconds, after: after.stats.currentDayActiveSeconds, reasonPrefix: reasonPrefix)
        appendStringDelta(&deltas, domain: .lifetime, name: "currentDayDate",
                          before: before.stats.currentDayDate, after: after.stats.currentDayDate, reasonPrefix: reasonPrefix)
        appendIntDelta(&deltas, domain: .lifetime, name: "streakDays",
                       before: before.stats.streakDays, after: after.stats.streakDays, reasonPrefix: reasonPrefix)
        appendStringDelta(&deltas, domain: .lifetime, name: "lastActiveDate",
                          before: before.stats.lastActiveDate, after: after.stats.lastActiveDate, reasonPrefix: reasonPrefix)
        appendIntDelta(&deltas, domain: .lifetime, name: "overworkStreakDays",
                       before: before.stats.overworkStreakDays, after: after.stats.overworkStreakDays, reasonPrefix: reasonPrefix)

        appendBoolDelta(&deltas, domain: .settings, name: "paused",
                        before: before.settings.paused, after: after.settings.paused, reasonPrefix: reasonPrefix)

        appendMapDeltas(
            &deltas,
            domain: .toolUse,
            before: before.stats.toolUseCount,
            after: after.stats.toolUseCount,
            reasonPrefix: reasonPrefix
        )
        appendMapDeltas(
            &deltas,
            domain: .cliUse,
            before: before.stats.cliUseCount,
            after: after.stats.cliUseCount,
            reasonPrefix: reasonPrefix
        )

        for (date, secondsAfter) in dailyActiveWrites {
            let secondsBefore = persistence?.currentDailyActiveSeconds(for: date) ?? 0
            appendIntDelta(
                &deltas,
                domain: .dailyActive,
                name: date,
                before: secondsBefore,
                after: secondsAfter,
                reasonPrefix: reasonPrefix
            )
        }

        return deltas
    }

    private func appendDoubleDelta(
        _ deltas: inout [CharacterLedgerDeltaDraft],
        domain: CharacterMetricDomain,
        name: String,
        before: Double,
        after: Double,
        reasonPrefix: String
    ) {
        guard abs(before - after) > 0.000_000_1 else { return }
        deltas.append(CharacterLedgerDeltaDraft(
            metricDomain: domain,
            metricName: name,
            reasonCode: "\(reasonPrefix).\(domain.rawValue).\(name)",
            valueBefore: .double(before),
            valueAfter: .double(after),
            numericDelta: after - before
        ))
    }

    private func appendIntDelta(
        _ deltas: inout [CharacterLedgerDeltaDraft],
        domain: CharacterMetricDomain,
        name: String,
        before: Int,
        after: Int,
        reasonPrefix: String
    ) {
        guard before != after else { return }
        deltas.append(CharacterLedgerDeltaDraft(
            metricDomain: domain,
            metricName: name,
            reasonCode: "\(reasonPrefix).\(domain.rawValue).\(name)",
            valueBefore: .int(before),
            valueAfter: .int(after),
            numericDelta: Double(after - before)
        ))
    }

    private func appendStringDelta(
        _ deltas: inout [CharacterLedgerDeltaDraft],
        domain: CharacterMetricDomain,
        name: String,
        before: String,
        after: String,
        reasonPrefix: String
    ) {
        guard before != after else { return }
        deltas.append(CharacterLedgerDeltaDraft(
            metricDomain: domain,
            metricName: name,
            reasonCode: "\(reasonPrefix).\(domain.rawValue).\(name)",
            valueBefore: .string(before),
            valueAfter: .string(after)
        ))
    }

    private func appendBoolDelta(
        _ deltas: inout [CharacterLedgerDeltaDraft],
        domain: CharacterMetricDomain,
        name: String,
        before: Bool,
        after: Bool,
        reasonPrefix: String
    ) {
        guard before != after else { return }
        deltas.append(CharacterLedgerDeltaDraft(
            metricDomain: domain,
            metricName: name,
            reasonCode: "\(reasonPrefix).\(domain.rawValue).\(name)",
            valueBefore: .bool(before),
            valueAfter: .bool(after)
        ))
    }

    private func appendMapDeltas(
        _ deltas: inout [CharacterLedgerDeltaDraft],
        domain: CharacterMetricDomain,
        before: [String: Int],
        after: [String: Int],
        reasonPrefix: String
    ) {
        let keys = Set(before.keys).union(after.keys)
        for key in keys.sorted() {
            appendIntDelta(
                &deltas,
                domain: domain,
                name: key,
                before: before[key] ?? 0,
                after: after[key] ?? 0,
                reasonPrefix: reasonPrefix
            )
        }
    }

    private func captureTransientState() -> EngineTransientStateSnapshot {
        EngineTransientStateSnapshot(
            lastActiveSource: lastActiveSource,
            sessionMetadataByID: sessionMetadataByID,
            sessionFocusThresholdFired: sessionFocusThresholdFired,
            promptStartTimes: promptStartTimes,
            promptLastSampleTimes: promptLastSampleTimes,
            promptTurnOrigins: promptTurnOrigins,
            sessionMealActiveSeconds: sessionMealActiveSeconds,
            sessionActiveSeconds: sessionActiveSeconds,
            sessionLastFocusActiveSeconds: sessionLastFocusActiveSeconds,
            lastToolEventTime: lastToolEventTime,
            sessionsCounted: sessionsCounted,
            lastLazyTickAt: lastLazyTickAt,
            lastActiveAt: lastActiveAt
        )
    }

    private func restoreTransientState(_ snapshot: EngineTransientStateSnapshot) {
        lastActiveSource = snapshot.lastActiveSource
        sessionMetadataByID = snapshot.sessionMetadataByID
        sessionFocusThresholdFired = snapshot.sessionFocusThresholdFired
        promptStartTimes = snapshot.promptStartTimes
        promptLastSampleTimes = snapshot.promptLastSampleTimes
        promptTurnOrigins = snapshot.promptTurnOrigins
        sessionMealActiveSeconds = snapshot.sessionMealActiveSeconds
        sessionActiveSeconds = snapshot.sessionActiveSeconds
        sessionLastFocusActiveSeconds = snapshot.sessionLastFocusActiveSeconds
        lastToolEventTime = snapshot.lastToolEventTime
        sessionsCounted = snapshot.sessionsCounted
        lastLazyTickAt = snapshot.lastLazyTickAt
        lastActiveAt = snapshot.lastActiveAt
    }

    private func clearAllTransientTracking() {
        lastActiveSource = nil
        sessionMetadataByID.removeAll()
        sessionFocusThresholdFired.removeAll()
        promptStartTimes.removeAll()
        promptLastSampleTimes.removeAll()
        promptTurnOrigins.removeAll()
        sessionMealActiveSeconds.removeAll()
        sessionActiveSeconds.removeAll()
        sessionLastFocusActiveSeconds.removeAll()
        lastToolEventTime.removeAll()
        sessionsCounted.removeAll()
        lastLazyTickAt = .distantPast
        lastActiveAt = nowProvider()
    }

    // MARK: - Timer

    // MARK: - Shared formatters

    private static let dayFmt: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    // MARK: - Timer

    private func startTimer() {
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: activePromptSampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                let runningSessionIds = self.runningSessionProvider()
                self.sampleActivePromptTime(runningSessionIds: runningSessionIds, now: now)
                self.tick(now: now, isAnySessionActive: !runningSessionIds.isEmpty)
            }
        }
    }

    private func stopTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - Helpers

    private func ledgerPayloadToRawJSON(_ payload: [String: AnyCodableLike]) -> [String: Any] {
        payload.mapValues(\.foundationValue)
    }

    private func toolInput(from rawJSON: [String: Any]) -> [String: Any]? {
        firstDictionary(in: rawJSON, keys: ["tool_input", "toolInput", "input", "arguments", "args", "params"])
            ?? firstDictionary(inNestedDictionary: rawJSON, containerKeys: ["tool", "payload", "data"],
                               keys: ["input", "tool_input", "toolInput", "arguments", "args", "params"])
    }

    private func firstDictionary(in dictionary: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = dictionary[key] as? [String: Any] {
                return value
            }
        }
        return nil
    }

    private func firstDictionary(inNestedDictionary dictionary: [String: Any],
                                 containerKeys: [String],
                                 keys: [String]) -> [String: Any]? {
        for containerKey in containerKeys {
            guard let nested = dictionary[containerKey] as? [String: Any] else { continue }
            if let value = firstDictionary(in: nested, keys: keys) {
                return value
            }
        }
        return nil
    }

    private func ledgerBool(_ value: AnyCodableLike?) -> Bool? {
        switch value {
        case .bool(let bool):
            return bool
        case .int(let int):
            return int != 0
        case .double(let double):
            return double != 0
        case .string(let string):
            switch string.lowercased() {
            case "1", "true":
                return true
            case "0", "false":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private func ledgerInt(_ value: AnyCodableLike?) -> Int? {
        switch value {
        case .int(let int):
            return Int(int)
        case .double(let double):
            return Int(double)
        case .string(let string):
            return Int(string)
        default:
            return nil
        }
    }

    private func ledgerDouble(_ value: AnyCodableLike?) -> Double? {
        switch value {
        case .double(let double):
            return double
        case .int(let int):
            return Double(int)
        case .string(let string):
            return Double(string)
        default:
            return nil
        }
    }

    private func ledgerString(_ value: AnyCodableLike?) -> String? {
        switch value {
        case .string(let string):
            return string
        case .int(let int):
            return String(int)
        case .double(let double):
            return String(double)
        default:
            return nil
        }
    }

    private func toolSemantic(from rawValue: String?) -> ToolSemantic? {
        guard let rawValue else { return nil }
        return ToolSemantic(rawValue: rawValue)
    }

    private func normalize(_ name: String) -> String {
        // Map snake_case / camelCase variants to canonical names
        switch name.lowercased().replacingOccurrences(of: "_", with: "") {
        case "posttooluse":    return "PostToolUse"
        case "stop", "poststop": return "PostStop"
        case "userpromptsubmit": return "UserPromptSubmit"
        case "notification":  return "Notification"
        case "sessionstart":  return "SessionStart"
        case "sessionend":    return "SessionEnd"
        case "subagentstart": return "SubagentStart"
        case "subagentstop":  return "SubagentStop"
        case "permissionrequest": return "PermissionRequest"
        default:              return name
        }
    }

    private func isSuccess(rawJSON: [String: Any]) -> Bool {
        // PostToolUse payload typically has "success" boolean or "exit_code" == 0
        if let success = rawJSON["success"] as? Bool { return success }
        if let code = rawJSON["exit_code"] as? Int { return code == 0 }
        if let code = rawJSON["exit_code"] as? Int64 { return code == 0 }
        if let code = rawJSON["exit_code"] as? NSNumber { return code.intValue == 0 }
        // "error" key presence indicates failure
        if let error = rawJSON["error"] as? String, !error.isEmpty { return false }
        // Default: assume success if no explicit failure signal
        return true
    }
}
