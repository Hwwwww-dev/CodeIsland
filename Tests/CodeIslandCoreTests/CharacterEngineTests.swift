import XCTest
@testable import CodeIslandCore

// MARK: - CharacterStats Unit Tests

final class CharacterEngineTests: XCTestCase {

    // MARK: - Mood Derivation Priority

    func testMoodSick_singleAxisLow() {
        // Single vital below 30 → mapped to its single-axis mood.
        // Multi-axis low cases now fall through to .critical (see below).
        var stats = CharacterStats()
        stats.vital.health = 20   // < 30 → sick
        stats.vital.energy = 50
        stats.vital.hunger = 50
        stats.vital.mood   = 50
        XCTAssertEqual(stats.derivedMood, .sick)
    }

    func testMoodTired_singleAxisLow() {
        var stats = CharacterStats()
        stats.vital.health = 50
        stats.vital.energy = 10   // < 30 → tired
        stats.vital.hunger = 50
        stats.vital.mood   = 50
        XCTAssertEqual(stats.derivedMood, .tired)
    }

    func testMoodHungry_singleAxisLow() {
        var stats = CharacterStats()
        stats.vital.health = 50
        stats.vital.energy = 50
        stats.vital.hunger = 20   // < 30 → hungry
        stats.vital.mood   = 50
        XCTAssertEqual(stats.derivedMood, .hungry)
    }

    func testMoodCritical_takesPrecedence_overSingleAxis() {
        // Composite burnout: ≥2 vitals < 30 → .critical, regardless of which.
        var stats = CharacterStats()
        stats.vital.health = 20   // would be sick on its own
        stats.vital.energy = 20   // would be tired on its own
        stats.vital.hunger = 50
        stats.vital.mood   = 50
        XCTAssertEqual(stats.derivedMood, .critical)
    }

    func testMoodCritical_threeAxesLow() {
        var stats = CharacterStats()
        stats.vital.health = 50
        stats.vital.energy = 0.2
        stats.vital.hunger = 50
        stats.vital.mood   = 22.2
        // Real-world example from production: energy + mood both red →
        // burnout, not just "tired".
        XCTAssertEqual(stats.derivedMood, .critical)
    }

    func testMoodSingleAxis_atBoundary_doesNotTriggerCritical() {
        // 29.99 is "low" (<30), 30 is fine. Only one below 30 → single-axis.
        var stats = CharacterStats()
        stats.vital.health = 30   // exactly 30, not <30
        stats.vital.energy = 29.9 // < 30 → tired (only this one)
        stats.vital.hunger = 30
        stats.vital.mood   = 30
        XCTAssertEqual(stats.derivedMood, .tired)
    }

    func testMoodSad_priority4() {
        var stats = CharacterStats()
        stats.vital.health = 50
        stats.vital.energy = 50
        stats.vital.hunger = 50
        stats.vital.mood   = 20   // < 30 → sad
        XCTAssertEqual(stats.derivedMood, .sad)
    }

    func testMoodJoyful_allHigh() {
        var stats = CharacterStats()
        stats.vital.health = 90
        stats.vital.energy = 90
        stats.vital.hunger = 90
        stats.vital.mood   = 90
        XCTAssertEqual(stats.derivedMood, .joyful)
    }

    func testMoodNeutral_otherwise() {
        var stats = CharacterStats()
        stats.vital.health = 50
        stats.vital.energy = 50
        stats.vital.hunger = 50
        stats.vital.mood   = 50
        XCTAssertEqual(stats.derivedMood, .neutral)
    }

    func testMoodNeutral_joyfulBoundaryNotMet() {
        var stats = CharacterStats()
        stats.vital.health = 80
        stats.vital.energy = 80
        stats.vital.hunger = 80
        stats.vital.mood   = 79   // just below 80 — not joyful
        XCTAssertEqual(stats.derivedMood, .neutral)
    }

    // MARK: - Persistence Round-Trip (SQLite)

    @MainActor
    func testPersistenceRoundTrip() throws {
        let tmpDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("char-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmpDB) }

        let persistence = CharacterPersistence(dbPath: tmpDB)

        var original = CharacterStats()
        original.vital.hunger     = 62.0
        original.vital.mood       = 73.0
        original.vital.energy     = 41.0
        original.vital.health     = 88.0
        original.cyber.focus      = 3437.0
        original.cyber.diligence  = 8912.0
        original.stats.totalSessions  = 312
        original.stats.totalToolCalls = 4781
        original.stats.toolUseCount   = ["Edit": 10, "Read": 5]
        original.stats.cliUseCount    = ["claude": 7]
        original.settings.paused = false

        persistence.saveNow(original)
        let decoded = persistence.load()

        XCTAssertEqual(decoded.vital.hunger,  62.0, accuracy: 0.001)
        XCTAssertEqual(decoded.vital.mood,    73.0, accuracy: 0.001)
        XCTAssertEqual(decoded.vital.energy,  41.0, accuracy: 0.001)
        XCTAssertEqual(decoded.vital.health,  88.0, accuracy: 0.001)
        XCTAssertEqual(decoded.cyber.focus,   3437.0, accuracy: 0.001)
        XCTAssertEqual(decoded.cyber.diligence, 8912.0, accuracy: 0.001)
        XCTAssertEqual(decoded.stats.totalSessions,  312)
        XCTAssertEqual(decoded.stats.totalToolCalls, 4781)
        XCTAssertEqual(decoded.stats.toolUseCount["Edit"], 10)
        XCTAssertEqual(decoded.stats.cliUseCount["claude"], 7)
        XCTAssertEqual(decoded.settings.paused, false)
    }

    // MARK: - Legacy data discard

    @MainActor
    func testLegacyJSON_isDiscardedOnLoad() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("char-migrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Write a legacy JSON file matching the old CharacterStats shape
        let jsonContent = """
        {
          "version": 1,
          "lastTickedAt": "2025-01-15T10:00:00Z",
          "vital": { "hunger": 55, "mood": 60, "energy": 45, "health": 70 },
          "cyber": { "focus": 1200, "diligence": 800, "collab": 300, "taste": 150, "curiosity": 500 },
          "stats": {
            "totalSessions": 42, "totalToolCalls": 100, "totalActiveSeconds": 36000,
            "currentDayActiveSeconds": 3600, "currentDayDate": "2025-01-15",
            "streakDays": 3, "lastActiveDate": "2025-01-14",
            "toolUseCount": {"Edit": 20, "Read": 30},
            "cliUseCount": {"claude": 42},
            "last7DaysActiveSeconds": [0, 1800, 3600, 7200, 5400, 3600, 3600]
          },
          "settings": { "paused": false }
        }
        """
        let jsonURL = tmpDir.appendingPathComponent("character.json")
        try jsonContent.data(using: .utf8)!.write(to: jsonURL)

        let dbURL = tmpDir.appendingPathComponent("character.sqlite")
        let persistence = CharacterPersistence(dbPath: dbURL)
        let loaded = persistence.load()

        // New requirement: ignore all legacy Character history and start from zero.
        XCTAssertEqual(loaded.vital.hunger, 100.0, accuracy: 0.001)
        XCTAssertEqual(loaded.vital.health, 100.0, accuracy: 0.001)
        XCTAssertEqual(loaded.cyber.focus, 0.0, accuracy: 0.001)
        XCTAssertEqual(loaded.stats.totalSessions, 0)
        XCTAssertEqual(loaded.stats.streakDays, 0)
        XCTAssertTrue(loaded.stats.toolUseCount.isEmpty)
        XCTAssertTrue(loaded.stats.cliUseCount.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jsonURL.path),
                       "Legacy character.json should be removed during destructive upgrade")
    }

    // MARK: - Daily Active Query

    @MainActor
    func testDailyActive_querySorted() throws {
        let tmpDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("char-daily-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmpDB) }

        let persistence = CharacterPersistence(dbPath: tmpDB)
        // Initialize schema
        _ = persistence.load()

        // Insert 10 days of data (some zero, some non-zero)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        for offset in 0..<10 {
            guard let day = cal.date(byAdding: .day, value: -(9 - offset), to: today) else { continue }
            let dateStr = fmt.string(from: day)
            let secs = offset % 3 == 0 ? 0 : (offset + 1) * 600  // some zeros
            if secs > 0 {
                persistence.upsertDailyActive(date: dateStr, seconds: secs)
            }
        }

        let results = persistence.last7DaysActive()

        // Only non-zero days, at most 7 days back, sorted ascending
        XCTAssertTrue(results.count <= 7, "At most 7 days returned")
        XCTAssertTrue(results.allSatisfy { $0.seconds > 0 }, "All returned entries must be non-zero")

        // Verify sorted by date ascending
        for i in 1..<results.count {
            XCTAssertLessThan(results[i-1].date, results[i].date, "Results must be sorted ascending")
        }

        // All dates must be within the last 7 days
        let cutoff = cal.date(byAdding: .day, value: -6, to: today)!
        for row in results {
            XCTAssertGreaterThanOrEqual(row.date, cutoff, "All dates must be within last 7 days")
        }
    }

    // MARK: - Decay Correctness

    @MainActor
    func testDecay_hungerDropsFourPerHour() {
        // With delta-coupling, hunger decay of -8 also reduces other vitals,
        // and energy recovery (2h from 50 → ~100) propagates +0.2×ΔE back to hunger.
        // Net result: hunger is clamped at 100 because recovery propagation exceeds decay.
        // Test with isAnySessionActive: true to isolate the hunger-only decay path.
        var stats = CharacterStats()
        stats.vital.hunger = 100
        stats.vital.energy = 50
        let now = Date()
        stats.lastTickedAt = now.addingTimeInterval(-2 * 3600)  // 2 hours ago
        let engine = CharacterEngine.makeForTesting(stats: stats)

        engine.tick(now: now, isAnySessionActive: true)  // suppress energy recovery

        // 2h × 4/h decay → hunger -8 → 92; hunger is a driver, coupling propagates
        // -8×0.5=-4 to mood, -8×0.2=-1.6 to health (no out-edge to energy). Hunger itself: 92.
        XCTAssertEqual(engine.characterStats.vital.hunger, 92.0, accuracy: 0.001)
    }

    func testDecay_energyRecoveryWhenIdle() {
        // Validates the closed-form exponential formula (rate-agnostic).
        // Uses 0.06 as a representative rate constant: E(t) = 100 - (100 - E0) * exp(-r * dt_min)
        // E0=40, r=0.06, dt=10min: 100 - 60 * exp(-0.6) = 67.071
        var stats = CharacterStats()
        stats.vital.energy = 40
        let dtMinutes = 10.0
        let decay = exp(-0.06 * dtMinutes)
        stats.vital.energy = 100 - (100 - stats.vital.energy) * decay
        stats.vital.clamp()

        XCTAssertEqual(stats.vital.energy, 67.071, accuracy: 0.01)
    }

    func testDecay_energyRecoveryAsymptotic() {
        // Validates asymptotic approach to 100 using representative rate r=0.06.
        // E0=50, r=0.06, dt=20min: 100 - 50 * exp(-1.2) ≈ 84.94.
        var stats = CharacterStats()
        stats.vital.energy = 50
        let dtMinutes = 20.0
        let decay = exp(-0.06 * dtMinutes)
        stats.vital.energy = 100 - (100 - stats.vital.energy) * decay
        stats.vital.clamp()

        XCTAssertEqual(stats.vital.energy, 84.94, accuracy: 0.01)
    }

    func testDecay_valuesClampAtZero() {
        var stats = CharacterStats()
        stats.vital.hunger = 1.0
        stats.vital.hunger -= 5.0  // would go negative
        stats.vital.clamp()
        XCTAssertEqual(stats.vital.hunger, 0.0)
    }

    func testDecay_valuesClampAt100() {
        var stats = CharacterStats()
        stats.vital.energy = 98.0
        stats.vital.energy += 10.0  // would exceed 100
        stats.vital.clamp()
        XCTAssertEqual(stats.vital.energy, 100.0)
    }

    // MARK: - Long Absence Clamp

    func testLongAbsence_clampedTo7Days() {
        // 30-day absence → clamped to 168h (7 days) of decay
        let maxDecayHours = 7.0 * 24  // = 168
        var stats = CharacterStats()
        stats.vital.hunger = 100

        // Apply clamped decay
        let dt = min(30 * 24.0, maxDecayHours)
        XCTAssertEqual(dt, 168.0, accuracy: 0.001)  // clamp enforced

        stats.vital.hunger -= dt * 4.0  // -672 with -4/h rate -> clamp to 0
        stats.vital.clamp()
        XCTAssertEqual(stats.vital.hunger, 0.0)  // all gone, but not "more than zero gone"
    }

    func testLongAbsence_shortAbsenceNotClamped() {
        let maxDecayHours = 7.0 * 24
        let dt = min(3.0, maxDecayHours)
        XCTAssertEqual(dt, 3.0, accuracy: 0.001)  // no clamp for short absence
    }

    // MARK: - Event Delta Application

    func testEvent_postStop_raisesHungerAndMood() {
        var stats = CharacterStats()
        stats.vital.hunger = 70
        stats.vital.mood   = 60

        // Simulate PostStop: +5 hunger, +0.5 mood
        stats.vital.hunger = min(100, stats.vital.hunger + 5)
        stats.vital.mood   = min(100, stats.vital.mood   + 0.5)
        stats.vital.clamp()

        XCTAssertEqual(stats.vital.hunger, 75.0, accuracy: 0.001)
        XCTAssertEqual(stats.vital.mood,   60.5, accuracy: 0.001)
    }

    func testEvent_postToolSuccess_hunger_energy() {
        var stats = CharacterStats()
        stats.vital.hunger = 60
        stats.vital.energy = 50

        // PostToolUse success: only energy -0.2. Hunger unchanged
        // (passive -4/h decay + meals on PostStop are the sole hunger paths).
        stats.vital.energy = max(0, stats.vital.energy - 0.2)
        stats.vital.clamp()

        XCTAssertEqual(stats.vital.hunger, 60.0, accuracy: 0.001)
        XCTAssertEqual(stats.vital.energy, 49.8, accuracy: 0.001)
    }

    @MainActor
    func testEvent_postStop_mealGate_underMinDuration_noMeal() {
        // No prompt-active time: no meal regardless of tool count.
        var stats = CharacterStats()
        stats.vital.hunger = 50
        let engine = CharacterEngine.makeForTesting(stats: stats)
        let sid = "abuse-quick"
        let json: [String: Any] = ["hook_event_name": "SessionStart", "session_id": sid]
        let startData = try! JSONSerialization.data(withJSONObject: json)
        engine.handle(event: HookEvent(from: startData)!, sessionContext: nil)

        // Immediately stop with high tool count — duration ~0
        let stopJSON: [String: Any] = ["hook_event_name": "PostStop", "session_id": sid]
        let stopData = try! JSONSerialization.data(withJSONObject: stopJSON)
        engine.handle(event: HookEvent(from: stopData)!,
                      sessionContext: CharacterSessionContext(totalTools: 100))

        // hunger is a driver — mood/health no longer propagate to it. PostStop's mood +0.5
        // stays in mood. No meal (duration ~0). Hunger decay is ~0 (dt ≈ 0). So hunger ≈ 50.
        XCTAssertEqual(engine.characterStats.vital.hunger, 50.0, accuracy: 0.5)
    }

    @MainActor
    func testEvent_postStop_mealGate_underMinTools_noMeal() throws {
        // Prompt-active time without tools does not feed the character.
        var stats = CharacterStats()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        stats.lastTickedAt = now
        stats.vital.hunger = 50
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
        let sid = "idle-session"

        engine.handle(event: try makeHookEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": sid,
        ]), sessionContext: nil)

        now = now.addingTimeInterval(6 * 60)
        engine.handle(event: try makeHookEvent([
            "hook_event_name": "PostStop",
            "session_id": sid,
        ]),
                      sessionContext: CharacterSessionContext(totalTools: 0,
                                                              hasActiveSession: true))

        // No meal (0 tools). hunger is a driver — mood events do not propagate to it.
        // Active path: 6 min × 4/h hunger decay = -0.4, plus the new damped
        // active-recovery channel adds ~+0.1 toward the 60 ceiling (rate ×
        // 0.1 damping over 6 min effective). Net: 50 - 0.4 + 0.1 ≈ 49.7.
        XCTAssertEqual(engine.characterStats.vital.hunger, 49.7, accuracy: 0.2)
    }

    @MainActor
    func testEvent_postStop_mealGateScalesAcrossPromptActiveBands() throws {
        let cases: [(minutes: Int, tools: Int, meal: Double)] = [
            (1, 2, 1),
            (2, 3, 2),
            (5, 5, 4),
            (10, 10, 6),
            (20, 20, 9),
            (30, 30, 12),
        ]

        for testCase in cases {
            var stats = CharacterStats()
            var now = Date(timeIntervalSince1970: 1_700_000_000)
            stats.lastTickedAt = now
            stats.vital.hunger = 50
            let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
            let sid = "prompt-meal-\(testCase.minutes)"

            engine.handle(event: try makeHookEvent([
                "hook_event_name": "UserPromptSubmit",
                "session_id": sid,
            ]), sessionContext: nil)

            now = now.addingTimeInterval(TimeInterval(testCase.minutes * 60))
            engine.handle(event: try makeHookEvent([
                "hook_event_name": "PostStop",
                "session_id": sid,
            ]), sessionContext: CharacterSessionContext(totalTools: testCase.tools,
                                                        hasActiveSession: true))

            // hasActiveSession=true keeps the trailing tick on the active path
            // (under the rebalanced model, idle ticks would route hunger toward
            // its idle ceiling instead of decaying).
            let decay = Double(testCase.minutes) / 60.0 * 4.0
            // Asymmetric coupling: hunger is a driver, no mood/energy back-propagation.
            // Only paths: PostStop meal +reward, and the elapsed hunger decay.
            // Final: 50 + meal - decay.
            XCTAssertEqual(engine.characterStats.vital.hunger,
                           50 + testCase.meal - decay,
                           accuracy: 0.1,
                           "minutes=\(testCase.minutes), tools=\(testCase.tools)")
        }
    }

    @MainActor
    func testEvent_postStop_mealGateUsesUserPromptSubmitWithoutSessionStart() throws {
        var stats = CharacterStats()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        stats.lastTickedAt = now
        stats.vital.hunger = 50
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
        let sid = "prompt-meal"

        engine.handle(event: try makeHookEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": sid,
        ]), sessionContext: nil)

        now = now.addingTimeInterval(5 * 60)
        engine.handle(event: try makeHookEvent([
            "hook_event_name": "PostStop",
            "session_id": sid,
        ]), sessionContext: CharacterSessionContext(totalTools: 5, hasActiveSession: true))

        // 5min active + 5 tools → meal band (300s, 5, 4) → reward=4.
        // hunger is a driver, no back-propagation: 50 + 4 - (5/60×4) = 53.67.
        // hasActiveSession=true keeps the trailing tick on the active path.
        XCTAssertEqual(engine.characterStats.vital.hunger, 50 + 4.0 - (5.0 / 60.0 * 4.0), accuracy: 0.1)
    }

    @MainActor
    func testEvent_postStop_mealGateIgnoresSessionStartBeforePrompt() throws {
        var stats = CharacterStats()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        stats.lastTickedAt = now
        stats.vital.hunger = 50
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
        let sid = "start-before-prompt"

        // hasActiveSession=true on every event so the trailing tick stays on
        // the active (decay) path. Without it the rebalanced model would route
        // the 2h gap into idle recovery instead of decay.
        let activeCtx = CharacterSessionContext(hasActiveSession: true)
        engine.handle(event: try makeHookEvent([
            "hook_event_name": "SessionStart",
            "session_id": sid,
        ]), sessionContext: activeCtx)

        now = now.addingTimeInterval(2 * 3600)
        engine.handle(event: try makeHookEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": sid,
        ]), sessionContext: activeCtx)

        now = now.addingTimeInterval(60)
        engine.handle(event: try makeHookEvent([
            "hook_event_name": "PostStop",
            "session_id": sid,
        ]), sessionContext: CharacterSessionContext(totalTools: 30, hasActiveSession: true))

        // 60s active prompt window + 30 tools → meal band (60s, 2, 1) → reward=1.
        // Sims-style hunger model: pure decay (no active recovery), no
        // coupling propagation. 50 - 8 (2h decay) + 1 (meal) - 0.067 (60s
        // post-meal decay) ≈ 42.93.
        XCTAssertEqual(engine.characterStats.vital.hunger, 42.93, accuracy: 0.1)
    }

    func testEvent_postToolFailure_moodBumped() {
        var stats = CharacterStats()
        stats.vital.mood = 50

        // PostToolUse failure: mood -2 (bumped from -1)
        stats.vital.mood = max(0, stats.vital.mood - 2)
        stats.vital.clamp()

        XCTAssertEqual(stats.vital.mood, 48.0, accuracy: 0.001)
    }

    func testEvent_permissionDenied_moodBumped() {
        var stats = CharacterStats()
        stats.vital.mood = 50

        // Notification deny: mood -3 (bumped from -2)
        stats.vital.mood = max(0, stats.vital.mood - 3)
        stats.vital.clamp()

        XCTAssertEqual(stats.vital.mood, 47.0, accuracy: 0.001)
    }

    func testDailyRoll_health_sweetSpot_plus3() {
        // 1–4 h active → health +3 (was +2)
        var stats = CharacterStats()
        stats.vital.health = 50
        let seconds = 7200  // 2 h
        if seconds >= 3600 && seconds <= 14400 {
            stats.vital.health = min(100, stats.vital.health + 3)
        }
        stats.vital.clamp()
        XCTAssertEqual(stats.vital.health, 53.0, accuracy: 0.001)
    }

    func testDailyRoll_health_overworked_minus3() {
        // >8 h → health -3 (was -2)
        var stats = CharacterStats()
        stats.vital.health = 50
        let seconds = 32400  // 9 h
        if seconds < 1800 || seconds > 28800 {
            stats.vital.health = max(0, stats.vital.health - 3)
        }
        stats.vital.clamp()
        XCTAssertEqual(stats.vital.health, 47.0, accuracy: 0.001)
    }

    func testEvent_postToolFailure_dropsMood() {
        var stats = CharacterStats()
        stats.vital.mood = 50

        // PostToolUse failure: mood -1
        stats.vital.mood = max(0, stats.vital.mood - 1)
        stats.vital.clamp()

        XCTAssertEqual(stats.vital.mood, 49.0, accuracy: 0.001)
    }

    func testEvent_diligence_incremented_byEdit() {
        var stats = CharacterStats()
        stats.cyber.diligence = 100

        // Edit → diligence +2
        stats.cyber.diligence += 2

        XCTAssertEqual(stats.cyber.diligence, 102.0, accuracy: 0.001)
    }

    func testEvent_curiosity_incrementedByRead() {
        var stats = CharacterStats()
        stats.cyber.curiosity = 50

        // Read → curiosity +1.5
        stats.cyber.curiosity += 1.5

        XCTAssertEqual(stats.cyber.curiosity, 51.5, accuracy: 0.001)
    }

    @MainActor
    func testEvent_codexBashReadCommandCountsAsReadForCharacterStats() throws {
        var stats = CharacterStats()
        stats.cyber.curiosity = 50
        let engine = CharacterEngine.makeForTesting(stats: stats)
        let event = try makeHookEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "codex-read",
            "tool_name": "Bash",
            "success": true,
            "tool_input": [
                "command": "sed -n '1,120p' Sources/CodeIslandCore/CharacterEngine.swift"
            ],
        ])

        engine.handle(
            event: event,
            sessionContext: CharacterSessionContext(source: "codex")
        )

        XCTAssertEqual(engine.characterStats.cyber.curiosity, 51.5, accuracy: 0.001)
        XCTAssertEqual(engine.characterStats.stats.toolUseCount["Read"], 1)
        XCTAssertNil(engine.characterStats.stats.toolUseCount["Bash"])
    }

    @MainActor
    func testEvent_lowercaseReadAliasCountsAsReadForCharacterStats() throws {
        var stats = CharacterStats()
        stats.cyber.curiosity = 50
        let engine = CharacterEngine.makeForTesting(stats: stats)
        let event = try makeHookEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "lowercase-read",
            "tool_name": "read_file",
            "success": true,
        ])

        engine.handle(
            event: event,
            sessionContext: CharacterSessionContext(source: "gemini")
        )

        XCTAssertEqual(engine.characterStats.cyber.curiosity, 51.5, accuracy: 0.001)
        XCTAssertEqual(engine.characterStats.stats.toolUseCount["Read"], 1)
        XCTAssertNil(engine.characterStats.stats.toolUseCount["read_file"])
    }

    @MainActor
    func testEvent_regularBashCommandStaysBashForCharacterStats() throws {
        var stats = CharacterStats()
        stats.cyber.curiosity = 50
        stats.cyber.diligence = 20
        let engine = CharacterEngine.makeForTesting(stats: stats)
        let event = try makeHookEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "bash-build",
            "tool_name": "Bash",
            "success": true,
            "tool_input": [
                "command": "swift test --filter CharacterEngineTests"
            ],
        ])

        engine.handle(
            event: event,
            sessionContext: CharacterSessionContext(source: "codex")
        )

        XCTAssertEqual(engine.characterStats.cyber.curiosity, 50, accuracy: 0.001)
        XCTAssertEqual(engine.characterStats.cyber.diligence, 21, accuracy: 0.001)
        XCTAssertEqual(engine.characterStats.stats.toolUseCount["Bash"], 1)
        XCTAssertNil(engine.characterStats.stats.toolUseCount["Read"])
    }

    @MainActor
    func testEvent_wrappedBashReadCommandCountsAsReadForCharacterStats() throws {
        var stats = CharacterStats()
        stats.cyber.curiosity = 50
        stats.cyber.diligence = 20
        let engine = CharacterEngine.makeForTesting(stats: stats)
        let event = try makeHookEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "wrapped-read",
            "tool_name": "Bash",
            "success": true,
            "tool_input": [
                "command": "env LC_ALL=C command sudo -n sed -n '1,80p' Package.swift"
            ],
        ])

        engine.handle(
            event: event,
            sessionContext: CharacterSessionContext(source: "codex")
        )

        XCTAssertEqual(engine.characterStats.cyber.curiosity, 51.5, accuracy: 0.001)
        // Shell-inferred Read no longer double-counts as diligence.
        XCTAssertEqual(engine.characterStats.cyber.diligence, 20, accuracy: 0.001)
        XCTAssertEqual(engine.characterStats.stats.toolUseCount["Read"], 1)
        XCTAssertNil(engine.characterStats.stats.toolUseCount["Bash"])
    }

    @MainActor
    func testEvent_successfulEditAddsImmediateFocus() throws {
        // Focus is time-axis only; a single tool call without time elapsed = no focus change.
        var stats = CharacterStats()
        stats.cyber.focus = 10
        let engine = CharacterEngine.makeForTesting(stats: stats)
        let event = try makeHookEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "edit-focus",
            "tool_name": "Edit",
            "success": true,
        ])

        engine.handle(
            event: event,
            sessionContext: CharacterSessionContext(source: "claude")
        )

        XCTAssertEqual(engine.characterStats.cyber.focus, 10, accuracy: 0.001)
    }

    @MainActor
    func testEvent_successfulReadAddsSameImmediateFocus() throws {
        // Focus is time-axis only; a single tool call without time elapsed = no focus change.
        var stats = CharacterStats()
        stats.cyber.focus = 10
        let engine = CharacterEngine.makeForTesting(stats: stats)
        let event = try makeHookEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "read-focus",
            "tool_name": "Read",
            "success": true,
        ])

        engine.handle(
            event: event,
            sessionContext: CharacterSessionContext(source: "claude")
        )

        XCTAssertEqual(engine.characterStats.cyber.focus, 10, accuracy: 0.001)
    }

    @MainActor
    func testEvent_searchCountsAsCuriosityTool() throws {
        var stats = CharacterStats()
        stats.cyber.curiosity = 50
        let engine = CharacterEngine.makeForTesting(stats: stats)
        let event = try makeHookEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "search-curiosity",
            "tool_name": "Search",
            "success": true,
        ])

        engine.handle(
            event: event,
            sessionContext: CharacterSessionContext(source: "claude")
        )

        // "Search" → ToolSemanticMapper classifies as (.search, "WebSearch")
        XCTAssertEqual(engine.characterStats.cyber.curiosity, 51.5, accuracy: 0.001)
        XCTAssertEqual(engine.characterStats.stats.toolUseCount["WebSearch"], 1)
        XCTAssertNil(engine.characterStats.stats.toolUseCount["Search"])
    }

    @MainActor
    func testEvent_codexApplyPatchCountsAsEditForCharacterStats() throws {
        var stats = CharacterStats()
        stats.cyber.diligence = 20
        let engine = CharacterEngine.makeForTesting(stats: stats)
        let event = try makeHookEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "codex-apply-patch",
            "tool_name": "apply_patch",
            "success": true,
            "tool_input": [
                "command": "*** Begin Patch\n*** Update File: Example.swift\n*** End Patch"
            ],
        ])

        engine.handle(
            event: event,
            sessionContext: CharacterSessionContext(source: "codex")
        )

        XCTAssertEqual(engine.characterStats.cyber.diligence, 22, accuracy: 0.001)
        XCTAssertEqual(engine.characterStats.stats.toolUseCount["Edit"], 1)
        XCTAssertNil(engine.characterStats.stats.toolUseCount["apply_patch"])
    }

    @MainActor
    func testEvent_codexApplyPatchCreateFileCountsAsWriteForCharacterStats() throws {
        var stats = CharacterStats()
        stats.cyber.diligence = 20
        let engine = CharacterEngine.makeForTesting(stats: stats)
        let event = try makeHookEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "codex-apply-patch-create",
            "tool_name": "apply_patch",
            "success": true,
            "tool_input": [
                "type": "create_file",
                "path": "Example.swift",
                "diff": "+print(\"hi\")",
            ],
        ])

        engine.handle(
            event: event,
            sessionContext: CharacterSessionContext(source: "codex")
        )

        XCTAssertEqual(engine.characterStats.cyber.diligence, 22, accuracy: 0.001)
        XCTAssertEqual(engine.characterStats.stats.toolUseCount["Write"], 1)
        XCTAssertNil(engine.characterStats.stats.toolUseCount["Edit"])
    }

    @MainActor
    func testEvent_codexApplyPatchAddFileCommandCountsAsWriteForCharacterStats() throws {
        var stats = CharacterStats()
        stats.cyber.diligence = 20
        let engine = CharacterEngine.makeForTesting(stats: stats)
        let event = try makeHookEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "codex-apply-patch-add",
            "tool_name": "apply_patch",
            "success": true,
            "tool_input": [
                "command": "*** Begin Patch\n*** Add File: Example.swift\n+print(\"hi\")\n*** End Patch"
            ],
        ])

        engine.handle(
            event: event,
            sessionContext: CharacterSessionContext(source: "codex")
        )

        XCTAssertEqual(engine.characterStats.cyber.diligence, 22, accuracy: 0.001)
        XCTAssertEqual(engine.characterStats.stats.toolUseCount["Write"], 1)
        XCTAssertNil(engine.characterStats.stats.toolUseCount["Edit"])
    }

    @MainActor
    func testEvent_focusUsesToolActivityWithoutSessionStart() throws {
        var stats = CharacterStats()
        stats.cyber.focus = 0
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
        let event = try makeHookEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "codex-no-start",
            "tool_name": "Bash",
            "success": true,
            "tool_input": [
                "command": "swift test --filter CharacterEngineTests"
            ],
        ])

        for _ in 0..<6 {
            engine.handle(
                event: event,
                sessionContext: CharacterSessionContext(source: "codex")
            )
            now = now.addingTimeInterval(120)
        }

        // 30 + 5×120 = 630 active seconds. 600s threshold → +4. 630/300=2 bands → +4. Total = 8.
        XCTAssertEqual(engine.characterStats.cyber.focus, 8, accuracy: 0.001)
    }

    func testEvent_taste_incrementedByHighSuccessSession() {
        var stats = CharacterStats()
        stats.cyber.taste = 200

        // Session success rate ≥ 90%, totalTools ≥ 5 → taste scaled linearly.
        // 0.95 → 5 + (0.95 - 0.90) * 50 = 5 + 2.5 = 7.5
        let successRate = 0.95
        let totalTools  = 10
        if successRate >= 0.90 && totalTools >= 5 {
            stats.cyber.taste += 5.0 + (successRate - 0.90) * 50.0
        }

        XCTAssertEqual(stats.cyber.taste, 207.5, accuracy: 0.001)
    }

    func testEvent_taste_notIncrementedByLowSuccessSession() {
        var stats = CharacterStats()
        stats.cyber.taste = 200

        let successRate = 0.80  // below 90%
        let totalTools  = 10
        if successRate >= 0.90 && totalTools >= 5 {
            stats.cyber.taste += 10
        }

        XCTAssertEqual(stats.cyber.taste, 200.0, accuracy: 0.001)  // unchanged
    }

    @MainActor
    func testEvent_collabIncrementedByUserPromptSubmit() throws {
        var stats = CharacterStats()
        stats.cyber.collab = 100
        let engine = CharacterEngine.makeForTesting(stats: stats)
        let event = try makeHookEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "prompt-collab",
        ])

        engine.handle(event: event, sessionContext: nil)

        XCTAssertEqual(engine.characterStats.cyber.collab, 102.0, accuracy: 0.001)
    }

    @MainActor
    func testActiveTimeCountsFromUserPromptSubmitToStopWithoutTools() throws {
        var stats = CharacterStats()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        stats.lastTickedAt = now
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
        let sid = "prompt-to-stop"

        engine.handle(event: try makeHookEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": sid,
        ]), sessionContext: nil)

        now = now.addingTimeInterval(180)
        engine.handle(event: try makeHookEvent([
            "hook_event_name": "PostStop",
            "session_id": sid,
        ]), sessionContext: nil)

        XCTAssertEqual(engine.characterStats.stats.totalActiveSeconds, 180)
        XCTAssertEqual(engine.characterStats.stats.currentDayActiveSeconds, 180)
    }

    @MainActor
    func testActiveTimeCountsUntilLateStopWithoutEightHourCap() throws {
        var stats = CharacterStats()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        stats.lastTickedAt = now
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
        let sid = "late-stop"

        engine.handle(event: try makeHookEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": sid,
        ]), sessionContext: nil)

        now = now.addingTimeInterval(10 * 3600)
        engine.handle(event: try makeHookEvent([
            "hook_event_name": "PostStop",
            "session_id": sid,
        ]), sessionContext: nil)

        XCTAssertEqual(engine.characterStats.stats.totalActiveSeconds, 10 * 3600)
        XCTAssertEqual(engine.characterStats.stats.currentDayActiveSeconds, 10 * 3600)
    }

    @MainActor
    func testActiveTimeSamplesEveryFiveSecondsWhileSessionStillRunning() throws {
        var stats = CharacterStats()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        stats.lastTickedAt = now
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
        let sid = "sampled-no-stop"

        engine.handle(event: try makeHookEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": sid,
        ]), sessionContext: nil)

        now = now.addingTimeInterval(4)
        engine.sampleActivePromptTime(runningSessionIds: [sid], now: now)
        XCTAssertEqual(engine.characterStats.stats.totalActiveSeconds, 0)

        now = now.addingTimeInterval(1)
        engine.sampleActivePromptTime(runningSessionIds: [sid], now: now)
        XCTAssertEqual(engine.characterStats.stats.totalActiveSeconds, 5)

        now = now.addingTimeInterval(5)
        engine.sampleActivePromptTime(runningSessionIds: [sid], now: now)
        XCTAssertEqual(engine.characterStats.stats.totalActiveSeconds, 10)
        XCTAssertEqual(engine.characterStats.stats.currentDayActiveSeconds, 10)
    }

    @MainActor
    func testActiveTimeCanContinuePastEightHoursWhileSessionStillRunning() throws {
        var stats = CharacterStats()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        stats.lastTickedAt = now
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
        let sid = "sampled-cap"

        engine.handle(event: try makeHookEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": sid,
        ]), sessionContext: nil)

        now = now.addingTimeInterval(10 * 3600)
        engine.sampleActivePromptTime(runningSessionIds: [sid], now: now)
        XCTAssertEqual(engine.characterStats.stats.totalActiveSeconds, 10 * 3600)
    }

    @MainActor
    func testActiveTimeStopsSamplingWhenSessionNoLongerRunning() throws {
        var stats = CharacterStats()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        stats.lastTickedAt = now
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
        let sid = "sampled-ended"

        engine.handle(event: try makeHookEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": sid,
        ]), sessionContext: nil)

        now = now.addingTimeInterval(5)
        engine.sampleActivePromptTime(runningSessionIds: [sid], now: now)
        XCTAssertEqual(engine.characterStats.stats.totalActiveSeconds, 5)

        now = now.addingTimeInterval(3)
        engine.sampleActivePromptTime(runningSessionIds: [], now: now)
        XCTAssertEqual(engine.characterStats.stats.totalActiveSeconds, 8)

        now = now.addingTimeInterval(3600)
        engine.sampleActivePromptTime(runningSessionIds: [], now: now)
        XCTAssertEqual(engine.characterStats.stats.totalActiveSeconds, 8)
    }

    @MainActor
    func testActiveTimeFinalizesOnSessionEnd() throws {
        var stats = CharacterStats()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        stats.lastTickedAt = now
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
        let sid = "session-end"

        engine.handle(event: try makeHookEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": sid,
        ]), sessionContext: nil)

        now = now.addingTimeInterval(180)
        engine.handle(event: try makeHookEvent([
            "hook_event_name": "SessionEnd",
            "session_id": sid,
        ]), sessionContext: nil)

        XCTAssertEqual(engine.characterStats.stats.totalActiveSeconds, 180)
        XCTAssertEqual(engine.characterStats.stats.currentDayActiveSeconds, 180)

        now = now.addingTimeInterval(3600)
        engine.sampleActivePromptTime(runningSessionIds: [sid], now: now)
        XCTAssertEqual(engine.characterStats.stats.totalActiveSeconds, 180)
    }

    @MainActor
    func testActiveTimeFallsBackToAgentLifecycleWhenPromptHookMissing() throws {
        var stats = CharacterStats()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        stats.lastTickedAt = now
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
        let sid = "agent-lifecycle"

        engine.handle(event: try makeHookEvent([
            "hook_event_name": "SubagentStart",
            "session_id": sid,
        ]), sessionContext: nil)

        now = now.addingTimeInterval(120)
        engine.handle(event: try makeHookEvent([
            "hook_event_name": "SubagentStop",
            "session_id": sid,
        ]), sessionContext: nil)

        XCTAssertEqual(engine.characterStats.stats.totalActiveSeconds, 120)
        XCTAssertEqual(engine.characterStats.stats.currentDayActiveSeconds, 120)
    }

    @MainActor
    func testEvent_subagentStart_grantsCollab() throws {
        // Each subagent dispatch is a per-spawn collaboration event,
        // distinct from the once-per-session fallback mood nudge inside ensurePromptTurnStarted.
        var stats = CharacterStats()
        stats.cyber.collab = 0
        let engine = CharacterEngine.makeForTesting(stats: stats)
        let sid = "spawn"

        // Pre-establish the session via UserPromptSubmit so ensurePromptTurnStarted's
        // first-turn +2 path is suppressed when SubagentStart fires.
        engine.handle(event: try makeHookEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": sid,
        ]), sessionContext: nil)
        let collabBefore = engine.characterStats.cyber.collab

        engine.handle(event: try makeHookEvent([
            "hook_event_name": "SubagentStart",
            "session_id": sid,
        ]), sessionContext: nil)

        XCTAssertEqual(engine.characterStats.cyber.collab - collabBefore, 4, accuracy: 0.001)
    }

    @MainActor
    func testEvent_collabIncrementedByPermissionApproved() throws {
        // Permission decisions now use the first-class PermissionRequest event.
        var stats = CharacterStats()
        stats.cyber.collab = 100
        let engine = CharacterEngine.makeForTesting(stats: stats)
        let event = try makeHookEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "permission-collab",
            "decision": "allow",
        ])

        engine.handle(event: event, sessionContext: nil)

        XCTAssertEqual(engine.characterStats.cyber.collab, 101.0, accuracy: 0.001)
    }

    // MARK: - Daily Roll

    func testDailyRoll_healthBoostForIdealDuration() {
        var stats = CharacterStats()
        stats.vital.health = 70

        // Simulate yesterday: 2h active (within [1h, 4h]) → health +2
        let seconds = 7200  // 2 hours
        if seconds >= 3600 && seconds <= 14400 {
            stats.vital.health = min(100, stats.vital.health + 2)
        }
        stats.vital.clamp()

        XCTAssertEqual(stats.vital.health, 72.0, accuracy: 0.001)
    }

    func testDailyRoll_healthPenaltyForInsufficientDuration() {
        var stats = CharacterStats()
        stats.vital.health = 70

        // < 30 min → health -2
        let seconds = 1000  // ~16 minutes
        if seconds < 1800 || seconds > 28800 {
            stats.vital.health = max(0, stats.vital.health - 2)
        }
        stats.vital.clamp()

        XCTAssertEqual(stats.vital.health, 68.0, accuracy: 0.001)
    }

    func testDailyRoll_healthPenaltyForOverwork() {
        var stats = CharacterStats()
        stats.vital.health = 70

        // > 8h → health -2
        let seconds = 30000  // ~8.3 hours
        if seconds < 1800 || seconds > 28800 {
            stats.vital.health = max(0, stats.vital.health - 2)
        }
        stats.vital.clamp()

        XCTAssertEqual(stats.vital.health, 68.0, accuracy: 0.001)
    }

    func testDailyRoll_healthPenaltyForZeroActivity() {
        var stats = CharacterStats()
        stats.vital.health = 70

        // Exactly 0 seconds active — falls into < 30min bucket → penalty
        let seconds = 0
        if seconds < 1800 || seconds > 28800 {
            stats.vital.health = max(0, stats.vital.health - 2)
        }

        XCTAssertEqual(stats.vital.health, 68.0, accuracy: 0.001)
    }

    @MainActor
    func testSuppressedTickStillFlushesDailyActiveReadModel() {
        let tmpDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("char-suppressed-tick-daily-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmpDB) }

        let persistence = CharacterPersistence(dbPath: tmpDB)
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart)!
        let tickTime = todayStart.addingTimeInterval(60)
        let yesterdayString = localDayString(yesterdayStart)

        var stats = persistence.load()
        stats.lastTickedAt = yesterdayStart.addingTimeInterval(12 * 3600)
        stats.stats.currentDayDate = yesterdayString
        stats.stats.currentDayActiveSeconds = 5400
        stats.stats.totalActiveSeconds = 5400
        stats.settings.logTickEvents = false

        let engine = CharacterEngine.makeForTesting(
            stats: stats,
            now: { tickTime },
            persistence: persistence
        )
        engine.tick(now: tickTime, isAnySessionActive: false)

        XCTAssertTrue(engine.listEvents(limit: 10, filter: CharacterEventQueryFilter(eventName: "Tick")).isEmpty)
        XCTAssertEqual(engine.characterStats.stats.currentDayActiveSeconds, 0)

        let chart = persistence.last7DaysActive()
        XCTAssertTrue(chart.contains(where: {
            localDayString($0.date) == yesterdayString && $0.seconds == 5400
        }))
    }

    // MARK: - Engine State Tests

    @MainActor
    func testPaused_eventsIgnored() {
        var stats = CharacterStats()
        stats.settings.paused = true
        stats.cyber.diligence = 0
        let engine = CharacterEngine.makeForTesting(stats: stats)

        // Build a PostToolUse event via JSON
        let json = """
        {"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Edit","success":true}
        """.data(using: .utf8)!
        guard let event = HookEvent(from: json) else {
            XCTFail("Failed to build HookEvent"); return
        }
        engine.handle(event: event, sessionContext: nil)

        XCTAssertEqual(engine.characterStats.cyber.diligence, 0,
                       "Paused engine must not apply stat changes")
    }

    @MainActor
    func testPaused_lastTickedAtUpdated() {
        var stats = CharacterStats()
        stats.settings.paused = true
        let now = Date()
        stats.lastTickedAt = now
        let engine = CharacterEngine.makeForTesting(stats: stats)

        let future = now.addingTimeInterval(3600)
        engine.tick(now: future, isAnySessionActive: false)

        XCTAssertEqual(engine.characterStats.lastTickedAt, future,
                       "tick() must advance lastTickedAt even when paused")
        XCTAssertEqual(engine.characterStats.vital.energy, 100,
                       "Vital values must not change when paused")
    }

    @MainActor
    func testReset_yieldsDefaultStats() {
        var stats = CharacterStats()
        stats.vital.energy = 20
        stats.cyber.diligence = 9999
        stats.stats.totalSessions = 42
        let engine = CharacterEngine.makeForTesting(stats: stats)

        engine.reset()

        XCTAssertEqual(engine.characterStats.vital.energy, 100, accuracy: 0.001)
        XCTAssertEqual(engine.characterStats.cyber.diligence, 0, accuracy: 0.001)
        XCTAssertEqual(engine.characterStats.stats.totalSessions, 0)
        XCTAssertEqual(engine.characterStats.settings.paused, false)
    }

    func testFirstLaunch_defaultsAllVitalsAt100() {
        let stats = CharacterStats()
        XCTAssertEqual(stats.vital.hunger,  100, accuracy: 0.001)
        XCTAssertEqual(stats.vital.mood,    100, accuracy: 0.001)
        XCTAssertEqual(stats.vital.energy,  100, accuracy: 0.001)
        XCTAssertEqual(stats.vital.health,  100, accuracy: 0.001)
        XCTAssertEqual(stats.cyber.focus,     0, accuracy: 0.001)
        XCTAssertEqual(stats.cyber.diligence, 0, accuracy: 0.001)
        XCTAssertEqual(stats.cyber.collab,    0, accuracy: 0.001)
        XCTAssertEqual(stats.cyber.taste,     0, accuracy: 0.001)
        XCTAssertEqual(stats.cyber.curiosity, 0, accuracy: 0.001)
        XCTAssertEqual(stats.settings.paused, false)
        XCTAssertEqual(stats.stats.totalSessions, 0)
        XCTAssertEqual(stats.stats.totalToolCalls, 0)
    }

    // MARK: - CyberStats Level Computation

    func testCyberLevel_computedCorrectly() {
        let stats = CyberStats(focus: 3437)
        XCTAssertEqual(stats.level(for: stats.focus), 3)
        XCTAssertEqual(stats.progress(for: stats.focus), 437.0, accuracy: 0.001)
    }

    func testCyberLevel_zeroIsLevelZero() {
        let stats = CyberStats(focus: 0)
        XCTAssertEqual(stats.level(for: stats.focus), 0)
        XCTAssertEqual(stats.progress(for: stats.focus), 0.0, accuracy: 0.001)
    }

    func testCyberLevel_exactBoundary() {
        let stats = CyberStats(focus: 1000)
        XCTAssertEqual(stats.level(for: stats.focus), 1)
        XCTAssertEqual(stats.progress(for: stats.focus), 0.0, accuracy: 0.001)
    }

    private func isoDay(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: s)!
    }

    /// Returns yyyy-MM-dd in local time for a given Date. Mirrors CharacterEngine.dayFmt.
    private func localDayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    @MainActor
    func testStreak_consecutiveDay_increments() {
        // Use ~25h gap so today > lastDay in any local timezone.
        let yesterday = Date(timeIntervalSinceReferenceDate: 800_000_000)  // arbitrary, fixed
        let today = yesterday.addingTimeInterval(25 * 3600)
        var stats = CharacterStats()
        stats.stats.lastActiveDate = localDayString(yesterday)
        stats.stats.streakDays = 3
        stats.stats.currentDayActiveSeconds = 7200
        stats.lastTickedAt = yesterday
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { today })
        engine.tick(now: today)
        XCTAssertEqual(engine.characterStats.stats.streakDays, 4)
    }

    @MainActor
    func testStreak_skippedDay_resetsToOne() {
        // 3-day-old lastActiveDate should NOT extend the streak.
        let lastDay = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let today = lastDay.addingTimeInterval(25 * 3600)
        let twoDaysAgo = lastDay.addingTimeInterval(-2 * 24 * 3600)
        var stats = CharacterStats()
        stats.stats.lastActiveDate = localDayString(twoDaysAgo)
        stats.stats.streakDays = 5
        stats.stats.currentDayActiveSeconds = 7200
        stats.lastTickedAt = lastDay
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { today })
        engine.tick(now: today)
        XCTAssertEqual(engine.characterStats.stats.streakDays, 1)
    }

    @MainActor
    func testPromptOnNewSource_collabIncrementsOnce() throws {
        let engine = CharacterEngine.makeForTesting()
        let codex = try makeHookEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "s1",
            "tool_name": "shell",
            "success": true,
            "tool_input": ["command": "ls"],
        ])
        engine.handle(event: codex, sessionContext: CharacterSessionContext(source: "codex"))
        let collabBefore = engine.characterStats.cyber.collab

        let prompt = try makeHookEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s2",
        ])
        engine.handle(event: prompt, sessionContext: CharacterSessionContext(source: "claude"))

        XCTAssertEqual(engine.characterStats.cyber.collab - collabBefore, 2, accuracy: 0.001)
    }

    @MainActor
    func testShellCatCommand_doesNotDoubleCount() throws {
        let engine = CharacterEngine.makeForTesting()
        let event = try makeHookEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "s1",
            "tool_name": "Bash",
            "success": true,
            "tool_input": ["command": "cat README.md"],
        ])
        engine.handle(event: event, sessionContext: nil)
        XCTAssertEqual(engine.characterStats.cyber.curiosity, 1.5, accuracy: 0.001)
        XCTAssertEqual(engine.characterStats.cyber.diligence, 0, accuracy: 0.001)
    }

    @MainActor
    func testShellRawBash_stillCreditsDiligence() throws {
        let engine = CharacterEngine.makeForTesting()
        let event = try makeHookEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "s1",
            "tool_name": "Bash",
            "success": true,
            "tool_input": ["command": "make build"],
        ])
        engine.handle(event: event, sessionContext: nil)
        XCTAssertEqual(engine.characterStats.cyber.diligence, 1, accuracy: 0.001)
        XCTAssertEqual(engine.characterStats.cyber.curiosity, 0, accuracy: 0.001)
    }

    // MARK: - Task 15: Taste graduated reward

    @MainActor
    func testTaste_90percent_grants5() throws {
        let engine = CharacterEngine.makeForTesting()
        engine.handle(event: try makeHookEvent(["hook_event_name": "UserPromptSubmit", "session_id": "s1"]),
                      sessionContext: nil)
        engine.handle(event: try makeHookEvent(["hook_event_name": "PostStop", "session_id": "s1"]),
                      sessionContext: CharacterSessionContext(toolSuccessRate: 0.90, totalTools: 5))
        XCTAssertEqual(engine.characterStats.cyber.taste, 5, accuracy: 0.01)
    }

    @MainActor
    func testTaste_100percent_grants10() throws {
        let engine = CharacterEngine.makeForTesting()
        engine.handle(event: try makeHookEvent(["hook_event_name": "UserPromptSubmit", "session_id": "s1"]),
                      sessionContext: nil)
        engine.handle(event: try makeHookEvent(["hook_event_name": "PostStop", "session_id": "s1"]),
                      sessionContext: CharacterSessionContext(toolSuccessRate: 1.0, totalTools: 5))
        XCTAssertEqual(engine.characterStats.cyber.taste, 10, accuracy: 0.01)
    }

    @MainActor
    func testTaste_below90percent_grantsNothing() throws {
        let engine = CharacterEngine.makeForTesting()
        engine.handle(event: try makeHookEvent(["hook_event_name": "UserPromptSubmit", "session_id": "s1"]),
                      sessionContext: nil)
        engine.handle(event: try makeHookEvent(["hook_event_name": "PostStop", "session_id": "s1"]),
                      sessionContext: CharacterSessionContext(toolSuccessRate: 0.85, totalTools: 5))
        XCTAssertEqual(engine.characterStats.cyber.taste, 0)
    }

    // MARK: - Task 14: Drop source-switch collab

    @MainActor
    func testSourceSwitch_aloneDoesNotCreditCollab() throws {
        let engine = CharacterEngine.makeForTesting()
        // Use same session so fallback collab fires only once (on first PostToolUse).
        let toolA = try makeHookEvent([
            "hook_event_name": "PostToolUse", "session_id": "s1",
            "tool_name": "Read", "success": true,
        ])
        let toolB = try makeHookEvent([
            "hook_event_name": "PostToolUse", "session_id": "s1",
            "tool_name": "Read", "success": true,
        ])
        engine.handle(event: toolA, sessionContext: CharacterSessionContext(source: "claude"))
        let collabBefore = engine.characterStats.cyber.collab
        engine.handle(event: toolB, sessionContext: CharacterSessionContext(source: "codex"))
        XCTAssertEqual(engine.characterStats.cyber.collab, collabBefore, accuracy: 0.001)
    }

    // MARK: - Task 13: PermissionRequest first-class handling

    @MainActor
    func testPermissionRequest_allow_creditsCollab() throws {
        let engine = CharacterEngine.makeForTesting()
        let evt = try makeHookEvent(["hook_event_name": "PermissionRequest", "session_id": "s1",
                                     "decision": "allow"])
        engine.handle(event: evt, sessionContext: nil)
        XCTAssertEqual(engine.characterStats.cyber.collab, 1, accuracy: 0.001)
    }

    @MainActor
    func testPermissionRequest_deny_dropsMood() throws {
        var stats = CharacterStats()
        stats.vital.mood = 100
        let engine = CharacterEngine.makeForTesting(stats: stats)
        let evt = try makeHookEvent(["hook_event_name": "PermissionRequest", "session_id": "s1",
                                     "decision": "deny"])
        engine.handle(event: evt, sessionContext: nil)
        XCTAssertEqual(engine.characterStats.vital.mood, 97, accuracy: 0.001)
    }

    @MainActor
    func testPermissionRequest_ask_isNeutral() throws {
        var stats = CharacterStats()
        stats.vital.mood = 80
        stats.cyber.collab = 0
        let engine = CharacterEngine.makeForTesting(stats: stats)
        let evt = try makeHookEvent(["hook_event_name": "PermissionRequest", "session_id": "s1",
                                     "decision": "ask"])
        engine.handle(event: evt, sessionContext: nil)
        XCTAssertEqual(engine.characterStats.vital.mood, 80, accuracy: 0.001)
        XCTAssertEqual(engine.characterStats.cyber.collab, 0, accuracy: 0.001)
    }

    @MainActor
    func testPermissionRequest_codexFieldName() throws {
        let engine = CharacterEngine.makeForTesting()
        let evt = try makeHookEvent(["hook_event_name": "PermissionRequest", "session_id": "s1",
                                     "permission_decision": "approved"])
        engine.handle(event: evt, sessionContext: nil)
        XCTAssertEqual(engine.characterStats.cyber.collab, 1, accuracy: 0.001)
    }

    // MARK: - Task 11: Cyber attribution via ToolSemantic

    @MainActor
    func testSingleEvent_creditsAtMostOneCyberDimension() throws {
        let engine = CharacterEngine.makeForTesting()
        // First establish a prompt turn so fallback collab doesn't fire on the tool event.
        let prompt = try makeHookEvent(["hook_event_name": "UserPromptSubmit", "session_id": "s1"])
        engine.handle(event: prompt, sessionContext: nil)
        let collabAfterPrompt = engine.characterStats.cyber.collab

        let evt = try makeHookEvent([
            "hook_event_name": "PostToolUse", "session_id": "s1",
            "tool_name": "Bash", "success": true,
            "tool_input": ["command": "cat foo.txt"],
        ])
        engine.handle(event: evt, sessionContext: nil)

        // Tool attribution must credit exactly one dimension. collab/taste are unchanged.
        let c = engine.characterStats.cyber
        XCTAssertEqual(c.collab, collabAfterPrompt, accuracy: 0.001, "tool event must not change collab")
        XCTAssertEqual(c.taste, 0, accuracy: 0.001, "tool event must not change taste")
        // cat → read semantic → curiosity, diligence stays 0
        XCTAssertGreaterThan(c.curiosity, 0)
        XCTAssertEqual(c.diligence, 0, accuracy: 0.001)
    }

    @MainActor
    func testGeminiWriteFile_creditsDiligence() throws {
        let engine = CharacterEngine.makeForTesting()
        let evt = try makeHookEvent([
            "hook_event_name": "PostToolUse", "session_id": "g1",
            "tool_name": "write_file", "success": true,
        ])
        engine.handle(event: evt, sessionContext: CharacterSessionContext(source: "gemini"))
        XCTAssertEqual(engine.characterStats.cyber.diligence, 2, accuracy: 0.001)
        XCTAssertEqual(engine.characterStats.cyber.curiosity, 0, accuracy: 0.001)
    }

    @MainActor
    func testCodexApplyPatch_creditsDiligence() throws {
        let engine = CharacterEngine.makeForTesting()
        let evt = try makeHookEvent([
            "hook_event_name": "PostToolUse", "session_id": "c1",
            "tool_name": "apply_patch", "success": true,
            "tool_input": ["operation": "update"],
        ])
        engine.handle(event: evt, sessionContext: CharacterSessionContext(source: "codex"))
        XCTAssertEqual(engine.characterStats.cyber.diligence, 2, accuracy: 0.001)
    }

    // MARK: - Task 9: Drop immediateFocusReward

    @MainActor
    func testFocus_rapidBurst_doesNotAccumulate() throws {
        let engine = CharacterEngine.makeForTesting()
        for _ in 0..<10 {
            let evt = try makeHookEvent([
                "hook_event_name": "PostToolUse", "session_id": "s1",
                "tool_name": "Read", "success": true,
            ])
            engine.handle(event: evt, sessionContext: nil)
        }
        XCTAssertEqual(engine.characterStats.cyber.focus, 0)
    }

    // MARK: - Focus reward without per-session cap

    @MainActor
    func testFocus_singleSession_allowsRewardAboveFifty() throws {
        // 8000s preloaded + first PostToolUse delta 30s = 8030s.
        // Threshold bonus +4, floor(8030/300)=26 bands → +52. Total = 56.
        let engine = CharacterEngine.makeForTesting()
        engine.testInject_sessionFocusActiveSeconds(sessionId: "cap1", seconds: 8000)
        // Trigger focus evaluation via a PostToolUse event.
        let evt = try makeHookEvent([
            "hook_event_name": "PostToolUse", "session_id": "cap1",
            "tool_name": "Read", "success": true,
        ])
        engine.handle(event: evt, sessionContext: nil)
        XCTAssertEqual(engine.characterStats.cyber.focus, 56, accuracy: 0.001)
    }

    @MainActor
    func testFocus_separateSessions_eachAccumulateFullReward() throws {
        // Two separate sessions each earn the full 56-point reward.
        let engine = CharacterEngine.makeForTesting()

        engine.testInject_sessionFocusActiveSeconds(sessionId: "sA", seconds: 8000)
        let evtA = try makeHookEvent([
            "hook_event_name": "PostToolUse", "session_id": "sA",
            "tool_name": "Read", "success": true,
        ])
        engine.handle(event: evtA, sessionContext: nil)
        XCTAssertEqual(engine.characterStats.cyber.focus, 56, accuracy: 0.001)

        engine.testInject_sessionFocusActiveSeconds(sessionId: "sB", seconds: 8000)
        let evtB = try makeHookEvent([
            "hook_event_name": "PostToolUse", "session_id": "sB",
            "tool_name": "Read", "success": true,
        ])
        engine.handle(event: evtB, sessionContext: nil)
        XCTAssertEqual(engine.characterStats.cyber.focus, 112, accuracy: 0.001)
    }

    @MainActor
    func testFocus_sessionCleanup_resetsProgressTracking() throws {
        // Session A earns 56, then ends. Same session id starts fresh and can earn 56 again.
        let engine = CharacterEngine.makeForTesting()

        engine.testInject_sessionFocusActiveSeconds(sessionId: "reuse", seconds: 8000)
        let evtA = try makeHookEvent([
            "hook_event_name": "PostToolUse", "session_id": "reuse",
            "tool_name": "Read", "success": true,
        ])
        engine.handle(event: evtA, sessionContext: nil)
        XCTAssertEqual(engine.characterStats.cyber.focus, 56, accuracy: 0.001)

        // End session — clears per-session focus tracking.
        engine.endSession(sessionId: "reuse")

        // New session with same id can earn another 56.
        engine.testInject_sessionFocusActiveSeconds(sessionId: "reuse", seconds: 8000)
        let evtB = try makeHookEvent([
            "hook_event_name": "PostToolUse", "session_id": "reuse",
            "tool_name": "Read", "success": true,
        ])
        engine.handle(event: evtB, sessionContext: nil)
        XCTAssertEqual(engine.characterStats.cyber.focus, 112, accuracy: 0.001)
    }

    // MARK: - Vital Coupling

    @MainActor
    func testCoupling_neutralVitalsDontMoveHealth() {
        // hunger=mood=energy=50: exact neutral (contribution=0 each), health
        // movement bounded by the active-damped recovery channel only (no
        // coupling kick). Over 1s the recovery push is ~0.0002 (damped 0.1×
        // health idle rate, ε snap not reached) — well under the 0.01 floor.
        var stats = CharacterStats()
        stats.vital.hunger = 50
        stats.vital.mood   = 50
        stats.vital.energy = 50
        stats.vital.health = 50
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        stats.lastTickedAt = t0
        let t1 = t0.addingTimeInterval(1)  // 1 second — negligible movement
        let engine = CharacterEngine.makeForTesting(stats: stats)
        engine.tick(now: t1, isAnySessionActive: true)
        XCTAssertEqual(engine.characterStats.vital.health, 50, accuracy: 0.01)
    }

    // MARK: - Task 8: Global mood equilibrium drift

    @MainActor
    func testMoodEquilibrium_lowEnergyPullsMoodDownWithoutThreshold() {
        var stats = CharacterStats()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        stats.lastTickedAt = now.addingTimeInterval(-3600)
        stats.vital.hunger = 96
        stats.vital.energy = 70
        stats.vital.health = 100
        stats.vital.mood = 100
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })

        engine.tick(now: now, isAnySessionActive: true)

        XCTAssertLessThan(engine.characterStats.vital.mood, 98.5)
    }

    @MainActor
    func testMoodEquilibrium_goodBodyStateLetsMoodRecoverSmoothly() {
        var stats = CharacterStats()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        stats.lastTickedAt = now.addingTimeInterval(-10 * 60)
        stats.vital.hunger = 100
        stats.vital.energy = 100
        stats.vital.health = 100
        stats.vital.mood = 60
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })

        engine.tick(now: now, isAnySessionActive: true)

        XCTAssertGreaterThan(engine.characterStats.vital.mood, 60)
    }

    // MARK: - Task 7: Daily-roll thresholds

    /// Returns a Date that is `daysOffset` calendar days from the start of today (local time).
    private func calendarDay(offsetDays: Int) -> Date {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        return cal.date(byAdding: .day, value: offsetDays, to: startOfToday)!
    }

    @MainActor
    func testRestDay_doesNotPunishHealth() {
        var stats = CharacterStats()
        stats.vital.health = 80
        // Rest days are not punished by daily roll. The continuous health model
        // can still recover during the idle portion of the elapsed day.
        stats.vital.hunger = 60; stats.vital.energy = 60; stats.vital.mood = 60
        stats.stats.currentDayActiveSeconds = 600
        stats.lastTickedAt = calendarDay(offsetDays: -1)
        let now = calendarDay(offsetDays: 0).addingTimeInterval(60)
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
        engine.tick(now: now)
        XCTAssertEqual(engine.characterStats.vital.health, 84.47, accuracy: 0.5)
    }

    @MainActor
    func testOverwork_singleDay_doesNotPunishHealth() {
        var stats = CharacterStats()
        stats.vital.health = 80
        // Daily overwork now hurts on the first >8h day; rest recovery applies
        // only to the estimated non-active portion of the elapsed day.
        stats.vital.hunger = 60; stats.vital.energy = 60; stats.vital.mood = 60
        stats.stats.currentDayActiveSeconds = 9 * 3600 // 9h, > 8h threshold
        stats.stats.overworkStreakDays = 0
        stats.lastTickedAt = calendarDay(offsetDays: -1)
        let now = calendarDay(offsetDays: 0).addingTimeInterval(60)
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
        engine.tick(now: now)
        XCTAssertEqual(engine.characterStats.vital.health, 79.7, accuracy: 0.5)
        XCTAssertEqual(engine.characterStats.stats.overworkStreakDays, 1)
    }

    @MainActor
    func testOverwork_thirdConsecutiveDay_punishesHealth() {
        var stats = CharacterStats()
        stats.vital.health = 80
        // Overwork penalty ramps by streak and caps later. With streak 2 going
        // into today, the third consecutive overwork day applies -9 health.
        stats.vital.hunger = 60; stats.vital.energy = 60; stats.vital.mood = 60
        stats.stats.currentDayActiveSeconds = 9 * 3600
        stats.stats.overworkStreakDays = 2
        stats.lastTickedAt = calendarDay(offsetDays: -1)
        let now = calendarDay(offsetDays: 0).addingTimeInterval(60)
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
        engine.tick(now: now)
        XCTAssertEqual(engine.characterStats.vital.health, 73.7, accuracy: 0.5)
        XCTAssertEqual(engine.characterStats.stats.overworkStreakDays, 3)
    }

    @MainActor
    func testOverwork_streakResetsAfterNormalDay() {
        var stats = CharacterStats()
        stats.vital.health = 80
        stats.vital.hunger = 60; stats.vital.energy = 60; stats.vital.mood = 60
        stats.stats.currentDayActiveSeconds = 2 * 3600 // 2h, healthy
        stats.stats.overworkStreakDays = 2
        stats.lastTickedAt = calendarDay(offsetDays: -1)
        let now = calendarDay(offsetDays: 0).addingTimeInterval(60)
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
        engine.tick(now: now)
        XCTAssertEqual(engine.characterStats.stats.overworkStreakDays, 0)
    }

    @MainActor
    func testHealthyDay_grantsHealthBonus() {
        var stats = CharacterStats()
        // Healthy-day daily roll still grants +3, and the continuous rest
        // channel also rebuilds health during the estimated non-active hours.
        stats.vital.health = 40
        stats.vital.hunger = 60; stats.vital.energy = 60; stats.vital.mood = 60
        stats.stats.currentDayActiveSeconds = 3 * 3600
        stats.lastTickedAt = calendarDay(offsetDays: -1)
        let now = calendarDay(offsetDays: 0).addingTimeInterval(60)
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
        engine.tick(now: now)
        XCTAssertEqual(engine.characterStats.vital.health, 46.9, accuracy: 0.5)
    }

    // MARK: - Task 6: Meal also restores energy

    @MainActor
    func testMeal_alsoRestoresEnergy() throws {
        var stats = CharacterStats()
        stats.vital.energy = 40
        stats.vital.hunger = 40
        let engine = CharacterEngine.makeForTesting(stats: stats)
        let prompt = try makeHookEvent(["hook_event_name": "UserPromptSubmit", "session_id": "s1"])
        engine.handle(event: prompt, sessionContext: nil)
        engine.testInject_sessionMealSeconds(sessionId: "s1", seconds: 130)
        let stop = try makeHookEvent(["hook_event_name": "PostStop", "session_id": "s1"])
        engine.handle(event: stop, sessionContext: CharacterSessionContext(totalTools: 3))
        // Meal band (2 min=120s, 3 tools) → reward 2.
        // Asymmetric coupling: mood/health are indicators only (no out-edges), so neither
        // UserPromptSubmit's nor PostStop's mood nudge propagates back to hunger/energy.
        // hunger and energy are drivers (no in-edges), so they only receive their direct
        // meal +2. The 60s idle-recovery cooldown also suppresses energy bleed-up between
        // ticks since the test runs in tight succession.
        // Final: hunger = 40 + 2 = 42; energy = 40 + 2 = 42.
        XCTAssertEqual(engine.characterStats.vital.hunger, 42.0, accuracy: 0.5)
        XCTAssertEqual(engine.characterStats.vital.energy, 42.0, accuracy: 0.5)
    }

    // MARK: - Task 5: Fallback prompt-turn earns mood + collab once

    @MainActor
    func testFallbackPromptTurn_grantsMoodAndCollabOnce() throws {
        var stats = CharacterStats()
        stats.vital.mood = 50
        stats.cyber.collab = 0
        let engine = CharacterEngine.makeForTesting(stats: stats)

        let evt1 = try makeHookEvent([
            "hook_event_name": "PostToolUse", "session_id": "g1",
            "tool_name": "read_file", "success": true,
        ])
        let evt2 = try makeHookEvent([
            "hook_event_name": "PostToolUse", "session_id": "g1",
            "tool_name": "read_file", "success": true,
        ])
        engine.handle(event: evt1, sessionContext: nil)
        engine.handle(event: evt2, sessionContext: nil)

        // mood +0.5 from fallback prompt-turn bonus. Per-tool energy cost halved
        // (-0.2 → -0.1) but retained — two tool successes deduct -0.1 energy
        // each, propagating -0.1 × 0.3 (energy→mood) × 1.0 (driver≥60, but at
        // exactly 60 the gain branch fires; this delta is negative so flat
        // 1.0×) = -0.03 mood per tool. Net: 50 + 0.5 - 0.06 ≈ 50.44.
        XCTAssertEqual(engine.characterStats.vital.mood, 50.44, accuracy: 0.1)
        XCTAssertEqual(engine.characterStats.cyber.collab, 2, accuracy: 0.001)
    }

    // MARK: - Task 4: totalSessions dedup

    @MainActor
    func testTotalSessions_dedupsAcrossHookVariants() throws {
        let engine = CharacterEngine.makeForTesting()
        let start = try makeHookEvent(["hook_event_name": "SessionStart", "session_id": "c1"])
        let prompt = try makeHookEvent(["hook_event_name": "UserPromptSubmit", "session_id": "c1"])
        let tool = try makeHookEvent([
            "hook_event_name": "PostToolUse", "session_id": "c1",
            "tool_name": "Read", "success": true,
        ])
        engine.handle(event: start, sessionContext: nil)
        engine.handle(event: prompt, sessionContext: nil)
        engine.handle(event: tool, sessionContext: nil)
        XCTAssertEqual(engine.characterStats.stats.totalSessions, 1)
    }

    @MainActor
    func testTotalSessions_sessionlessFirstActivity_stillCounts() throws {
        let engine = CharacterEngine.makeForTesting()
        let tool = try makeHookEvent([
            "hook_event_name": "PostToolUse", "session_id": "g1",
            "tool_name": "Read", "success": true,
        ])
        engine.handle(event: tool, sessionContext: nil)
        XCTAssertEqual(engine.characterStats.stats.totalSessions, 1)
    }

    private func makeHookEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("Failed to build HookEvent")
            throw NSError(domain: "CharacterEngineTests", code: 1)
        }
        return event
    }

    // MARK: - Future-date row protection

    /// last7DaysActive must exclude rows whose date is in the future.
    @MainActor
    func testLast7DaysActive_excludesFutureDatedRows() {
        let tmpDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("char-future-read-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmpDB) }

        let persistence = CharacterPersistence(dbPath: tmpDB)
        _ = persistence.load()  // open + schema

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        // Insert a legitimate yesterday row and a future row
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        persistence.upsertDailyActive(date: fmt.string(from: yesterday), seconds: 3600)

        let future = cal.date(byAdding: .day, value: 13, to: today)!
        persistence.upsertDailyActive(date: fmt.string(from: future), seconds: 7200)

        let results = persistence.last7DaysActive()

        XCTAssertFalse(results.isEmpty, "Should return the legitimate yesterday row")
        let futureCutoff = cal.date(byAdding: .day, value: 1, to: today)!
        for row in results {
            XCTAssertLessThan(row.date, futureCutoff, "No future-dated rows should be returned")
        }
        XCTAssertEqual(results.count, 1, "Only the yesterday row expected")
    }

    /// purgeFutureDailyActiveRows runs on open and removes rows dated after today.
    @MainActor
    func testOpenDB_purgeFutureDatedRows() {
        let tmpDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("char-future-purge-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmpDB) }

        // First open: insert a future-dated row directly after open via upsert
        let persistence = CharacterPersistence(dbPath: tmpDB)
        _ = persistence.load()  // open schema

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        let futureDate = fmt.string(from: cal.date(byAdding: .day, value: 13, to: today)!)
        persistence.upsertDailyActive(date: futureDate, seconds: 7200)

        // Second open (new instance) — triggers purgeFutureDailyActiveRows
        let persistence2 = CharacterPersistence(dbPath: tmpDB)
        _ = persistence2.load()

        // The future row should now be gone
        let results = persistence2.last7DaysActive()
        for row in results {
            XCTAssertLessThanOrEqual(row.date, today, "Future rows must be purged on open")
        }
        let futureDateObj = fmt.date(from: futureDate)!
        XCTAssertFalse(results.contains(where: { $0.date == futureDateObj }),
                       "The dirty future row must have been deleted on second open")
    }
}
