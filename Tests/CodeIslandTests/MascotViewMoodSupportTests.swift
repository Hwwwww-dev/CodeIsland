import XCTest
@testable import CodeIsland

final class MascotViewMoodSupportTests: XCTestCase {
    func testMoodSupportedSourcesIncludesEveryMascotWithMoodScenes() {
        let expected: Set<String> = [
            "antigravity",
            "claude",
            "codebuddy",
            "codex",
            "copilot",
            "codybuddycn",
            "cursor",
            "droid",
            "gemini",
            "hermes",
            "kimi",
            "opencode",
            "qoder",
            "qwen",
            "stepfun",
            "trae",
            "traecli",
            "traecn",
            "workbuddy",
        ]

        XCTAssertEqual(MascotView.moodSupportedSources, expected)
    }

    func testIslandMascotViewsExplicitlyReceiveCharacterMood() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("CodeIsland")
            .appendingPathComponent("NotchPanelView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let invocations = mascotViewInvocations(in: source)
        let missingMood = invocations.filter { !$0.text.contains("mood:") }

        XCTAssertTrue(
            missingMood.isEmpty,
            "Island MascotView calls must pass CharacterEngine currentMood. Missing at lines: \(missingMood.map { $0.line })"
        )
    }

    private func mascotViewInvocations(in source: String) -> [(line: Int, text: String)] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [(line: Int, text: String)] = []
        var index = 0

        while index < lines.count {
            let line = String(lines[index])
            guard line.contains("MascotView(") else {
                index += 1
                continue
            }

            let startLine = index + 1
            var text = line
            var balance = parenBalance(in: line)
            index += 1

            while balance > 0 && index < lines.count {
                let nextLine = String(lines[index])
                text += "\n" + nextLine
                balance += parenBalance(in: nextLine)
                index += 1
            }

            result.append((line: startLine, text: text))
        }

        return result
    }

    private func parenBalance(in line: String) -> Int {
        line.reduce(into: 0) { balance, character in
            if character == "(" {
                balance += 1
            } else if character == ")" {
                balance -= 1
            }
        }
    }
}
