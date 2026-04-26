import Foundation

/// Coarse semantic categories for tool calls across CLIs. Cyber-stat attribution
/// keys off this enum, not the raw tool name. Adding a new CLI = extend the
/// classification table; engine logic does not change.
public enum ToolSemantic: String, Sendable, Equatable {
    case read       // Read / read_file / cat / sed / head / NotebookRead / beforeReadFile
    case write      // Edit / Write / NotebookEdit / write_file / replace / apply_patch / afterFileEdit
    case search     // Grep / Glob / ripgrep / ag / ack / glob / grep_search / google_web_search
    case execute    // Bash / shell / run_shell_command (uninferred command)
    case network    // WebFetch / web_fetch / curl / wget
    case manage     // TodoWrite / Task / Agent / Skill / SlashCommand / save_memory / activate_skill / ask_user / MCP
    case unknown    // No mapping — counts toward totals only
}

public enum ToolSemanticMapper {

    public static func classify(source: String?,
                                rawToolName: String,
                                toolInput: [String: Any]?) -> (semantic: ToolSemantic, displayName: String) {
        let trimmed = rawToolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalize(trimmed)

        // MCP tools across all CLIs use a `mcp__server__tool` or similar prefix.
        if key.hasPrefix("mcp") { return (.manage, "MCP") }

        // apply_patch (Codex) — operation field distinguishes create vs update.
        if key == "applypatch" || key == "patch" {
            let isCreate = patchIsCreate(toolInput: toolInput)
            return (.write, isCreate ? "Write" : "Edit")
        }

        // Shell family — try to infer based on the actual command before falling back to execute.
        if key == "bash" || key == "shell" || key == "exec" || key == "execcommand"
            || key == "runshellcommand" {
            if let inferred = shellInferred(input: toolInput) {
                return inferred
            }
            return (.execute, "Bash")
        }

        switch key {
        case "read", "readfile", "notebookread", "readmcpresource":
            return (.read, "Read")
        case "edit", "notebookedit", "replace":
            return (.write, "Edit")
        case "write", "writefile":
            return (.write, "Write")
        case "grep", "ripgrep", "glob", "grepsearch", "googlewebsearch":
            return (.search, "Grep")
        case "search", "websearch":
            return (.search, "WebSearch")
        case "webfetch", "webfetch_tool":
            return (.network, "WebFetch")
        case "todowrite", "task", "agent", "skill", "slashcommand", "savememory",
             "activateskill", "askuser":
            return (.manage, prettyManageName(trimmed))
        default:
            return (.unknown, trimmed.isEmpty ? rawToolName : trimmed)
        }
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private static func shellInferred(input: [String: Any]?) -> (ToolSemantic, String)? {
        guard let command = input?["command"] as? String,
              let exe = firstExecutable(in: command) else { return nil }
        switch exe {
        case "cat", "sed", "nl", "head", "tail", "less", "more", "bat":
            return (.read, "Read")
        case "rg", "grep", "ag", "ack":
            return (.search, "Grep")
        case "curl", "wget", "http", "httpie":
            return (.network, "WebFetch")
        default:
            return nil
        }
    }

    private static func firstExecutable(in command: String) -> String? {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "|;&"))
        let tokens = command
            .split { scalar in scalar.unicodeScalars.allSatisfy { separators.contains($0) } }
            .map(String.init)
        for token in tokens {
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if cleaned.isEmpty { continue }
            if cleaned.hasPrefix("-") { continue }
            if cleaned == "env" || cleaned == "command" || cleaned == "sudo" { continue }
            if cleaned.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil { continue }
            return URL(fileURLWithPath: cleaned).lastPathComponent.lowercased()
        }
        return nil
    }

    private static func patchIsCreate(toolInput: [String: Any]?) -> Bool {
        guard let input = toolInput else { return false }
        for k in ["type", "operation", "op", "action"] {
            if let v = input[k] as? String {
                let n = normalize(v)
                if n == "createfile" || n == "addfile" { return true }
                return false
            }
        }
        if let cmd = input["command"] as? String,
           cmd.range(of: "*** Add File:", options: .caseInsensitive) != nil { return true }
        return false
    }

    private static func prettyManageName(_ raw: String) -> String {
        raw.isEmpty ? "Manage" : raw
    }
}
