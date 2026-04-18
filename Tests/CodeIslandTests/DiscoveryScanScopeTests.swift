import XCTest
@testable import CodeIsland

final class DiscoveryScanScopeTests: XCTestCase {
    func testMergeSpecificSourcesIntoEmptyScope() {
        var scope = DiscoveryScanScope.none

        scope.merge(["codex"])

        XCTAssertEqual(scope, .sources(["codex"]))
    }

    func testMergeSpecificSourcesUnionsThem() {
        var scope = DiscoveryScanScope.sources(["codex"])

        scope.merge(["claude", "codex"])

        XCTAssertEqual(scope, .sources(["claude", "codex"]))
    }

    func testMergeFullScanOverridesSpecificSources() {
        var scope = DiscoveryScanScope.sources(["codex"])

        scope.merge(nil)

        XCTAssertEqual(scope, .all)
    }

    func testMergeSpecificSourcesDoesNotDowngradeFullScan() {
        var scope = DiscoveryScanScope.all

        scope.merge(["claude"])

        XCTAssertEqual(scope, .all)
    }
}
