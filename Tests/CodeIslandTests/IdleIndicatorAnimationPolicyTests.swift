import XCTest
@testable import CodeIsland

final class IdleIndicatorAnimationPolicyTests: XCTestCase {
    func testCollapsedIdleIndicatorDoesNotAnimateMascot() {
        XCTAssertFalse(
            IdleIndicatorAnimationPolicy.shouldAnimateMascot(
                hovered: false,
                showInlineActions: false
            )
        )
    }

    func testHoveringIdleIndicatorAnimatesMascot() {
        XCTAssertTrue(
            IdleIndicatorAnimationPolicy.shouldAnimateMascot(
                hovered: true,
                showInlineActions: false
            )
        )
    }

    func testExpandedIdleIndicatorAnimatesMascot() {
        XCTAssertTrue(
            IdleIndicatorAnimationPolicy.shouldAnimateMascot(
                hovered: false,
                showInlineActions: true
            )
        )
    }
}
