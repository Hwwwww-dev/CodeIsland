import Foundation
import SQLite3
import os.log

private let log = Logger(subsystem: "com.codeisland", category: "CharacterPersistence")

@MainActor
public final class CharacterPersistence {

    public static let shared = CharacterPersistence()
    nonisolated public static let currentSchemaVersion = 3

    private let dbURL: URL
    private let legacyJSONURL: URL
    private var db: OpaquePointer?

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("CodeIsland", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("character.sqlite")
        legacyJSONURL = dir.appendingPathComponent("character.json")
    }

    init(dbPath: URL) {
        dbURL = dbPath
        legacyJSONURL = dbPath.deletingLastPathComponent().appendingPathComponent("character.json")
        try? FileManager.default.createDirectory(
            at: dbPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    // MARK: - Public API

    public func load() -> CharacterStats {
        openIfNeeded()
        if let loaded = readAll() {
            return loaded
        }

        let defaults = Self.defaultStats()
        writeSnapshot(defaults)
        return defaults
    }

    /// Compatibility shim. Event-ledger writes are immediate; there is no debounce now.
    public func scheduleSave(_ stats: CharacterStats) {
        saveNow(stats)
    }

    public func saveNow(_ stats: CharacterStats) {
        openIfNeeded()
        writeSnapshot(stats)
    }

    public func append(
        event draft: CharacterLedgerEventDraft,
        deltas: [CharacterLedgerDeltaDraft],
        snapshot stats: CharacterStats
    ) -> Int64? {
        openIfNeeded()
        guard beginImmediate() else { return nil }

        guard let eventID = insertEvent(draft) else {
            rollback()
            return nil
        }

        guard upsertSessionRecord(from: draft, eventID: eventID) else {
            rollback()
            return nil
        }

        for (index, delta) in deltas.enumerated() {
            guard insertDelta(delta, eventID: eventID, sequence: index) else {
                rollback()
                return nil
            }
        }

        guard writeSnapshotTables(stats, applyDailyActiveFrom: deltas) else {
            rollback()
            return nil
        }

        guard commit() else {
            rollback()
            return nil
        }

        return eventID
    }

    public func listEvents(
        limit: Int = 100,
        beforeEventID: Int64? = nil,
        filter: CharacterEventQueryFilter = CharacterEventQueryFilter()
    ) -> [CharacterLedgerEvent] {
        openIfNeeded()
        let limit = max(1, limit)
        var clauses: [String] = []
        var bindings: [SQLiteBindValue] = []

        if let beforeEventID {
            clauses.append("id < ?")
            bindings.append(.int(beforeEventID))
        }
        if let sessionID = filter.sessionID {
            clauses.append("session_id = ?")
            bindings.append(.text(sessionID))
        }
        if let eventKind = filter.eventKind {
            clauses.append("event_kind = ?")
            bindings.append(.text(eventKind.rawValue))
        }
        if let eventName = filter.eventName {
            clauses.append("event_name = ?")
            bindings.append(.text(eventName))
        }
        if let source = filter.source {
            clauses.append("source = ?")
            bindings.append(.text(source))
        }
        if let providerSessionID = filter.providerSessionID {
            clauses.append("provider_session_id = ?")
            bindings.append(.text(providerSessionID))
        }
        if let toolName = filter.toolName {
            clauses.append("tool_name = ?")
            bindings.append(.text(toolName))
        }
        if let startDate = filter.startDate {
            clauses.append("occurred_at >= ?")
            bindings.append(.real(startDate.timeIntervalSince1970))
        }
        if let endDate = filter.endDate {
            clauses.append("occurred_at <= ?")
            bindings.append(.real(endDate.timeIntervalSince1970))
        }

        var sql = """
            SELECT id, batch_id, occurred_at, recorded_at, event_kind, event_name,
                   session_id, source, provider_session_id, cwd, model,
                   permission_mode, session_title, remote_host_id, remote_host_name,
                   tool_name, tool_use_id, agent_id, rule_version, payload_json, derived_json
            FROM character_event
            """
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY id DESC LIMIT ?"
        bindings.append(.int(Int64(limit)))

        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindAll(stmt, values: bindings)

        var events: [CharacterLedgerEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let kindRaw = columnText(stmt, 4),
                  let kind = CharacterEventKind(rawValue: kindRaw) else { continue }
            let event = CharacterLedgerEvent(
                id: sqlite3_column_int64(stmt, 0),
                batchID: columnText(stmt, 1) ?? "",
                occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                recordedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                eventKind: kind,
                eventName: columnText(stmt, 5) ?? "",
                sessionID: columnText(stmt, 6),
                source: columnText(stmt, 7),
                providerSessionID: columnText(stmt, 8),
                cwd: columnText(stmt, 9),
                model: columnText(stmt, 10),
                permissionMode: columnText(stmt, 11),
                sessionTitle: columnText(stmt, 12),
                remoteHostID: columnText(stmt, 13),
                remoteHostName: columnText(stmt, 14),
                toolName: columnText(stmt, 15),
                toolUseID: columnText(stmt, 16),
                agentID: columnText(stmt, 17),
                ruleVersion: Int(sqlite3_column_int64(stmt, 18)),
                payload: CharacterLedgerJSON.decodeObject(columnText(stmt, 19)),
                derived: CharacterLedgerJSON.decodeObject(columnText(stmt, 20))
            )
            events.append(event)
        }
        return events
    }

    public func listEventDeltas(eventID: Int64) -> [CharacterLedgerDelta] {
        openIfNeeded()
        let sql = """
            SELECT id, event_id, sequence_in_event, metric_domain, metric_name,
                   reason_code, value_type, value_before, value_after, delta_numeric
            FROM character_event_delta
            WHERE event_id = ?
            ORDER BY sequence_in_event ASC, id ASC
            """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, int: eventID)

        var deltas: [CharacterLedgerDelta] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let domainRaw = columnText(stmt, 3),
                  let domain = CharacterMetricDomain(rawValue: domainRaw),
                  let typeRaw = columnText(stmt, 6),
                  let valueType = CharacterMetricValueType(rawValue: typeRaw),
                  let beforeRaw = columnText(stmt, 7),
                  let afterRaw = columnText(stmt, 8),
                  let valueBefore = CharacterMetricValue.fromStorage(type: valueType, rawValue: beforeRaw),
                  let valueAfter = CharacterMetricValue.fromStorage(type: valueType, rawValue: afterRaw) else {
                continue
            }
            let delta = CharacterLedgerDelta(
                id: sqlite3_column_int64(stmt, 0),
                eventID: sqlite3_column_int64(stmt, 1),
                sequenceInEvent: Int(sqlite3_column_int64(stmt, 2)),
                metricDomain: domain,
                metricName: columnText(stmt, 4) ?? "",
                reasonCode: columnText(stmt, 5) ?? "",
                valueBefore: valueBefore,
                valueAfter: valueAfter,
                numericDelta: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 9)
            )
            deltas.append(delta)
        }
        return deltas
    }

    public func listEventsForSession(sessionID: String, limit: Int = 100) -> [CharacterLedgerEvent] {
        listEvents(limit: limit, filter: CharacterEventQueryFilter(sessionID: sessionID))
    }

    public func listSessions(
        limit: Int = 100,
        filter: CharacterSessionQueryFilter = CharacterSessionQueryFilter()
    ) -> [CharacterLedgerSession] {
        openIfNeeded()
        let limit = max(1, limit)
        var clauses: [String] = []
        var bindings: [SQLiteBindValue] = []

        if let sessionID = filter.sessionID {
            clauses.append("session_id = ?")
            bindings.append(.text(sessionID))
        }
        if let source = filter.source {
            clauses.append("source = ?")
            bindings.append(.text(source))
        }
        if let providerSessionID = filter.providerSessionID {
            clauses.append("provider_session_id = ?")
            bindings.append(.text(providerSessionID))
        }

        var sql = """
            SELECT session_id, source, provider_session_id, cwd, model, permission_mode,
                   session_title, remote_host_id, remote_host_name,
                   first_event_id, last_event_id, first_seen_at, last_seen_at
            FROM character_session
            """
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY last_seen_at DESC, session_id ASC LIMIT ?"
        bindings.append(.int(Int64(limit)))

        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindAll(stmt, values: bindings)

        var sessions: [CharacterLedgerSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let sessionID = columnText(stmt, 0) else { continue }
            sessions.append(CharacterLedgerSession(
                sessionID: sessionID,
                source: columnText(stmt, 1),
                providerSessionID: columnText(stmt, 2),
                cwd: columnText(stmt, 3),
                model: columnText(stmt, 4),
                permissionMode: columnText(stmt, 5),
                sessionTitle: columnText(stmt, 6),
                remoteHostID: columnText(stmt, 7),
                remoteHostName: columnText(stmt, 8),
                firstEventID: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 9),
                lastEventID: sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 10),
                firstSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11)),
                lastSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))
            ))
        }
        return sessions
    }

    public func listEventsInRange(
        start: Date,
        end: Date,
        kind: CharacterEventKind? = nil,
        limit: Int = 500
    ) -> [CharacterLedgerEvent] {
        listEvents(
            limit: limit,
            filter: CharacterEventQueryFilter(eventKind: kind, startDate: start, endDate: end)
        )
    }

    public func reset() {
        resetAllCharacterData()
    }

    public func resetAllCharacterData() {
        openIfNeeded()
        guard beginImmediate() else { return }
        guard clearAllTables() else {
            rollback()
            return
        }
        guard commit() else {
            rollback()
            return
        }
        writeSnapshot(Self.defaultStats())
        log.info("character.sqlite reset — ledger and read models cleared")
    }

    public func rebuild() -> CharacterStats {
        openIfNeeded()
        var rebuilt = Self.defaultStats()
        let sql = """
            SELECT id, batch_id, occurred_at, recorded_at, event_kind, event_name,
                   session_id, source, provider_session_id, cwd, model,
                   permission_mode, session_title, remote_host_id, remote_host_name,
                   tool_name, tool_use_id, agent_id, rule_version, payload_json, derived_json
            FROM character_event
            ORDER BY id ASC
            """
        guard let stmt = prepare(sql) else { return readAll() ?? rebuilt }
        defer { sqlite3_finalize(stmt) }

        let replayEngine = CharacterEngine.makeForTesting(
            stats: rebuilt,
            now: { Date(timeIntervalSince1970: 0) },
            persistence: nil
        )
        var dailyActiveRows: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let kindRaw = columnText(stmt, 4),
                  let kind = CharacterEventKind(rawValue: kindRaw) else {
                continue
            }

            let event = CharacterLedgerEvent(
                id: sqlite3_column_int64(stmt, 0),
                batchID: columnText(stmt, 1) ?? "",
                occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                recordedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                eventKind: kind,
                eventName: columnText(stmt, 5) ?? "",
                sessionID: columnText(stmt, 6),
                source: columnText(stmt, 7),
                providerSessionID: columnText(stmt, 8),
                cwd: columnText(stmt, 9),
                model: columnText(stmt, 10),
                permissionMode: columnText(stmt, 11),
                sessionTitle: columnText(stmt, 12),
                remoteHostID: columnText(stmt, 13),
                remoteHostName: columnText(stmt, 14),
                toolName: columnText(stmt, 15),
                toolUseID: columnText(stmt, 16),
                agentID: columnText(stmt, 17),
                ruleVersion: Int(sqlite3_column_int64(stmt, 18)),
                payload: CharacterLedgerJSON.decodeObject(columnText(stmt, 19)),
                derived: CharacterLedgerJSON.decodeObject(columnText(stmt, 20))
            )

            replayEngine.replay(event: event)

            if let flushedDate = ledgerString(event.derived["flushedDate"]),
               let rolledSeconds = ledgerInt(event.derived["rolledDaySeconds"]) {
                if rolledSeconds == 0 {
                    dailyActiveRows.removeValue(forKey: flushedDate)
                } else {
                    dailyActiveRows[flushedDate] = rolledSeconds
                }
            }
        }
        rebuilt = replayEngine.characterStats

        guard beginImmediate() else { return rebuilt }
        guard clearReadModelTables() else {
            rollback()
            return rebuilt
        }
        guard rebuildSessionRowsFromEvents() else {
            rollback()
            return rebuilt
        }
        guard writeSnapshotTables(rebuilt, dailyActiveRows: dailyActiveRows) else {
            rollback()
            return rebuilt
        }
        guard commit() else {
            rollback()
            return rebuilt
        }

        return rebuilt
    }

    /// Returns (date, activeSeconds) for the last 7 calendar days with non-zero activity,
    /// sorted by date ascending.
    public func last7DaysActive() -> [(date: Date, seconds: Int)] {
        openIfNeeded()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let cutoff = cal.date(byAdding: .day, value: -6, to: today) else { return [] }

        let cutoffStr = Self.dayFmt.string(from: cutoff)
        let todayStr = Self.dayFmt.string(from: today)
        let sql = """
            SELECT date, active_seconds FROM character_daily_active
            WHERE date >= ? AND date <= ? AND active_seconds > 0
            ORDER BY date ASC
            """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, text: cutoffStr)
        bind(stmt, 2, text: todayStr)

        var result: [(date: Date, seconds: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rawDate = columnText(stmt, 0),
                  let date = Self.dayFmt.date(from: rawDate) else { continue }
            result.append((date: date, seconds: Int(sqlite3_column_int64(stmt, 1))))
        }
        return result
    }

    public func upsertDailyActive(date: String, seconds: Int) {
        openIfNeeded()
        guard beginImmediate() else { return }
        let delta = CharacterLedgerDeltaDraft(
            metricDomain: .dailyActive,
            metricName: date,
            reasonCode: "manual.daily_active.\(date)",
            valueBefore: .int(currentDailyActiveSeconds(for: date)),
            valueAfter: .int(seconds),
            numericDelta: Double(seconds - currentDailyActiveSeconds(for: date))
        )
        guard applyDailyActiveDeltas([delta]), commit() else {
            rollback()
            return
        }
    }

    func currentDailyActiveSeconds(for date: String) -> Int {
        openIfNeeded()
        let sql = "SELECT active_seconds FROM character_daily_active WHERE date = ?"
        guard let stmt = prepare(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, text: date)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Open & Schema

    private func openIfNeeded() {
        guard db == nil else { return }
        let path = dbURL.path
        guard sqlite3_open_v2(
            path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            log.error("sqlite3_open failed")
            return
        }

        exec("PRAGMA foreign_keys = ON;")
        exec("PRAGMA journal_mode = WAL;")
        exec("PRAGMA synchronous = NORMAL;")
        applySchema()
        discardLegacyJSONIfPresent()
        performDestructiveResetIfNeeded()
        purgeFutureDailyActiveRows()
        log.info("character.sqlite opened at \(path)")
    }

    private func applySchema() {
        exec("""
            CREATE TABLE IF NOT EXISTS character_state (
                id                       INTEGER PRIMARY KEY CHECK (id = 1),
                schema_version           INTEGER NOT NULL DEFAULT 3,
                last_ticked_at           REAL    NOT NULL,
                paused                   INTEGER NOT NULL DEFAULT 0,
                vital_hunger             REAL    NOT NULL,
                vital_mood               REAL    NOT NULL,
                vital_energy             REAL    NOT NULL,
                vital_health             REAL    NOT NULL,
                cyber_focus              REAL    NOT NULL,
                cyber_diligence          REAL    NOT NULL,
                cyber_collab             REAL    NOT NULL,
                cyber_taste              REAL    NOT NULL,
                cyber_curiosity          REAL    NOT NULL,
                log_raw_hook_payloads    INTEGER NOT NULL DEFAULT 0,
                log_tick_events          INTEGER NOT NULL DEFAULT 0
            );
            """)
        // Idempotent ADD COLUMN for upgrades — schema_version is intentionally
        // NOT bumped because performDestructiveResetIfNeeded would wipe user
        // history. Existing-column check avoids spamming the log on every boot.
        let stateColumns = tableColumns("character_state")
        if !stateColumns.contains("log_raw_hook_payloads") {
            exec("ALTER TABLE character_state ADD COLUMN log_raw_hook_payloads INTEGER NOT NULL DEFAULT 0;")
        }
        if !stateColumns.contains("log_tick_events") {
            exec("ALTER TABLE character_state ADD COLUMN log_tick_events INTEGER NOT NULL DEFAULT 0;")
        }
        exec("""
            CREATE TABLE IF NOT EXISTS character_lifetime (
                id                          INTEGER PRIMARY KEY CHECK (id = 1),
                total_sessions              INTEGER NOT NULL DEFAULT 0,
                total_tool_calls            INTEGER NOT NULL DEFAULT 0,
                total_active_seconds        INTEGER NOT NULL DEFAULT 0,
                current_day_active_seconds  INTEGER NOT NULL DEFAULT 0,
                current_day_date            TEXT    NOT NULL,
                streak_days                 INTEGER NOT NULL DEFAULT 0,
                last_active_date            TEXT    NOT NULL,
                overwork_streak_days        INTEGER NOT NULL DEFAULT 0,
                last_full_restore_date      TEXT    NOT NULL DEFAULT ''
            );
            """)
        // Idempotent ADD COLUMN — same pattern as character_state, keeps
        // schema_version stable to avoid triggering destructive reset.
        let lifetimeColumns = tableColumns("character_lifetime")
        if !lifetimeColumns.contains("last_full_restore_date") {
            exec("ALTER TABLE character_lifetime ADD COLUMN last_full_restore_date TEXT NOT NULL DEFAULT '';")
        }
        exec("""
            CREATE TABLE IF NOT EXISTS character_tool_use (
                tool_name  TEXT    PRIMARY KEY,
                use_count  INTEGER NOT NULL DEFAULT 0
            );
            """)
        exec("""
            CREATE TABLE IF NOT EXISTS character_cli_use (
                cli_source TEXT    PRIMARY KEY,
                use_count  INTEGER NOT NULL DEFAULT 0
            );
            """)
        exec("""
            CREATE TABLE IF NOT EXISTS character_daily_active (
                date            TEXT    PRIMARY KEY,
                active_seconds  INTEGER NOT NULL DEFAULT 0
            );
            """)
        exec("""
            CREATE TABLE IF NOT EXISTS character_session (
                session_id           TEXT    PRIMARY KEY,
                source               TEXT,
                provider_session_id  TEXT,
                cwd                  TEXT,
                model                TEXT,
                permission_mode      TEXT,
                session_title        TEXT,
                remote_host_id       TEXT,
                remote_host_name     TEXT,
                first_event_id       INTEGER,
                last_event_id        INTEGER,
                first_seen_at        REAL    NOT NULL,
                last_seen_at         REAL    NOT NULL
            );
            """)
        exec("""
            CREATE TABLE IF NOT EXISTS character_event (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                batch_id      TEXT    NOT NULL,
                occurred_at   REAL    NOT NULL,
                recorded_at   REAL    NOT NULL,
                event_kind    TEXT    NOT NULL,
                event_name    TEXT    NOT NULL,
                session_id    TEXT,
                source        TEXT,
                provider_session_id TEXT,
                cwd           TEXT,
                model         TEXT,
                permission_mode TEXT,
                session_title TEXT,
                remote_host_id TEXT,
                remote_host_name TEXT,
                tool_name     TEXT,
                tool_use_id   TEXT,
                agent_id      TEXT,
                rule_version  INTEGER NOT NULL,
                payload_json  TEXT    NOT NULL,
                derived_json  TEXT    NOT NULL
            );
            """)
        exec("""
            CREATE TABLE IF NOT EXISTS character_event_delta (
                id                 INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id           INTEGER NOT NULL REFERENCES character_event(id) ON DELETE CASCADE,
                sequence_in_event  INTEGER NOT NULL,
                metric_domain      TEXT    NOT NULL,
                metric_name        TEXT    NOT NULL,
                reason_code        TEXT    NOT NULL,
                value_type         TEXT    NOT NULL,
                value_before       TEXT    NOT NULL,
                value_after        TEXT    NOT NULL,
                delta_numeric      REAL
            );
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_character_event_occurred_at ON character_event(occurred_at);")
        exec("CREATE INDEX IF NOT EXISTS idx_character_event_session_id ON character_event(session_id);")
        exec("CREATE INDEX IF NOT EXISTS idx_character_event_kind ON character_event(event_kind);")
        exec("CREATE INDEX IF NOT EXISTS idx_character_event_source ON character_event(source);")
        exec("CREATE INDEX IF NOT EXISTS idx_character_event_provider_session_id ON character_event(provider_session_id);")
        exec("CREATE INDEX IF NOT EXISTS idx_character_event_tool_name ON character_event(tool_name);")
        exec("CREATE INDEX IF NOT EXISTS idx_character_event_delta_event_id ON character_event_delta(event_id, sequence_in_event);")
        exec("CREATE INDEX IF NOT EXISTS idx_character_session_source ON character_session(source);")
        exec("CREATE INDEX IF NOT EXISTS idx_character_session_provider_session_id ON character_session(provider_session_id);")
        exec("CREATE INDEX IF NOT EXISTS idx_character_session_last_seen_at ON character_session(last_seen_at);")
    }

    private func discardLegacyJSONIfPresent() {
        let path = legacyJSONURL.path
        guard FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.removeItem(at: legacyJSONURL)
        log.info("Discarded legacy character.json during destructive upgrade path")
    }

    private func performDestructiveResetIfNeeded() {
        guard let schemaVersion = readSchemaVersion(),
              schemaVersion != Self.currentSchemaVersion else { return }
        log.info("Character schema version changed from \(schemaVersion) to \(Self.currentSchemaVersion); clearing legacy character data")
        guard beginImmediate() else { return }
        if dropAllTables(), commit() {
            applySchema()
            return
        }
        rollback()
    }

    private func readSchemaVersion() -> Int? {
        let sql = "SELECT schema_version FROM character_state WHERE id = 1"
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func purgeFutureDailyActiveRows() {
        let todayStr = Self.dayFmt.string(from: Calendar.current.startOfDay(for: Date()))
        let sql = "DELETE FROM character_daily_active WHERE date > ?"
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, text: todayStr)
        sqlite3_step(stmt)
    }

    // MARK: - Read

    private func readAll() -> CharacterStats? {
        let stateSQL = """
            SELECT last_ticked_at, paused,
                   vital_hunger, vital_mood, vital_energy, vital_health,
                   cyber_focus, cyber_diligence, cyber_collab, cyber_taste, cyber_curiosity,
                   log_raw_hook_payloads, log_tick_events
            FROM character_state
            WHERE id = 1
            """
        guard let stateStmt = prepare(stateSQL) else { return nil }
        defer { sqlite3_finalize(stateStmt) }
        guard sqlite3_step(stateStmt) == SQLITE_ROW else { return nil }

        var stats = Self.defaultStats()
        stats.lastTickedAt = Date(timeIntervalSince1970: sqlite3_column_double(stateStmt, 0))
        stats.settings.paused = sqlite3_column_int64(stateStmt, 1) != 0
        stats.vital.hunger = sqlite3_column_double(stateStmt, 2)
        stats.vital.mood = sqlite3_column_double(stateStmt, 3)
        stats.vital.energy = sqlite3_column_double(stateStmt, 4)
        stats.vital.health = sqlite3_column_double(stateStmt, 5)
        stats.cyber.focus = sqlite3_column_double(stateStmt, 6)
        stats.cyber.diligence = sqlite3_column_double(stateStmt, 7)
        stats.cyber.collab = sqlite3_column_double(stateStmt, 8)
        stats.cyber.taste = sqlite3_column_double(stateStmt, 9)
        stats.cyber.curiosity = sqlite3_column_double(stateStmt, 10)
        stats.settings.logRawHookPayloads = sqlite3_column_int64(stateStmt, 11) != 0
        stats.settings.logTickEvents = sqlite3_column_int64(stateStmt, 12) != 0

        let lifetimeSQL = """
            SELECT total_sessions, total_tool_calls, total_active_seconds,
                   current_day_active_seconds, current_day_date,
                   streak_days, last_active_date, overwork_streak_days,
                   last_full_restore_date
            FROM character_lifetime
            WHERE id = 1
            """
        if let lifeStmt = prepare(lifetimeSQL) {
            defer { sqlite3_finalize(lifeStmt) }
            if sqlite3_step(lifeStmt) == SQLITE_ROW {
                stats.stats.totalSessions = Int(sqlite3_column_int64(lifeStmt, 0))
                stats.stats.totalToolCalls = Int(sqlite3_column_int64(lifeStmt, 1))
                stats.stats.totalActiveSeconds = Int(sqlite3_column_int64(lifeStmt, 2))
                stats.stats.currentDayActiveSeconds = Int(sqlite3_column_int64(lifeStmt, 3))
                stats.stats.currentDayDate = columnText(lifeStmt, 4) ?? ""
                stats.stats.streakDays = Int(sqlite3_column_int64(lifeStmt, 5))
                stats.stats.lastActiveDate = columnText(lifeStmt, 6) ?? ""
                stats.stats.overworkStreakDays = Int(sqlite3_column_int64(lifeStmt, 7))
                stats.stats.lastFullRestoreDate = columnText(lifeStmt, 8) ?? ""
            }
        }

        if let toolStmt = prepare("SELECT tool_name, use_count FROM character_tool_use") {
            defer { sqlite3_finalize(toolStmt) }
            while sqlite3_step(toolStmt) == SQLITE_ROW {
                guard let name = columnText(toolStmt, 0) else { continue }
                stats.stats.toolUseCount[name] = Int(sqlite3_column_int64(toolStmt, 1))
            }
        }

        if let cliStmt = prepare("SELECT cli_source, use_count FROM character_cli_use") {
            defer { sqlite3_finalize(cliStmt) }
            while sqlite3_step(cliStmt) == SQLITE_ROW {
                guard let name = columnText(cliStmt, 0) else { continue }
                stats.stats.cliUseCount[name] = Int(sqlite3_column_int64(cliStmt, 1))
            }
        }

        return stats
    }

    // MARK: - Write

    private func writeSnapshot(_ stats: CharacterStats) {
        guard beginImmediate() else { return }
        guard writeSnapshotTables(stats) else {
            rollback()
            return
        }
        guard commit() else {
            rollback()
            return
        }
    }

    @discardableResult
    private func writeSnapshotTables(
        _ stats: CharacterStats,
        applyDailyActiveFrom deltas: [CharacterLedgerDeltaDraft] = [],
        dailyActiveRows: [String: Int]? = nil
    ) -> Bool {
        guard upsertCharacterState(stats),
              upsertLifetime(stats),
              replaceToolUseRows(stats.stats.toolUseCount),
              replaceCLIUseRows(stats.stats.cliUseCount) else {
            return false
        }

        if let dailyActiveRows {
            guard replaceDailyActiveRows(dailyActiveRows) else { return false }
        } else if !deltas.isEmpty {
            guard applyDailyActiveDeltas(deltas) else { return false }
        }

        return true
    }

    private func upsertCharacterState(_ stats: CharacterStats) -> Bool {
        let sql = """
            INSERT INTO character_state(
                id, schema_version, last_ticked_at, paused,
                vital_hunger, vital_mood, vital_energy, vital_health,
                cyber_focus, cyber_diligence, cyber_collab, cyber_taste, cyber_curiosity,
                log_raw_hook_payloads, log_tick_events
            ) VALUES(1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                schema_version = excluded.schema_version,
                last_ticked_at = excluded.last_ticked_at,
                paused = excluded.paused,
                vital_hunger = excluded.vital_hunger,
                vital_mood = excluded.vital_mood,
                vital_energy = excluded.vital_energy,
                vital_health = excluded.vital_health,
                cyber_focus = excluded.cyber_focus,
                cyber_diligence = excluded.cyber_diligence,
                cyber_collab = excluded.cyber_collab,
                cyber_taste = excluded.cyber_taste,
                cyber_curiosity = excluded.cyber_curiosity,
                log_raw_hook_payloads = excluded.log_raw_hook_payloads,
                log_tick_events = excluded.log_tick_events
            """
        guard let stmt = prepare(sql) else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, int: Int64(Self.currentSchemaVersion))
        bind(stmt, 2, real: stats.lastTickedAt.timeIntervalSince1970)
        bind(stmt, 3, int: stats.settings.paused ? 1 : 0)
        bind(stmt, 4, real: stats.vital.hunger)
        bind(stmt, 5, real: stats.vital.mood)
        bind(stmt, 6, real: stats.vital.energy)
        bind(stmt, 7, real: stats.vital.health)
        bind(stmt, 8, real: stats.cyber.focus)
        bind(stmt, 9, real: stats.cyber.diligence)
        bind(stmt, 10, real: stats.cyber.collab)
        bind(stmt, 11, real: stats.cyber.taste)
        bind(stmt, 12, real: stats.cyber.curiosity)
        bind(stmt, 13, int: stats.settings.logRawHookPayloads ? 1 : 0)
        bind(stmt, 14, int: stats.settings.logTickEvents ? 1 : 0)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func upsertLifetime(_ stats: CharacterStats) -> Bool {
        let sql = """
            INSERT INTO character_lifetime(
                id, total_sessions, total_tool_calls, total_active_seconds,
                current_day_active_seconds, current_day_date,
                streak_days, last_active_date, overwork_streak_days,
                last_full_restore_date
            ) VALUES(1, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                total_sessions = excluded.total_sessions,
                total_tool_calls = excluded.total_tool_calls,
                total_active_seconds = excluded.total_active_seconds,
                current_day_active_seconds = excluded.current_day_active_seconds,
                current_day_date = excluded.current_day_date,
                streak_days = excluded.streak_days,
                last_active_date = excluded.last_active_date,
                overwork_streak_days = excluded.overwork_streak_days,
                last_full_restore_date = excluded.last_full_restore_date
            """
        guard let stmt = prepare(sql) else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, int: Int64(stats.stats.totalSessions))
        bind(stmt, 2, int: Int64(stats.stats.totalToolCalls))
        bind(stmt, 3, int: Int64(stats.stats.totalActiveSeconds))
        bind(stmt, 4, int: Int64(stats.stats.currentDayActiveSeconds))
        bind(stmt, 5, text: stats.stats.currentDayDate)
        bind(stmt, 6, int: Int64(stats.stats.streakDays))
        bind(stmt, 7, text: stats.stats.lastActiveDate)
        bind(stmt, 8, int: Int64(stats.stats.overworkStreakDays))
        bind(stmt, 9, text: stats.stats.lastFullRestoreDate)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func replaceToolUseRows(_ rows: [String: Int]) -> Bool {
        guard exec("DELETE FROM character_tool_use") else { return false }
        let sql = "INSERT INTO character_tool_use(tool_name, use_count) VALUES(?, ?)"
        for (name, count) in rows {
            guard let stmt = prepare(sql) else { return false }
            bind(stmt, 1, text: name)
            bind(stmt, 2, int: Int64(count))
            let ok = sqlite3_step(stmt) == SQLITE_DONE
            sqlite3_finalize(stmt)
            guard ok else { return false }
        }
        return true
    }

    private func replaceCLIUseRows(_ rows: [String: Int]) -> Bool {
        guard exec("DELETE FROM character_cli_use") else { return false }
        let sql = "INSERT INTO character_cli_use(cli_source, use_count) VALUES(?, ?)"
        for (source, count) in rows {
            guard let stmt = prepare(sql) else { return false }
            bind(stmt, 1, text: source)
            bind(stmt, 2, int: Int64(count))
            let ok = sqlite3_step(stmt) == SQLITE_DONE
            sqlite3_finalize(stmt)
            guard ok else { return false }
        }
        return true
    }

    private func replaceDailyActiveRows(_ rows: [String: Int]) -> Bool {
        guard exec("DELETE FROM character_daily_active") else { return false }
        let sql = "INSERT INTO character_daily_active(date, active_seconds) VALUES(?, ?)"
        for (date, seconds) in rows {
            guard let stmt = prepare(sql) else { return false }
            bind(stmt, 1, text: date)
            bind(stmt, 2, int: Int64(seconds))
            let ok = sqlite3_step(stmt) == SQLITE_DONE
            sqlite3_finalize(stmt)
            guard ok else { return false }
        }
        return true
    }

    private func applyDailyActiveDeltas(_ deltas: [CharacterLedgerDeltaDraft]) -> Bool {
        let sql = """
            INSERT INTO character_daily_active(date, active_seconds) VALUES(?, ?)
            ON CONFLICT(date) DO UPDATE SET active_seconds = excluded.active_seconds
            """
        for delta in deltas where delta.metricDomain == .dailyActive {
            guard case .int(let seconds) = delta.valueAfter else { continue }
            guard let stmt = prepare(sql) else { return false }
            bind(stmt, 1, text: delta.metricName)
            bind(stmt, 2, int: Int64(seconds))
            let ok = sqlite3_step(stmt) == SQLITE_DONE
            sqlite3_finalize(stmt)
            guard ok else { return false }
        }
        return true
    }

    private func insertEvent(_ draft: CharacterLedgerEventDraft) -> Int64? {
        let sql = """
            INSERT INTO character_event(
                batch_id, occurred_at, recorded_at, event_kind, event_name,
                session_id, source, provider_session_id, cwd, model,
                permission_mode, session_title, remote_host_id, remote_host_name,
                tool_name, tool_use_id, agent_id, rule_version, payload_json, derived_json
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, text: draft.batchID)
        bind(stmt, 2, real: draft.occurredAt.timeIntervalSince1970)
        bind(stmt, 3, real: Date().timeIntervalSince1970)
        bind(stmt, 4, text: draft.eventKind.rawValue)
        bind(stmt, 5, text: draft.eventName)
        bind(stmt, 6, optionalText: draft.sessionID)
        bind(stmt, 7, optionalText: draft.source)
        bind(stmt, 8, optionalText: draft.providerSessionID)
        bind(stmt, 9, optionalText: draft.cwd)
        bind(stmt, 10, optionalText: draft.model)
        bind(stmt, 11, optionalText: draft.permissionMode)
        bind(stmt, 12, optionalText: draft.sessionTitle)
        bind(stmt, 13, optionalText: draft.remoteHostID)
        bind(stmt, 14, optionalText: draft.remoteHostName)
        bind(stmt, 15, optionalText: draft.toolName)
        bind(stmt, 16, optionalText: draft.toolUseID)
        bind(stmt, 17, optionalText: draft.agentID)
        bind(stmt, 18, int: Int64(draft.ruleVersion))
        bind(stmt, 19, text: CharacterLedgerJSON.encodeObject(draft.payload))
        bind(stmt, 20, text: CharacterLedgerJSON.encodeObject(draft.derived))
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    private func insertDelta(_ draft: CharacterLedgerDeltaDraft, eventID: Int64, sequence: Int) -> Bool {
        let sql = """
            INSERT INTO character_event_delta(
                event_id, sequence_in_event, metric_domain, metric_name, reason_code,
                value_type, value_before, value_after, delta_numeric
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        guard let stmt = prepare(sql) else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, int: eventID)
        bind(stmt, 2, int: Int64(sequence))
        bind(stmt, 3, text: draft.metricDomain.rawValue)
        bind(stmt, 4, text: draft.metricName)
        bind(stmt, 5, text: draft.reasonCode)
        bind(stmt, 6, text: draft.valueAfter.valueType.rawValue)
        bind(stmt, 7, text: draft.valueBefore.storageString)
        bind(stmt, 8, text: draft.valueAfter.storageString)
        if let numericDelta = draft.numericDelta {
            bind(stmt, 9, real: numericDelta)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func upsertSessionRecord(from draft: CharacterLedgerEventDraft, eventID: Int64) -> Bool {
        guard let sessionID = draft.sessionID, !sessionID.isEmpty else { return true }

        let sql = """
            INSERT INTO character_session(
                session_id, source, provider_session_id, cwd, model, permission_mode,
                session_title, remote_host_id, remote_host_name,
                first_event_id, last_event_id, first_seen_at, last_seen_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET
                source = COALESCE(excluded.source, character_session.source),
                provider_session_id = COALESCE(excluded.provider_session_id, character_session.provider_session_id),
                cwd = COALESCE(excluded.cwd, character_session.cwd),
                model = COALESCE(excluded.model, character_session.model),
                permission_mode = COALESCE(excluded.permission_mode, character_session.permission_mode),
                session_title = COALESCE(excluded.session_title, character_session.session_title),
                remote_host_id = COALESCE(excluded.remote_host_id, character_session.remote_host_id),
                remote_host_name = COALESCE(excluded.remote_host_name, character_session.remote_host_name),
                last_event_id = excluded.last_event_id,
                last_seen_at = excluded.last_seen_at
            """
        guard let stmt = prepare(sql) else { return false }
        defer { sqlite3_finalize(stmt) }

        bind(stmt, 1, text: sessionID)
        bind(stmt, 2, optionalText: draft.source)
        bind(stmt, 3, optionalText: draft.providerSessionID)
        bind(stmt, 4, optionalText: draft.cwd)
        bind(stmt, 5, optionalText: draft.model)
        bind(stmt, 6, optionalText: draft.permissionMode)
        bind(stmt, 7, optionalText: draft.sessionTitle)
        bind(stmt, 8, optionalText: draft.remoteHostID)
        bind(stmt, 9, optionalText: draft.remoteHostName)
        bind(stmt, 10, int: eventID)
        bind(stmt, 11, int: eventID)
        bind(stmt, 12, real: draft.occurredAt.timeIntervalSince1970)
        bind(stmt, 13, real: draft.occurredAt.timeIntervalSince1970)

        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func rebuildSessionRowsFromEvents() -> Bool {
        let sql = """
            SELECT id, occurred_at, session_id, source, provider_session_id, cwd, model,
                   permission_mode, session_title, remote_host_id, remote_host_name
            FROM character_event
            WHERE session_id IS NOT NULL AND session_id != ''
            ORDER BY id ASC
            """
        guard let stmt = prepare(sql) else { return false }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let sessionID = columnText(stmt, 2) else { continue }
            let draft = CharacterLedgerEventDraft(
                batchID: "",
                occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                eventKind: .externalHook,
                eventName: "",
                sessionID: sessionID,
                source: columnText(stmt, 3),
                providerSessionID: columnText(stmt, 4),
                cwd: columnText(stmt, 5),
                model: columnText(stmt, 6),
                permissionMode: columnText(stmt, 7),
                sessionTitle: columnText(stmt, 8),
                remoteHostID: columnText(stmt, 9),
                remoteHostName: columnText(stmt, 10),
                ruleVersion: 0
            )
            guard upsertSessionRecord(from: draft, eventID: sqlite3_column_int64(stmt, 0)) else {
                return false
            }
        }
        return true
    }

    private func clearReadModelTables() -> Bool {
        exec("DELETE FROM character_state")
            && exec("DELETE FROM character_lifetime")
            && exec("DELETE FROM character_tool_use")
            && exec("DELETE FROM character_cli_use")
            && exec("DELETE FROM character_session")
            && exec("DELETE FROM character_daily_active")
    }

    private func clearAllTables() -> Bool {
        clearReadModelTables()
            && exec("DELETE FROM character_event_delta")
            && exec("DELETE FROM character_event")
    }

    private func dropAllTables() -> Bool {
        exec("DROP TABLE IF EXISTS character_event_delta")
            && exec("DROP TABLE IF EXISTS character_event")
            && exec("DROP TABLE IF EXISTS character_session")
            && exec("DROP TABLE IF EXISTS character_daily_active")
            && exec("DROP TABLE IF EXISTS character_cli_use")
            && exec("DROP TABLE IF EXISTS character_tool_use")
            && exec("DROP TABLE IF EXISTS character_lifetime")
            && exec("DROP TABLE IF EXISTS character_state")
    }

    // MARK: - Rebuild application

    private func applyDelta(
        domain: CharacterMetricDomain,
        metricName: String,
        valueAfter: CharacterMetricValue,
        stats: inout CharacterStats,
        dailyActiveRows: inout [String: Int]
    ) {
        switch domain {
        case .meta:
            guard metricName == "lastTickedAt",
                  case .double(let seconds) = valueAfter else { return }
            stats.lastTickedAt = Date(timeIntervalSince1970: seconds)

        case .vital:
            guard case .double(let value) = valueAfter else { return }
            switch metricName {
            case "hunger": stats.vital.hunger = value
            case "mood": stats.vital.mood = value
            case "energy": stats.vital.energy = value
            case "health": stats.vital.health = value
            default: break
            }

        case .cyber:
            guard case .double(let value) = valueAfter else { return }
            switch metricName {
            case "focus": stats.cyber.focus = value
            case "diligence": stats.cyber.diligence = value
            case "collab": stats.cyber.collab = value
            case "taste": stats.cyber.taste = value
            case "curiosity": stats.cyber.curiosity = value
            default: break
            }

        case .lifetime:
            switch (metricName, valueAfter) {
            case ("totalSessions", .int(let value)):
                stats.stats.totalSessions = value
            case ("totalToolCalls", .int(let value)):
                stats.stats.totalToolCalls = value
            case ("totalActiveSeconds", .int(let value)):
                stats.stats.totalActiveSeconds = value
            case ("currentDayActiveSeconds", .int(let value)):
                stats.stats.currentDayActiveSeconds = value
            case ("currentDayDate", .string(let value)):
                stats.stats.currentDayDate = value
            case ("streakDays", .int(let value)):
                stats.stats.streakDays = value
            case ("lastActiveDate", .string(let value)):
                stats.stats.lastActiveDate = value
            case ("overworkStreakDays", .int(let value)):
                stats.stats.overworkStreakDays = value
            case ("lastFullRestoreDate", .string(let value)):
                stats.stats.lastFullRestoreDate = value
            default:
                break
            }

        case .settings:
            guard case .bool(let flag) = valueAfter else { return }
            switch metricName {
            case "paused":              stats.settings.paused = flag
            case "logRawHookPayloads":  stats.settings.logRawHookPayloads = flag
            case "logTickEvents":       stats.settings.logTickEvents = flag
            default: return
            }

        case .toolUse:
            guard case .int(let count) = valueAfter else { return }
            if count == 0 {
                stats.stats.toolUseCount.removeValue(forKey: metricName)
            } else {
                stats.stats.toolUseCount[metricName] = count
            }

        case .cliUse:
            guard case .int(let count) = valueAfter else { return }
            if count == 0 {
                stats.stats.cliUseCount.removeValue(forKey: metricName)
            } else {
                stats.stats.cliUseCount[metricName] = count
            }

        case .dailyActive:
            guard case .int(let count) = valueAfter else { return }
            if count == 0 {
                dailyActiveRows.removeValue(forKey: metricName)
            } else {
                dailyActiveRows[metricName] = count
            }
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

    // MARK: - SQLite Helpers

    /// Returns the set of column names for `tableName`, empty if the table
    /// does not exist. Used to gate idempotent ADD COLUMN migrations.
    private func tableColumns(_ tableName: String) -> Set<String> {
        guard let stmt = prepare("PRAGMA table_info(\(tableName))") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = columnText(stmt, 1) { names.insert(name) }
        }
        return names
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            log.error("sqlite3_exec failed (\(rc)): \(message) | SQL: \(sql)")
            sqlite3_free(errorMessage)
            return false
        }
        return true
    }

    private func beginImmediate() -> Bool {
        exec("BEGIN IMMEDIATE;")
    }

    private func commit() -> Bool {
        exec("COMMIT;")
    }

    private func rollback() {
        _ = exec("ROLLBACK;")
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            log.error("sqlite3_prepare_v2 failed (\(rc)): \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ idx: Int32, real: Double) {
        sqlite3_bind_double(stmt, idx, real)
    }

    private func bind(_ stmt: OpaquePointer, _ idx: Int32, int: Int64) {
        sqlite3_bind_int64(stmt, idx, int)
    }

    private func bind(_ stmt: OpaquePointer, _ idx: Int32, text: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, idx, text, -1, transient)
    }

    private func bind(_ stmt: OpaquePointer, _ idx: Int32, optionalText: String?) {
        guard let optionalText else {
            sqlite3_bind_null(stmt, idx)
            return
        }
        bind(stmt, idx, text: optionalText)
    }

    private func bindAll(_ stmt: OpaquePointer, values: [SQLiteBindValue]) {
        for (offset, value) in values.enumerated() {
            let idx = Int32(offset + 1)
            switch value {
            case .int(let intValue):
                bind(stmt, idx, int: intValue)
            case .real(let realValue):
                bind(stmt, idx, real: realValue)
            case .text(let textValue):
                bind(stmt, idx, text: textValue)
            }
        }
    }

    private func columnText(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard let raw = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: raw)
    }

    // MARK: - Defaults

    private static func defaultStats() -> CharacterStats {
        var stats = CharacterStats()
        stats.version = currentSchemaVersion
        stats.lastTickedAt = Date()
        stats.stats.currentDayDate = LifetimeStats.todayString
        return stats
    }

    private static let dayFmt: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private enum SQLiteBindValue {
    case int(Int64)
    case real(Double)
    case text(String)
}
