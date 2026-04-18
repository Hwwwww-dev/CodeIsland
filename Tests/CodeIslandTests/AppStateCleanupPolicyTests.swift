import XCTest
@testable import CodeIsland

final class AppStateCleanupPolicyTests: XCTestCase {
    func testCleanupSkippedWhenNothingNeedsMaintenance() {
        XCTAssertFalse(
            AppState.shouldRunCleanup(
                sessionCount: 0,
                monitorCount: 0,
                exitingCount: 0
            )
        )
    }

    func testCleanupRunsWhenSessionsExist() {
        XCTAssertTrue(
            AppState.shouldRunCleanup(
                sessionCount: 1,
                monitorCount: 0,
                exitingCount: 0
            )
        )
    }

    func testCleanupRunsWhenProcessMonitorsExist() {
        XCTAssertTrue(
            AppState.shouldRunCleanup(
                sessionCount: 0,
                monitorCount: 1,
                exitingCount: 0
            )
        )
    }

    func testCleanupRunsWhenExitGracePeriodIsPending() {
        XCTAssertTrue(
            AppState.shouldRunCleanup(
                sessionCount: 0,
                monitorCount: 0,
                exitingCount: 1
            )
        )
    }
}
