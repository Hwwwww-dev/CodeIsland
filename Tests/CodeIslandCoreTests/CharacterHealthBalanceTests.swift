import XCTest
@testable import CodeIslandCore

final class CharacterHealthBalanceTests: XCTestCase {

    func testBodyScoreHealthDelta_smoothsThresholdEdges() {
        XCTAssertEqual(CharacterHealthBalance.bodyScoreHealthDeltaPerHour(30), 0, accuracy: 0.0001)
        XCTAssertEqual(CharacterHealthBalance.bodyScoreHealthDeltaPerHour(70), 0, accuracy: 0.0001)

        XCTAssertEqual(CharacterHealthBalance.bodyScoreHealthDeltaPerHour(25), -0.15, accuracy: 0.0001)
        XCTAssertEqual(CharacterHealthBalance.bodyScoreHealthDeltaPerHour(75), 0.1, accuracy: 0.0001)

        XCTAssertEqual(CharacterHealthBalance.bodyScoreHealthDeltaPerHour(20), -0.3, accuracy: 0.0001)
        XCTAssertEqual(CharacterHealthBalance.bodyScoreHealthDeltaPerHour(80), 0.2, accuracy: 0.0001)
    }

    @MainActor
    func testRestingWithStableBodyRecoversHealthWithoutDailyRollPenalty() {
        var stats = CharacterStats()
        let start = Self.fixedStart
        let now = start.addingTimeInterval(2 * 3600)
        stats.lastTickedAt = start
        stats.vital.health = 50
        stats.vital.hunger = 60
        stats.vital.energy = 60
        stats.vital.mood = 60

        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
        engine.tick(now: now, isAnySessionActive: false)

        XCTAssertGreaterThan(engine.characterStats.vital.health, 50.4)
        XCTAssertLessThan(engine.characterStats.vital.health, 50.7)
    }

    @MainActor
    func testActiveLowBodyScoreDrainsHealthSmoothly() {
        var stats = CharacterStats()
        let start = Self.fixedStart
        let now = start.addingTimeInterval(2 * 3600)
        stats.lastTickedAt = start
        stats.vital.health = 50
        stats.vital.hunger = 25
        stats.vital.energy = 25
        stats.vital.mood = 25

        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
        engine.tick(now: now, isAnySessionActive: true)

        XCTAssertLessThan(engine.characterStats.vital.health, 50)
        XCTAssertGreaterThan(engine.characterStats.vital.health, 49)
    }

    @MainActor
    func testContinuousPromptWorkPenalizesOnlyTimeBeyondTwoHours() throws {
        let twoHourHealth = try healthAfterContinuousPrompt(hours: 2)
        let threeHourHealth = try healthAfterContinuousPrompt(hours: 3)

        XCTAssertLessThan(threeHourHealth, twoHourHealth)
        XCTAssertGreaterThan(threeHourHealth, 79)
    }

    @MainActor
    func testDailyOverworkPenaltyRampsAndCaps() {
        var stats = CharacterStats()
        stats.lastTickedAt = Self.calendarDay(offsetDays: -1)
        stats.vital.health = 80
        stats.vital.hunger = 60
        stats.vital.energy = 60
        stats.vital.mood = 60
        stats.stats.currentDayActiveSeconds = 9 * 3600
        stats.stats.overworkStreakDays = 4

        let now = Self.calendarDay(offsetDays: 0).addingTimeInterval(60)
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })
        engine.tick(now: now)

        XCTAssertEqual(engine.characterStats.vital.health, 70.703, accuracy: 0.05)
        XCTAssertEqual(engine.characterStats.stats.overworkStreakDays, 5)
    }

    private static var fixedStart: Date {
        Date(timeIntervalSince1970: 1_700_000_000)
    }

    private static func calendarDay(offsetDays: Int) -> Date {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: fixedStart)
        return calendar.date(byAdding: .day, value: offsetDays, to: startOfToday)!
    }

    @MainActor
    private func healthAfterContinuousPrompt(hours: TimeInterval) throws -> Double {
        var stats = CharacterStats()
        stats.lastTickedAt = Self.fixedStart
        stats.vital.health = 80

        var current = Self.fixedStart
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { current })
        let prompt = try makeHookEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "continuous-health-\(hours)",
        ])
        engine.handle(event: prompt, sessionContext: nil)

        current = current.addingTimeInterval(hours * 3600)
        let stop = try makeHookEvent([
            "hook_event_name": "PostStop",
            "session_id": "continuous-health-\(hours)",
        ])
        engine.handle(event: stop, sessionContext: CharacterSessionContext(totalTools: 0))
        return engine.characterStats.vital.health
    }

    private func makeHookEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("Failed to build HookEvent")
            throw NSError(domain: "CharacterHealthBalanceTests", code: 1)
        }
        return event
    }
}
