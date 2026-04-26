import XCTest
@testable import CodeIslandCore

final class ToolSemanticTests: XCTestCase {

    func testClaudeRead()        { assertClassify("claude", "Read", nil, .read,    "Read") }
    func testClaudeEdit()        { assertClassify("claude", "Edit", nil, .write,   "Edit") }
    func testClaudeWrite()       { assertClassify("claude", "Write", nil, .write,  "Write") }
    func testClaudeGrep()        { assertClassify("claude", "Grep", nil, .search,  "Grep") }
    func testClaudeWebFetch()    { assertClassify("claude", "WebFetch", nil, .network, "WebFetch") }
    func testClaudeWebSearch()   { assertClassify("claude", "WebSearch", nil, .search, "WebSearch") }
    func testClaudeTodoWrite()   { assertClassify("claude", "TodoWrite", nil, .manage, "TodoWrite") }
    func testClaudeNotebookEdit(){ assertClassify("claude", "NotebookEdit", nil, .write, "Edit") }

    func testCodexApplyPatch_createBecomesWrite() {
        let r = ToolSemanticMapper.classify(source: "codex", rawToolName: "apply_patch",
                                            toolInput: ["operation": "create_file"])
        XCTAssertEqual(r.semantic, .write); XCTAssertEqual(r.displayName, "Write")
    }
    func testCodexApplyPatch_modifyBecomesEdit() {
        let r = ToolSemanticMapper.classify(source: "codex", rawToolName: "apply_patch",
                                            toolInput: ["operation": "update"])
        XCTAssertEqual(r.semantic, .write); XCTAssertEqual(r.displayName, "Edit")
    }
    func testCodexBash() { assertClassify("codex", "shell", ["command": "make"], .execute, "Bash") }
    func testCodexMCP()  { assertClassify("codex", "mcp__github__get_pr", nil, .manage, "MCP") }

    func testGeminiReadFile()        { assertClassify("gemini", "read_file", nil, .read, "Read") }
    func testGeminiWriteFile()       { assertClassify("gemini", "write_file", nil, .write, "Write") }
    func testGeminiReplace()         { assertClassify("gemini", "replace", nil, .write, "Edit") }
    func testGeminiGlob()            { assertClassify("gemini", "glob", nil, .search, "Grep") }
    func testGeminiGrepSearch()      { assertClassify("gemini", "grep_search", nil, .search, "Grep") }
    func testGeminiWebSearch()       { assertClassify("gemini", "google_web_search", nil, .search, "Grep") }
    func testGeminiWebFetch()        { assertClassify("gemini", "web_fetch", nil, .network, "WebFetch") }
    func testGeminiRunShell()        { assertClassify("gemini", "run_shell_command",
                                                       ["command": "make"], .execute, "Bash") }
    func testGeminiAskUser()         { assertClassify("gemini", "ask_user", nil, .manage, "ask_user") }
    func testGeminiSaveMemory()      { assertClassify("gemini", "save_memory", nil, .manage, "save_memory") }

    func testCursorBeforeReadFile()  { assertClassify("cursor", "Read", nil, .read, "Read") }
    func testCursorAfterFileEdit()   { assertClassify("cursor", "Edit", nil, .write, "Edit") }

    func testShellCat_inferredAsRead() {
        assertClassify("claude", "Bash", ["command": "cat README.md"], .read, "Read")
    }
    func testShellGrep_inferredAsSearch() {
        assertClassify("claude", "Bash", ["command": "rg pattern src/"], .search, "Grep")
    }
    func testShellCurl_inferredAsNetwork() {
        assertClassify("claude", "Bash", ["command": "curl https://example.com"], .network, "WebFetch")
    }
    func testShellMakeBuild_staysExecute() {
        assertClassify("claude", "Bash", ["command": "make build"], .execute, "Bash")
    }

    func testUnknownTool_isUnknown() {
        let r = ToolSemanticMapper.classify(source: "trae", rawToolName: "GhostTool", toolInput: nil)
        XCTAssertEqual(r.semantic, .unknown); XCTAssertEqual(r.displayName, "GhostTool")
    }

    private func assertClassify(_ source: String, _ raw: String, _ input: [String: Any]?,
                                _ expectedSemantic: ToolSemantic, _ expectedDisplay: String,
                                file: StaticString = #file, line: UInt = #line) {
        let r = ToolSemanticMapper.classify(source: source, rawToolName: raw, toolInput: input)
        XCTAssertEqual(r.semantic, expectedSemantic, file: file, line: line)
        XCTAssertEqual(r.displayName, expectedDisplay, file: file, line: line)
    }
}
