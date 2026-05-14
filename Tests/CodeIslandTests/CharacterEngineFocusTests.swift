import XCTest
@testable import CodeIslandCore

@MainActor
final class CharacterEngineFocusTests: XCTestCase {
    func testPromptSamplingDoesNotGrantFocus() throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var stats = CharacterStats()
        stats.lastTickedAt = now
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })

        engine.handle(
            event: try makeHookEvent(name: "UserPromptSubmit", sessionId: "s1"),
            sessionContext: CharacterSessionContext(hasActiveSession: true)
        )

        now = now.addingTimeInterval(8 * 3600)
        engine.sampleActivePromptTime(runningSessionIds: ["s1"], now: now)

        XCTAssertEqual(engine.characterStats.cyber.focus, 0, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(engine.characterStats.stats.totalActiveSeconds, 8 * 3600)
    }

    func testLongToolRuntimeIsCappedForFocus() throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var stats = CharacterStats()
        stats.lastTickedAt = now
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })

        engine.handle(
            event: try makeHookEvent(
                name: "PreToolUse",
                sessionId: "s1",
                toolName: "Bash",
                toolUseId: "toolu_long",
                toolInput: ["command": "swift test"]
            ),
            sessionContext: CharacterSessionContext(source: "codex", hasActiveSession: true)
        )

        now = now.addingTimeInterval(8 * 3600)
        engine.handle(
            event: try makeHookEvent(
                name: "PostToolUse",
                sessionId: "s1",
                toolName: "Bash",
                toolUseId: "toolu_long",
                toolInput: ["command": "swift test"]
            ),
            sessionContext: CharacterSessionContext(source: "codex", hasActiveSession: true)
        )

        XCTAssertEqual(engine.characterStats.cyber.focus, 0, accuracy: 0.000_001)
    }

    func testFocusCreditsCappedToolRuntimeAndShortGaps() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var now = base
        var stats = CharacterStats()
        stats.lastTickedAt = now
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })

        for index in 0..<6 {
            now = base.addingTimeInterval(TimeInterval(index * 120))
            engine.handle(
                event: try makeHookEvent(
                    name: "PreToolUse",
                    sessionId: "s1",
                    toolName: "Bash",
                    toolUseId: "toolu_\(index)",
                    toolInput: ["command": "swift test"]
                ),
                sessionContext: CharacterSessionContext(source: "codex", hasActiveSession: true)
            )

            now = now.addingTimeInterval(90)
            engine.handle(
                event: try makeHookEvent(
                    name: "PostToolUse",
                    sessionId: "s1",
                    toolName: "Bash",
                    toolUseId: "toolu_\(index)",
                    toolInput: ["command": "swift test"]
                ),
                sessionContext: CharacterSessionContext(source: "codex", hasActiveSession: true)
            )
        }

        XCTAssertEqual(engine.characterStats.cyber.focus, 10, accuracy: 0.000_001)
    }

    func testContinuousFocusBonusRequiresThirtyMinutesOfEffectiveWork() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var now = base
        var stats = CharacterStats()
        stats.lastTickedAt = now
        let engine = CharacterEngine.makeForTesting(stats: stats, now: { now })

        for index in 0..<16 {
            now = base.addingTimeInterval(TimeInterval(index * 120))
            engine.handle(
                event: try makeHookEvent(
                    name: "PreToolUse",
                    sessionId: "s1",
                    toolName: "Bash",
                    toolUseId: "toolu_\(index)",
                    toolInput: ["command": "swift test"]
                ),
                sessionContext: CharacterSessionContext(source: "codex", hasActiveSession: true)
            )

            now = now.addingTimeInterval(90)
            engine.handle(
                event: try makeHookEvent(
                    name: "PostToolUse",
                    sessionId: "s1",
                    toolName: "Bash",
                    toolUseId: "toolu_\(index)",
                    toolInput: ["command": "swift test"]
                ),
                sessionContext: CharacterSessionContext(source: "codex", hasActiveSession: true)
            )
        }

        XCTAssertEqual(engine.characterStats.cyber.focus, 45, accuracy: 0.000_001)
    }

    private func makeHookEvent(
        name: String,
        sessionId: String,
        toolName: String? = nil,
        toolUseId: String? = nil,
        toolInput: [String: Any]? = nil
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": name,
            "session_id": sessionId
        ]
        if let toolName { payload["tool_name"] = toolName }
        if let toolUseId { payload["tool_use_id"] = toolUseId }
        if let toolInput { payload["tool_input"] = toolInput }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }
}
