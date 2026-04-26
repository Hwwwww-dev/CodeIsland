import XCTest
@testable import CodeIslandCore

final class EventNormalizerTests: XCTestCase {

    func testCursor_beforeReadFile_synthesisesRead() {
        let r = EventNormalizer.normalize("beforeReadFile")
        XCTAssertEqual(r.eventName, "PostToolUse")
        XCTAssertEqual(r.syntheticToolName, "Read")
    }

    func testCursor_afterFileEdit_synthesisesEdit() {
        let r = EventNormalizer.normalize("afterFileEdit")
        XCTAssertEqual(r.eventName, "PostToolUse")
        XCTAssertEqual(r.syntheticToolName, "Edit")
    }

    func testCursor_afterShellExecution_synthesisesBash() {
        let r = EventNormalizer.normalize("afterShellExecution")
        XCTAssertEqual(r.eventName, "PostToolUse")
        XCTAssertEqual(r.syntheticToolName, "Bash")
    }

    func testCursor_afterMCPExecution_synthesisesMCP() {
        let r = EventNormalizer.normalize("afterMCPExecution")
        XCTAssertEqual(r.eventName, "PostToolUse")
        XCTAssertEqual(r.syntheticToolName, "MCP")
    }

    func testGemini_beforeAgent_mapsToSubagentStart_noSyntheticTool() {
        let r = EventNormalizer.normalize("BeforeAgent")
        XCTAssertEqual(r.eventName, "SubagentStart")
        XCTAssertNil(r.syntheticToolName)
    }

    func testTraecli_permissionRequest() {
        let r = EventNormalizer.normalize("permission_request")
        XCTAssertEqual(r.eventName, "PermissionRequest")
        XCTAssertNil(r.syntheticToolName)
    }

    func testUnknownEvent_passesThrough() {
        let r = EventNormalizer.normalize("CustomEvent")
        XCTAssertEqual(r.eventName, "CustomEvent")
        XCTAssertNil(r.syntheticToolName)
    }

    func testNormalizeName_legacyCallSites() {
        XCTAssertEqual(EventNormalizer.normalizeName("beforeReadFile"), "PostToolUse")
        XCTAssertEqual(EventNormalizer.normalizeName("session_start"), "SessionStart")
    }
}
