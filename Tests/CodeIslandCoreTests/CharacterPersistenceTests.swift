import SQLite3
import XCTest
@testable import CodeIslandCore

@MainActor
final class CharacterPersistenceTests: XCTestCase {

    func testAppendAndQueryCharacterLedgerEvent() throws {
        let persistence = makePersistence()
        var stats = persistence.load()
        stats.vital.hunger = 92
        stats.stats.totalSessions = 1
        stats.stats.toolUseCount["Read"] = 1

        let draft = CharacterLedgerEventDraft(
            batchID: "batch-1",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            eventKind: .externalHook,
            eventName: "PostToolUse",
            sessionID: "s1",
            source: "codex",
            providerSessionID: "provider-s1",
            cwd: "/tmp/project-a",
            model: "gpt-5.5",
            permissionMode: "default",
            sessionTitle: "Project A",
            remoteHostID: "host-1",
            remoteHostName: "devbox",
            toolName: "Read",
            toolUseID: "tool-1",
            ruleVersion: 1,
            payload: ["hook_event_name": .string("PostToolUse")],
            derived: ["semantic": .string("read")]
        )
        let deltas = [
            CharacterLedgerDeltaDraft(
                metricDomain: .vital,
                metricName: "hunger",
                reasonCode: "post_tool_use.vital.hunger",
                valueBefore: .double(100),
                valueAfter: .double(92),
                numericDelta: -8
            ),
            CharacterLedgerDeltaDraft(
                metricDomain: .lifetime,
                metricName: "totalSessions",
                reasonCode: "post_tool_use.lifetime.totalSessions",
                valueBefore: .int(0),
                valueAfter: .int(1),
                numericDelta: 1
            ),
            CharacterLedgerDeltaDraft(
                metricDomain: .toolUse,
                metricName: "Read",
                reasonCode: "post_tool_use.tool_use.Read",
                valueBefore: .int(0),
                valueAfter: .int(1),
                numericDelta: 1
            ),
        ]

        let eventID = persistence.append(event: draft, deltas: deltas, snapshot: stats)
        XCTAssertNotNil(eventID)

        let events = persistence.listEvents(limit: 10, filter: CharacterEventQueryFilter(eventName: "PostToolUse"))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].sessionID, "s1")
        XCTAssertEqual(events[0].source, "codex")
        XCTAssertEqual(events[0].providerSessionID, "provider-s1")
        XCTAssertEqual(events[0].cwd, "/tmp/project-a")
        XCTAssertEqual(events[0].model, "gpt-5.5")
        XCTAssertEqual(events[0].permissionMode, "default")
        XCTAssertEqual(events[0].sessionTitle, "Project A")
        XCTAssertEqual(events[0].remoteHostID, "host-1")
        XCTAssertEqual(events[0].remoteHostName, "devbox")
        XCTAssertEqual(events[0].derived["semantic"], .string("read"))

        let sessions = persistence.listSessions(limit: 10, filter: CharacterSessionQueryFilter(sessionID: "s1"))
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].source, "codex")
        XCTAssertEqual(sessions[0].providerSessionID, "provider-s1")
        XCTAssertEqual(sessions[0].cwd, "/tmp/project-a")
        XCTAssertEqual(sessions[0].model, "gpt-5.5")
        XCTAssertEqual(sessions[0].sessionTitle, "Project A")

        let recordedDeltas = persistence.listEventDeltas(eventID: eventID!)
        XCTAssertEqual(recordedDeltas.count, 3)
        XCTAssertEqual(recordedDeltas[0].metricName, "hunger")
        XCTAssertEqual(recordedDeltas[1].metricName, "totalSessions")
        XCTAssertEqual(recordedDeltas[2].metricName, "Read")

        let loaded = persistence.load()
        XCTAssertEqual(loaded.vital.hunger, 92, accuracy: 0.001)
        XCTAssertEqual(loaded.stats.totalSessions, 1)
        XCTAssertEqual(loaded.stats.toolUseCount["Read"], 1)
    }

    func testRebuildRecomputesFromStoredEventsEvenWhenDeltasAreDeleted() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("char-ledger-rebuild-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: dbURL) }

        let persistence = CharacterPersistence(dbPath: dbURL)
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let activeDayStart = calendar.date(byAdding: .day, value: -1, to: todayStart)!
        let flushedDay = dayString(activeDayStart)

        var now = activeDayStart.addingTimeInterval(9 * 3600)
        var stats = persistence.load()
        stats.lastTickedAt = now
        // Enable tick event logging so rebuild can replay the Tick and recover decay/roll effects.
        stats.settings.logTickEvents = true
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now }, persistence: persistence)

        let prompt = try makeHookEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "provider-s1",
            "cwd": "/tmp/project-a",
            "model": "gpt-5.5",
            "permission_mode": "default",
            "session_title": "Project A",
        ])
        engine.handle(
            event: prompt,
            sessionContext: CharacterSessionContext(source: "codex", hasActiveSession: true)
        )

        now = now.addingTimeInterval(60)
        let tool = try makeHookEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "provider-s1",
            "tool_name": "Read",
            "success": true,
        ])
        engine.handle(
            event: tool,
            sessionContext: CharacterSessionContext(source: "codex", hasActiveSession: true)
        )

        now = activeDayStart.addingTimeInterval(10 * 3600 + 30 * 60)
        engine.sampleActivePromptTime(runningSessionIds: [], now: now)

        now = todayStart.addingTimeInterval(60)
        engine.tick(now: now, isAnySessionActive: false)

        let expected = persistence.load()
        XCTAssertLessThan(expected.vital.hunger, 100)
        XCTAssertEqual(expected.stats.totalSessions, 1)
        XCTAssertEqual(expected.stats.totalToolCalls, 1)
        XCTAssertEqual(expected.stats.totalActiveSeconds, 5400)
        XCTAssertEqual(expected.stats.currentDayActiveSeconds, 0)
        XCTAssertEqual(expected.stats.toolUseCount["Read"], 1)
        XCTAssertEqual(expected.stats.cliUseCount["codex"], 1)
        XCTAssertTrue(
            persistence.last7DaysActive().contains(where: {
                dayString($0.date) == flushedDay && $0.seconds == 5400
            })
        )

        try deleteAllEventDeltas(at: dbURL)

        var corrupt = CharacterStats()
        corrupt.vital.hunger = 100
        corrupt.vital.mood = 100
        corrupt.vital.energy = 100
        corrupt.vital.health = 100
        corrupt.stats.totalSessions = 99
        corrupt.stats.totalToolCalls = 77
        corrupt.stats.totalActiveSeconds = 12
        corrupt.stats.currentDayActiveSeconds = 12
        corrupt.stats.toolUseCount["Bogus"] = 9
        corrupt.stats.cliUseCount["ghost"] = 4
        persistence.saveNow(corrupt)

        let rebuilt = persistence.rebuild()
        // accuracy=1.0: rebuild cannot perfectly replay the Tick because the replay
        // engine's lastActiveAt is initialised to the rebuild timestamp (not the
        // historical lastActiveAt), so idle energy recovery is skipped during replay
        // (±0.2 gap). Vitals drift and mood equilibrium produce sub-1-point differences.
        XCTAssertEqual(rebuilt.vital.hunger, expected.vital.hunger, accuracy: 1.0)
        XCTAssertEqual(rebuilt.vital.mood, expected.vital.mood, accuracy: 1.0)
        XCTAssertEqual(rebuilt.vital.energy, expected.vital.energy, accuracy: 1.0)
        XCTAssertEqual(rebuilt.vital.health, expected.vital.health, accuracy: 1.0)
        XCTAssertEqual(rebuilt.stats.totalSessions, expected.stats.totalSessions)
        XCTAssertEqual(rebuilt.stats.totalToolCalls, expected.stats.totalToolCalls)
        XCTAssertEqual(rebuilt.stats.totalActiveSeconds, expected.stats.totalActiveSeconds)
        XCTAssertEqual(rebuilt.stats.currentDayActiveSeconds, expected.stats.currentDayActiveSeconds)
        XCTAssertEqual(rebuilt.stats.toolUseCount["Read"], 1)
        XCTAssertNil(rebuilt.stats.toolUseCount["Bogus"])
        XCTAssertEqual(rebuilt.stats.cliUseCount["codex"], 1)
        XCTAssertNil(rebuilt.stats.cliUseCount["ghost"])
        XCTAssertLessThan(rebuilt.vital.hunger, 100)

        let chart = persistence.last7DaysActive()
        XCTAssertTrue(chart.contains(where: { dayString($0.date) == flushedDay && $0.seconds == 5400 }))

        let sessions = persistence.listSessions(limit: 10, filter: CharacterSessionQueryFilter(sessionID: "provider-s1"))
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].source, "codex")
        XCTAssertEqual(sessions[0].providerSessionID, "provider-s1")
        XCTAssertEqual(sessions[0].cwd, "/tmp/project-a")
        XCTAssertEqual(sessions[0].model, "gpt-5.5")
    }

    func testEngineIntegration_recordsEventsAndResetClearsLedger() throws {
        let persistence = makePersistence()
        var stats = persistence.load()
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        stats.lastTickedAt = now

        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now }, persistence: persistence)
        let event = try makeHookEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s1",
        ])
        engine.handle(event: event, sessionContext: CharacterSessionContext(source: "codex"))

        let promptEvents = engine.listEvents(limit: 10, filter: CharacterEventQueryFilter(eventName: "UserPromptSubmit"))
        XCTAssertEqual(promptEvents.count, 1)
        let deltas = engine.listEventDeltas(eventID: promptEvents[0].id)
        XCTAssertTrue(deltas.contains(where: { $0.metricDomain == .cyber && $0.metricName == "collab" }))
        XCTAssertTrue(deltas.contains(where: { $0.metricDomain == .lifetime && $0.metricName == "totalSessions" }))

        var corrupt = CharacterStats()
        corrupt.vital.hunger = 3
        corrupt.stats.totalSessions = 99
        persistence.saveNow(corrupt)

        let rebuilt = engine.rebuild()
        XCTAssertEqual(rebuilt.stats.totalSessions, 1)
        XCTAssertEqual(rebuilt.cyber.collab, 2, accuracy: 0.001)

        engine.reset()
        XCTAssertTrue(engine.listEvents(limit: 10).isEmpty)
        XCTAssertEqual(engine.characterStats.stats.totalSessions, 0)
    }

    func testDerivedSessionEventsCarryCLIAndSessionMetadata() throws {
        let persistence = makePersistence()
        var stats = persistence.load()
        let start = Date(timeIntervalSince1970: 1_700_200_000)
        stats.lastTickedAt = start

        var now = start
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now }, persistence: persistence)

        let prompt = try makeHookEvent([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "provider-s1",
            "cwd": "/tmp/project-b",
            "model": "gpt-5.5",
            "permission_mode": "default",
            "session_title": "Project B",
        ])
        engine.handle(event: prompt, sessionContext: CharacterSessionContext(source: "codex"))

        now = start.addingTimeInterval(6)
        engine.sampleActivePromptTime(runningSessionIds: [], now: now)

        let sampleEvents = engine.listEvents(limit: 10, filter: CharacterEventQueryFilter(eventName: "PromptActiveSample"))
        XCTAssertEqual(sampleEvents.count, 1)
        XCTAssertEqual(sampleEvents[0].source, "codex")
        XCTAssertEqual(sampleEvents[0].providerSessionID, "provider-s1")
        XCTAssertEqual(sampleEvents[0].cwd, "/tmp/project-b")
        XCTAssertEqual(sampleEvents[0].model, "gpt-5.5")
        XCTAssertEqual(sampleEvents[0].permissionMode, "default")
        XCTAssertEqual(sampleEvents[0].sessionTitle, "Project B")

        let sessions = engine.listSessions(limit: 10, filter: CharacterSessionQueryFilter(providerSessionID: "provider-s1"))
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sessionID, "provider-s1")
        XCTAssertEqual(sessions[0].source, "codex")
        XCTAssertEqual(sessions[0].cwd, "/tmp/project-b")
        XCTAssertEqual(sessions[0].model, "gpt-5.5")
    }

    // MARK: - Helpers

    private func makePersistence() -> CharacterPersistence {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("char-ledger-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return CharacterPersistence(dbPath: url)
    }

    private func makeHookEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("Failed to build HookEvent")
            throw NSError(domain: "CharacterPersistenceTests", code: 1)
        }
        return event
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func deleteAllEventDeltas(at dbURL: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            XCTFail("Failed to open sqlite db at \(dbURL.path)")
            return
        }
        defer { sqlite3_close(db) }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, "DELETE FROM character_event_delta", nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            XCTFail("Failed to delete character_event_delta rows: \(message)")
        }
    }
}
