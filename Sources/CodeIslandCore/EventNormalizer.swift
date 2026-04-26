import Foundation

public struct NormalizedEvent: Equatable, Sendable {
    public let eventName: String        // canonical PascalCase, e.g. "PostToolUse"
    public let syntheticToolName: String?  // populated for Cursor file/shell hooks; nil otherwise

    public init(eventName: String, syntheticToolName: String? = nil) {
        self.eventName = eventName
        self.syntheticToolName = syntheticToolName
    }
}

public enum EventNormalizer {

    public static func normalize(_ name: String) -> NormalizedEvent {
        switch name {
        // Cursor (camelCase) — split file/shell hooks into PostToolUse with a synthetic tool.
        case "beforeSubmitPrompt":    return NormalizedEvent(eventName: "UserPromptSubmit")
        case "beforeShellExecution":  return NormalizedEvent(eventName: "PreToolUse",
                                                              syntheticToolName: "Bash")
        case "afterShellExecution":   return NormalizedEvent(eventName: "PostToolUse",
                                                              syntheticToolName: "Bash")
        case "beforeReadFile":        return NormalizedEvent(eventName: "PostToolUse",
                                                              syntheticToolName: "Read")
        case "afterFileEdit":         return NormalizedEvent(eventName: "PostToolUse",
                                                              syntheticToolName: "Edit")
        case "beforeMCPExecution":    return NormalizedEvent(eventName: "PreToolUse",
                                                              syntheticToolName: "MCP")
        case "afterMCPExecution":     return NormalizedEvent(eventName: "PostToolUse",
                                                              syntheticToolName: "MCP")
        case "afterAgentThought":     return NormalizedEvent(eventName: "Notification")
        case "afterAgentResponse":    return NormalizedEvent(eventName: "AfterAgentResponse")
        case "stop":                  return NormalizedEvent(eventName: "Stop")
        // Gemini
        case "BeforeTool":            return NormalizedEvent(eventName: "PreToolUse")
        case "AfterTool":             return NormalizedEvent(eventName: "PostToolUse")
        case "BeforeAgent":           return NormalizedEvent(eventName: "SubagentStart")
        case "AfterAgent":            return NormalizedEvent(eventName: "SubagentStop")
        // GitHub Copilot CLI
        case "sessionStart":          return NormalizedEvent(eventName: "SessionStart")
        case "sessionEnd":            return NormalizedEvent(eventName: "SessionEnd")
        case "userPromptSubmitted":   return NormalizedEvent(eventName: "UserPromptSubmit")
        case "preToolUse":            return NormalizedEvent(eventName: "PreToolUse")
        case "postToolUse":           return NormalizedEvent(eventName: "PostToolUse")
        case "errorOccurred":         return NormalizedEvent(eventName: "Notification")
        // Traecli (snake_case)
        case "session_start":         return NormalizedEvent(eventName: "SessionStart")
        case "session_end":           return NormalizedEvent(eventName: "SessionEnd")
        case "user_prompt_submit":    return NormalizedEvent(eventName: "UserPromptSubmit")
        case "pre_tool_use":          return NormalizedEvent(eventName: "PreToolUse")
        case "post_tool_use":         return NormalizedEvent(eventName: "PostToolUse")
        case "post_tool_use_failure": return NormalizedEvent(eventName: "PostToolUseFailure")
        case "permission_request":    return NormalizedEvent(eventName: "PermissionRequest")
        case "subagent_start":        return NormalizedEvent(eventName: "SubagentStart")
        case "subagent_stop":         return NormalizedEvent(eventName: "SubagentStop")
        case "pre_compact":           return NormalizedEvent(eventName: "PreCompact")
        case "post_compact":          return NormalizedEvent(eventName: "PostCompact")
        case "notification":          return NormalizedEvent(eventName: "Notification")
        default:                      return NormalizedEvent(eventName: name)
        }
    }

    /// Convenience for callers that only need the event name (legacy sites).
    public static func normalizeName(_ name: String) -> String {
        normalize(name).eventName
    }
}
