import Foundation

public enum CharacterEventKind: String, Codable, Sendable, Equatable {
    case externalHook = "external_hook"
    case derivedEffect = "derived_effect"
    case systemControl = "system_control"
}

public enum CharacterMetricDomain: String, Codable, Sendable, Equatable {
    case meta
    case vital
    case cyber
    case lifetime
    case settings
    case toolUse = "tool_use"
    case cliUse = "cli_use"
    case dailyActive = "daily_active"
}

public enum CharacterMetricValueType: String, Codable, Sendable, Equatable {
    case double
    case int
    case string
    case bool
}

public enum CharacterMetricValue: Codable, Sendable, Equatable {
    case double(Double)
    case int(Int)
    case string(String)
    case bool(Bool)

    public var valueType: CharacterMetricValueType {
        switch self {
        case .double: return .double
        case .int: return .int
        case .string: return .string
        case .bool: return .bool
        }
    }

    var storageString: String {
        switch self {
        case .double(let value):
            return String(format: "%.17g", value)
        case .int(let value):
            return String(value)
        case .string(let value):
            return value
        case .bool(let value):
            return value ? "1" : "0"
        }
    }

    var numericValue: Double? {
        switch self {
        case .double(let value):
            return value
        case .int(let value):
            return Double(value)
        case .string, .bool:
            return nil
        }
    }

    static func fromStorage(type: CharacterMetricValueType, rawValue: String) -> CharacterMetricValue? {
        switch type {
        case .double:
            guard let value = Double(rawValue) else { return nil }
            return .double(value)
        case .int:
            guard let value = Int(rawValue) else { return nil }
            return .int(value)
        case .string:
            return .string(rawValue)
        case .bool:
            switch rawValue {
            case "1", "true", "TRUE":
                return .bool(true)
            case "0", "false", "FALSE":
                return .bool(false)
            default:
                return nil
            }
        }
    }
}

public struct CharacterLedgerEventDraft: Sendable, Equatable {
    public var batchID: String
    public var occurredAt: Date
    public var eventKind: CharacterEventKind
    public var eventName: String
    public var sessionID: String?
    public var source: String?
    public var providerSessionID: String?
    public var cwd: String?
    public var model: String?
    public var permissionMode: String?
    public var sessionTitle: String?
    public var remoteHostID: String?
    public var remoteHostName: String?
    public var toolName: String?
    public var toolUseID: String?
    public var agentID: String?
    public var ruleVersion: Int
    public var payload: [String: AnyCodableLike]
    public var derived: [String: AnyCodableLike]

    public init(
        batchID: String,
        occurredAt: Date,
        eventKind: CharacterEventKind,
        eventName: String,
        sessionID: String? = nil,
        source: String? = nil,
        providerSessionID: String? = nil,
        cwd: String? = nil,
        model: String? = nil,
        permissionMode: String? = nil,
        sessionTitle: String? = nil,
        remoteHostID: String? = nil,
        remoteHostName: String? = nil,
        toolName: String? = nil,
        toolUseID: String? = nil,
        agentID: String? = nil,
        ruleVersion: Int,
        payload: [String: AnyCodableLike] = [:],
        derived: [String: AnyCodableLike] = [:]
    ) {
        self.batchID = batchID
        self.occurredAt = occurredAt
        self.eventKind = eventKind
        self.eventName = eventName
        self.sessionID = sessionID
        self.source = source
        self.providerSessionID = providerSessionID
        self.cwd = cwd
        self.model = model
        self.permissionMode = permissionMode
        self.sessionTitle = sessionTitle
        self.remoteHostID = remoteHostID
        self.remoteHostName = remoteHostName
        self.toolName = toolName
        self.toolUseID = toolUseID
        self.agentID = agentID
        self.ruleVersion = ruleVersion
        self.payload = payload
        self.derived = derived
    }
}

public struct CharacterLedgerDeltaDraft: Sendable, Equatable {
    public var metricDomain: CharacterMetricDomain
    public var metricName: String
    public var reasonCode: String
    public var valueBefore: CharacterMetricValue
    public var valueAfter: CharacterMetricValue
    public var numericDelta: Double?

    public init(
        metricDomain: CharacterMetricDomain,
        metricName: String,
        reasonCode: String,
        valueBefore: CharacterMetricValue,
        valueAfter: CharacterMetricValue,
        numericDelta: Double? = nil
    ) {
        self.metricDomain = metricDomain
        self.metricName = metricName
        self.reasonCode = reasonCode
        self.valueBefore = valueBefore
        self.valueAfter = valueAfter
        self.numericDelta = numericDelta
    }
}

public struct CharacterLedgerEvent: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var batchID: String
    public var occurredAt: Date
    public var recordedAt: Date
    public var eventKind: CharacterEventKind
    public var eventName: String
    public var sessionID: String?
    public var source: String?
    public var providerSessionID: String?
    public var cwd: String?
    public var model: String?
    public var permissionMode: String?
    public var sessionTitle: String?
    public var remoteHostID: String?
    public var remoteHostName: String?
    public var toolName: String?
    public var toolUseID: String?
    public var agentID: String?
    public var ruleVersion: Int
    public var payload: [String: AnyCodableLike]
    public var derived: [String: AnyCodableLike]
}

public struct CharacterLedgerSession: Sendable, Equatable, Identifiable {
    public var sessionID: String
    public var source: String?
    public var providerSessionID: String?
    public var cwd: String?
    public var model: String?
    public var permissionMode: String?
    public var sessionTitle: String?
    public var remoteHostID: String?
    public var remoteHostName: String?
    public var firstEventID: Int64?
    public var lastEventID: Int64?
    public var firstSeenAt: Date
    public var lastSeenAt: Date

    public var id: String { sessionID }
}

public struct CharacterLedgerDelta: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var eventID: Int64
    public var sequenceInEvent: Int
    public var metricDomain: CharacterMetricDomain
    public var metricName: String
    public var reasonCode: String
    public var valueBefore: CharacterMetricValue
    public var valueAfter: CharacterMetricValue
    public var numericDelta: Double?
}

public struct CharacterEventQueryFilter: Sendable, Equatable {
    public var sessionID: String?
    public var eventKind: CharacterEventKind?
    public var eventName: String?
    public var source: String?
    public var providerSessionID: String?
    public var toolName: String?
    public var startDate: Date?
    public var endDate: Date?

    public init(
        sessionID: String? = nil,
        eventKind: CharacterEventKind? = nil,
        eventName: String? = nil,
        source: String? = nil,
        providerSessionID: String? = nil,
        toolName: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil
    ) {
        self.sessionID = sessionID
        self.eventKind = eventKind
        self.eventName = eventName
        self.source = source
        self.providerSessionID = providerSessionID
        self.toolName = toolName
        self.startDate = startDate
        self.endDate = endDate
    }
}

public struct CharacterSessionQueryFilter: Sendable, Equatable {
    public var sessionID: String?
    public var source: String?
    public var providerSessionID: String?

    public init(
        sessionID: String? = nil,
        source: String? = nil,
        providerSessionID: String? = nil
    ) {
        self.sessionID = sessionID
        self.source = source
        self.providerSessionID = providerSessionID
    }
}

enum CharacterLedgerJSON {
    static func encodeObject(_ object: [String: AnyCodableLike]) -> String {
        guard !object.isEmpty else { return "{}" }
        let foundation = object.mapValues { $0.foundationValue }
        guard JSONSerialization.isValidJSONObject(foundation),
              let data = try? JSONSerialization.data(withJSONObject: foundation, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    static func decodeObject(_ text: String?) -> [String: AnyCodableLike] {
        guard let text, !text.isEmpty,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: AnyCodableLike] = [:]
        for (key, value) in object {
            result[key] = AnyCodableLike.from(value)
        }
        return result
    }
}

extension AnyCodableLike {
    var foundationValue: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.foundationValue)
        case .object(let values):
            return values.mapValues(\.foundationValue)
        }
    }
}
