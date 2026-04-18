import Foundation

enum IdleIndicatorAnimationPolicy {
    static func shouldAnimateMascot(hovered: Bool, showInlineActions: Bool) -> Bool {
        hovered || showInlineActions
    }
}
