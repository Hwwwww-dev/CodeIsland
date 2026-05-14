import AppKit
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.codeisland", category: "Panel")

private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Ensures first click on a nonactivatingPanel fires SwiftUI actions
/// instead of being consumed for key-window activation.
/// Also guards against NSHostingView constraint-update re-entrancy crash:
/// during updateConstraints(), SwiftUI may invalidate the view graph and
/// call setNeedsUpdateConstraints again, which AppKit forbids.
private class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// When true, the deferred handler is setting super — don't re-defer.
    private var applyingDeferred = false

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Always defer `needsUpdateConstraints = true` to the next run-loop turn.
    /// During AppKit's display-cycle (constraint-update or layout phases),
    /// calling setNeedsUpdateConstraints synchronously re-enters
    /// `_postWindowNeedsUpdateConstraints` and throws.  Deferring avoids
    /// that entirely; the one-tick delay is imperceptible.
    override var needsUpdateConstraints: Bool {
        get { super.needsUpdateConstraints }
        set {
            if applyingDeferred {
                super.needsUpdateConstraints = newValue
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.applySuperNeedsUpdateConstraints(newValue)
            }
        }
    }

    private func applySuperNeedsUpdateConstraints(_ value: Bool) {
        applyingDeferred = true
        super.needsUpdateConstraints = value
        applyingDeferred = false
    }

    override var needsLayout: Bool {
        get { super.needsLayout }
        set {
            if applyingDeferred {
                super.needsLayout = newValue
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.applySuperNeedsLayout(newValue)
            }
        }
    }

    private func applySuperNeedsLayout(_ value: Bool) {
        applyingDeferred = true
        super.needsLayout = value
        applyingDeferred = false
    }
}

struct PanelScreenHopFrames {
    let outgoing: NSRect
    let incoming: NSRect
}

struct PanelScreenHopMotion {
    let outgoingOffset: CGFloat
    let incomingOffset: CGFloat
    let fadeOutDuration: TimeInterval
    let incomingPauseDuration: TimeInterval
    let fadeInDuration: TimeInterval
}

@MainActor
class PanelWindowController: NSObject, NSWindowDelegate {
    private enum ScreenHopMetrics {
        static let outgoingOffset: CGFloat = 18
        static let incomingOffset: CGFloat = 30
        static let fadeOutDuration: TimeInterval = 0.14
        static let incomingPauseDuration: TimeInterval = 0.06
        static let fadeInDuration: TimeInterval = 0.34
    }

    nonisolated static func screenHopMotion() -> PanelScreenHopMotion {
        PanelScreenHopMotion(
            outgoingOffset: ScreenHopMetrics.outgoingOffset,
            incomingOffset: ScreenHopMetrics.incomingOffset,
            fadeOutDuration: ScreenHopMetrics.fadeOutDuration,
            incomingPauseDuration: ScreenHopMetrics.incomingPauseDuration,
            fadeInDuration: ScreenHopMetrics.fadeInDuration
        )
    }

    nonisolated static func shouldAutoPollScreens(
        displayChoice: String,
        screenCount: Int,
        activeSessionCount: Int
    ) -> Bool {
        displayChoice == "auto" && screenCount > 1 && activeSessionCount > 0
    }

    nonisolated static func didActiveSessionCountChange(
        previousActiveSessionCount: Int?,
        activeSessionCount: Int
    ) -> Bool {
        guard let previousActiveSessionCount else { return false }
        return previousActiveSessionCount != activeSessionCount
    }

    /// Process-wide weak reference. There's only ever one PanelWindowController
    /// alive (created in AppDelegate.applicationDidFinishLaunching). Code in
    /// SwiftUI Views can use this directly instead of going through
    /// `NSApp.delegate as? AppDelegate`, which fails under SwiftUI's
    /// NSApplicationDelegateAdaptor because the actual delegate is a wrapper.
    static weak var current: PanelWindowController?

    private var panel: NSPanel?
    private var hostingView: NotchHostingView<NotchPanelView>?
    private let appState: AppState

    nonisolated static func screenHopFrames(
        oldFrame: NSRect,
        newFrame: NSRect
    ) -> PanelScreenHopFrames {
        let motion = screenHopMotion()
        return PanelScreenHopFrames(
            outgoing: oldFrame.offsetBy(dx: 0, dy: motion.outgoingOffset),
            incoming: newFrame.offsetBy(dx: 0, dy: motion.incomingOffset)
        )
    }

    private func panelSize(for screen: NSScreen) -> NSSize {
        let maxSessions = CGFloat(max(2, UserDefaults.standard.integer(forKey: SettingsKey.maxVisibleSessions)))
        let maxH = max(300, maxSessions * 90 + 60)
        let screenW = screen.frame.width
        let width = min(620, screenW - 40)
        return NSSize(width: width, height: maxH)
    }

    private var panelSize: NSSize {
        panelSize(for: chosenScreen())
    }

    private var visibilityTimer: Timer?
    private var autoScreenPoller: Timer?
    private var fullscreenPoller: Timer?
    private var fullscreenLatch = false
    private var settingsObservers: [NSObjectProtocol] = []
    private var globalClickMonitor: Any?
    private var lastChosenScreenSignature = ""
    private var isAnimatingScreenHop = false
    private var dragStartMouseX: CGFloat?
    private var dragStartPanelX: CGFloat?
    private var isDraggingPanel = false
    private var localDragMonitor: Any?
    private var lastDisplayChoice = ""
    private var lastNotchHeightMode = SettingsDefaults.notchHeightMode
    private var lastCustomNotchHeight = SettingsDefaults.customNotchHeight
    private var lastObservedActiveSessionCount: Int?

    // Hover expansion is driven from this controller, not from SwiftUI's
    // .onHover. Reason: under the close animation SwiftUI's hit-test region
    // for the inner VStack does not shrink in lock-step with the frame, so
    // the cursor sitting in the OLD expanded region keeps re-firing
    // onHover(true). We bypass that entirely by polling NSEvent.mouseLocation
    // on a 20 Hz timer (mouseMoved events are unreliable for a nonactivating
    // panel that can't become key) and driving expansion from cursor
    // coordinates against the visible island rect. The timer only runs while
    // surface == .collapsed; armSessionObservation starts/stops it when
    // surface changes.
    private var hoverPollingTimer: Timer?
    private var hoverCursorInsideVisibleIsland = false
    /// Visible island geometry — pushed in by NotchPanelView whenever
    /// panelWidth or notchHeight changes.
    private var visibleIslandWidth: CGFloat = 0
    private var visibleIslandHeight: CGFloat = 0
    private var lastUsageHoverRefreshAt: Date = .distantPast
    private static let usageHoverRefreshMinInterval: TimeInterval = 10

    init(appState: AppState) {
        self.appState = appState
        super.init()
        Self.current = self
    }

    func showPanel() {
        let screen = chosenScreen()
        let contentView = makeHostingView(for: screen)
        self.hostingView = contentView

        let size = panelSize
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.acceptsMouseMovedEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .readOnly
        panel.contentView = contentView
        panel.delegate = self

        self.panel = panel
        self.lastChosenScreenSignature = ScreenDetector.signature(for: screen)

        setupHorizontalDragMonitor()
        updatePosition()
        panel.orderFrontRegardless()

        // Screen change observer
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCurrentScreen(forceRebuild: true)
                // macOS may not have finished updating NSScreen.screens when the notification fires.
                // Rebuild again after a short delay to pick up the final screen configuration.
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.refreshCurrentScreen(forceRebuild: true)
            }
        }

        // Active space change — check fullscreen
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.refreshCurrentScreen()
                if self.isActiveSpaceFullscreen() {
                    self.fullscreenLatch = true
                    self.updateVisibility()
                    self.startFullscreenExitPoller()
                } else {
                    // Non-fullscreen space: clear any stale latch immediately so the panel
                    // doesn't stay hidden for up to 1.5s while the exit poller catches up (#104).
                    if self.fullscreenLatch {
                        self.fullscreenLatch = false
                        self.fullscreenPoller?.invalidate()
                        self.fullscreenPoller = nil
                    }
                    self.updateVisibility()
                }
            }
        }

        // Frontmost app change
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.refreshCurrentScreen()
                if !self.fullscreenLatch { self.updateVisibility() }
            }
        }

        // Observe session changes via @Observable tracking without polling.
        lastObservedActiveSessionCount = appState.activeSessionCount
        armSessionObservation()

        // Observe settings changes (display choice, panel height)
        observeSettingsChanges()
        configureAutoScreenPolling()

        // Global mouse-moved monitor — drives collapsed→expanded by polling
        // cursor coordinates, bypassing SwiftUI's stuck onHover hit area.
        // Only runs while surface == .collapsed.
        syncHoverMonitor()

        // Global click monitor: close panel + repost click when clicking outside
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self = self, self.appState.surface.isExpanded else { return }
                // Don't close during approval/question
                switch self.appState.surface {
                case .approvalCard, .questionCard: return
                default: break
                }
                // Don't collapse if click is within the panel frame (event leaked on external display)
                if let panelFrame = self.panel?.frame {
                    let clickLocation = NSEvent.mouseLocation
                    if panelFrame.contains(clickLocation) { return }
                }
                withAnimation(NotchAnimation.close) {
                    self.appState.surface = .collapsed
                    self.appState.cancelCompletionQueue()
                }
            }
        }
    }

    private func makeHostingView(for screen: NSScreen) -> NotchHostingView<NotchPanelView> {
        let hasNotch = ScreenDetector.screenHasNotch(screen)
        let notchHeight = ScreenDetector.topBarHeight(for: screen)
        let notchW = ScreenDetector.notchWidth(for: screen)

        let rootView = NotchPanelView(
            appState: appState,
            hasNotch: hasNotch,
            notchHeight: notchHeight,
            notchW: notchW,
            screenWidth: screen.frame.width
        )
        let contentView = NotchHostingView(rootView: rootView)
        contentView.sizingOptions = []
        contentView.translatesAutoresizingMaskIntoConstraints = true
        return contentView
    }

    /// Rebuild the SwiftUI view when the target screen changes
    /// (notchHeight, notchWidth, hasNotch may be different)
    private func rebuildForCurrentScreen(_ screen: NSScreen) {
        guard let panel = panel else { return }
        let contentView = makeHostingView(for: screen)
        self.hostingView = contentView
        panel.contentView = contentView
        lastChosenScreenSignature = ScreenDetector.signature(for: screen)
        updatePosition()
    }

    private func refreshCurrentScreen(forceRebuild: Bool = false) {
        if isAnimatingScreenHop { return }

        let screen = chosenScreen()
        let signature = ScreenDetector.signature(for: screen)

        if forceRebuild {
            rebuildForCurrentScreen(screen)
            return
        }

        if signature != lastChosenScreenSignature {
            animateScreenHop(to: screen, signature: signature)
        }
    }

    private func animateScreenHop(to screen: NSScreen, signature: String) {
        guard let panel = panel else {
            rebuildForCurrentScreen(screen)
            return
        }

        if !panel.isVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            rebuildForCurrentScreen(screen)
            panel.alphaValue = 1
            return
        }

        isAnimatingScreenHop = true
        let oldFrame = panel.frame
        let newFrame = panelFrame(for: screen)
        let motion = Self.screenHopMotion()
        let frames = Self.screenHopFrames(oldFrame: oldFrame, newFrame: newFrame)
        let targetSignature = signature

        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(frames.outgoing, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard let panel = self.panel else {
                    self.isAnimatingScreenHop = false
                    return
                }

                let targetScreen = NSScreen.screens.first {
                    ScreenDetector.signature(for: $0) == targetSignature
                } ?? self.chosenScreen()

                self.rebuildForCurrentScreen(targetScreen)
                panel.alphaValue = 0
                panel.setFrame(frames.incoming, display: true)

                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(motion.incomingPauseDuration * 1_000_000_000))
                    guard let self = self else { return }
                    guard let panel = self.panel else {
                        self.isAnimatingScreenHop = false
                        return
                    }

                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = motion.fadeInDuration
                        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
                        panel.animator().alphaValue = 1
                        panel.animator().setFrame(newFrame, display: true)
                    } completionHandler: { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.lastChosenScreenSignature = targetSignature
                            self?.isAnimatingScreenHop = false
                        }
                    }
                }
            }
        }
    }

    private func observeSettingsChanges() {
        lastDisplayChoice = SettingsManager.shared.displayChoice
        lastNotchHeightMode = SettingsManager.shared.notchHeightMode.rawValue
        lastCustomNotchHeight = SettingsManager.shared.customNotchHeight
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let newChoice = SettingsManager.shared.displayChoice
                let newHeightMode = SettingsManager.shared.notchHeightMode.rawValue
                let newCustomHeight = SettingsManager.shared.customNotchHeight

                let displayChanged = newChoice != self.lastDisplayChoice
                let notchHeightChanged = newHeightMode != self.lastNotchHeightMode
                    || abs(newCustomHeight - self.lastCustomNotchHeight) > 0.001

                if displayChanged {
                    self.refreshCurrentScreen(forceRebuild: true)
                    self.configureAutoScreenPolling()
                } else if notchHeightChanged {
                    self.refreshCurrentScreen(forceRebuild: true)
                } else {
                    self.updateVisibility()
                    self.updatePosition()
                }

                // Always sync snapshots — previously only the display branch updated lastDisplayChoice,
                // leaving lastNotch* stale and breaking later notch-height / 灵动岛 appearance updates.
                self.lastDisplayChoice = newChoice
                self.lastNotchHeightMode = newHeightMode
                self.lastCustomNotchHeight = newCustomHeight
            }
        }
        settingsObservers.append(observer)
    }

    private func configureAutoScreenPolling() {
        autoScreenPoller?.invalidate()
        autoScreenPoller = nil

        guard Self.shouldAutoPollScreens(
            displayChoice: SettingsManager.shared.displayChoice,
            screenCount: NSScreen.screens.count,
            activeSessionCount: appState.activeSessionCount
        ) else { return }

        // Screen-parameter / Space-change / frontmost-app notifications already cover the
        // common cases. This poller is a fallback for the rare path where a window is
        // dragged to another display without switching focus — a low cadence is enough
        // and every tick runs a full CGWindowListCopyWindowInfo, which was measurably
        // contributing to Energy Impact (#92).
        autoScreenPoller = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCurrentScreen()
            }
        }
    }

    private func armSessionObservation() {
        withObservationTracking {
            _ = appState.activeSessionCount
            _ = appState.surface
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let activeSessionCount = self.appState.activeSessionCount
                if Self.didActiveSessionCountChange(
                    previousActiveSessionCount: self.lastObservedActiveSessionCount,
                    activeSessionCount: activeSessionCount
                ) {
                    self.configureAutoScreenPolling()
                }
                self.lastObservedActiveSessionCount = activeSessionCount
                self.updateVisibility()
                self.syncHoverMonitor()
                self.armSessionObservation()
            }
        }
    }

    private func updatePosition() {
        guard let panel = panel else { return }
        let screen = chosenScreen()
        panel.setFrame(panelFrame(for: screen), display: true)
    }

    private func panelFrame(for screen: NSScreen) -> NSRect {
        let size = panelSize(for: screen)
        let screenFrame = screen.frame
        let centeredX = centeredX(for: size, screen: screen)
        let dragOffset = SettingsManager.shared.allowHorizontalDrag
            ? CGFloat(SettingsManager.shared.panelHorizontalOffset)
            : 0
        let x = clampedX(centeredX + dragOffset, panelWidth: size.width, on: screen)
        let y = screenFrame.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func centeredX(for size: NSSize, screen: NSScreen) -> CGFloat {
        screen.frame.midX - size.width / 2
    }

    private func clampedX(_ desiredX: CGFloat, panelWidth: CGFloat, on screen: NSScreen) -> CGFloat {
        min(max(desiredX, screen.frame.minX), screen.frame.maxX - panelWidth)
    }

    private func setupHorizontalDragMonitor() {
        let dragThreshold: CGFloat = 5

        localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let panel = self.panel,
                  SettingsManager.shared.allowHorizontalDrag else { return event }

            switch event.type {
            case .leftMouseDown:
                if event.window === panel {
                    self.dragStartMouseX = NSEvent.mouseLocation.x
                    self.dragStartPanelX = panel.frame.origin.x
                    self.isDraggingPanel = false
                }
            case .leftMouseDragged:
                if let startMouseX = self.dragStartMouseX,
                   let startPanelX = self.dragStartPanelX {
                    let deltaX = NSEvent.mouseLocation.x - startMouseX
                    // Only start moving after exceeding threshold
                    if !self.isDraggingPanel {
                        guard abs(deltaX) > dragThreshold else { return event }
                        self.isDraggingPanel = true
                    }
                    let screen = self.chosenScreen()
                    let size = panel.frame.size
                    let newX = self.clampedX(startPanelX + deltaX, panelWidth: size.width, on: screen)
                    let fixedY = screen.frame.maxY - size.height
                    panel.setFrameOrigin(NSPoint(x: newX, y: fixedY))
                }
            case .leftMouseUp:
                if self.isDraggingPanel, let panel = self.panel {
                    let screen = self.chosenScreen()
                    let size = panel.frame.size
                    let offset = panel.frame.origin.x - self.centeredX(for: size, screen: screen)
                    SettingsManager.shared.panelHorizontalOffset = Double(offset)
                }
                self.dragStartMouseX = nil
                self.dragStartPanelX = nil
                self.isDraggingPanel = false
            default:
                break
            }
            return event
        }
    }

    /// Choose which screen to display on based on displayChoice setting
    private func chosenScreen() -> NSScreen {
        let choice = SettingsManager.shared.displayChoice

        // Handle specific screen index: "screen_0", "screen_1", etc.
        if choice.hasPrefix("screen_"),
           let index = Int(choice.dropFirst(7)),
           index < NSScreen.screens.count {
            return NSScreen.screens[index]
        }

        // "auto" — prefer notch screen, fallback to main
        return ScreenDetector.preferredScreen
    }

    /// Poll every 1.5s while in fullscreen; stop when fullscreen ends
    private func startFullscreenExitPoller() {
        fullscreenPoller?.invalidate()
        fullscreenPoller = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else { timer.invalidate(); return }
                if !self.isActiveSpaceFullscreen() {
                    self.fullscreenLatch = false
                    self.updateVisibility()
                    timer.invalidate()
                    self.fullscreenPoller = nil
                }
            }
        }
    }

    /// Update panel visibility based on settings
    private func updateVisibility() {
        guard let panel = panel else { return }
        let settings = SettingsManager.shared
        if settings.hideInFullscreen && fullscreenLatch {
            panel.orderOut(nil)
            return
        }

        if settings.hideWhenNoSession && appState.activeSessionCount == 0 {
            panel.orderOut(nil)
            return
        }

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func isActiveSpaceFullscreen() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }

        let screen = chosenScreen()

        // Primary: check if frontmost app has a window covering the entire screen
        if let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] {
            for window in windowList {
                guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                      pid == frontApp.processIdentifier,
                      let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                      let bounds = window[kCGWindowBounds as String] as? [String: Any],
                      let w = bounds["Width"] as? CGFloat,
                      let h = bounds["Height"] as? CGFloat else { continue }
                if w >= screen.frame.width && h >= screen.frame.height {
                    return true
                }
            }
        }

        // Fallback: menu bar disappeared on this screen (no Screen Recording permission needed)
        let menuBarGap = screen.frame.maxY - screen.visibleFrame.maxY
        if menuBarGap < 1 {
            return true
        }

        return false
    }

    /// Whether the mouse cursor is currently within the visible island rect
    /// (centered horizontally on the panel, anchored to the top).
    ///
    /// SwiftUI's onHover hit-test region updates lazily on mouse events. During
    /// the close animation the panelWidth frame shrinks, but if the cursor stays
    /// still SwiftUI never re-fires onHover(false) — it can sit in the OLD
    /// expanded hit area and re-trigger expansion the moment any timer fires.
    /// Use this as a hard coordinate guard before committing to expand.
    func isMouseInsideVisibleIsland(width: CGFloat, height: CGFloat) -> Bool {
        guard let panel = panel else { return false }
        let mouse = NSEvent.mouseLocation
        let pf = panel.frame
        let halfW = width / 2
        return mouse.x >= pf.midX - halfW
            && mouse.x <= pf.midX + halfW
            && mouse.y >= pf.maxY - height
            && mouse.y <= pf.maxY
    }

    /// Pushed in by `NotchPanelView` whenever its computed `panelWidth` or
    /// `notchHeight` changes. The controller uses these for the global
    /// mouseMoved hit-test that drives expansion from .collapsed.
    func reportVisibleIslandSize(width: CGFloat, height: CGFloat) {
        visibleIslandWidth = width
        visibleIslandHeight = height
    }

    /// Start the polling timer if and only if surface == .collapsed and the
    /// panel is visible. Idempotent: safe to call from showPanel and from the
    /// surface-observation onChange.
    private func syncHoverMonitor() {
        // panel.isVisible can be false transiently during showPanel /
        // animations; rely on surface alone here. handleHoverMouseMoved
        // still guards on panel visibility per tick.
        if appState.surface == .collapsed {
            startHoverMouseMonitor()
        } else {
            stopHoverMouseMonitor()
        }
    }

    private func startHoverMouseMonitor() {
        if hoverPollingTimer != nil { return }
        // RunLoop.common is critical: while the mouse is moving, AppKit
        // switches the main run loop to .eventTracking mode and a default-mode
        // timer would never fire — exactly when we need it most.
        // The closure is invoked on the main run loop; assumeIsolated lets us
        // call MainActor-isolated methods without a Task hop on every tick.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleHoverMouseMoved()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverPollingTimer = timer
    }

    private func stopHoverMouseMonitor() {
        hoverPollingTimer?.invalidate()
        hoverPollingTimer = nil
        hoverCursorInsideVisibleIsland = false
    }

    @MainActor
    private func handleHoverMouseMoved() {
        // Defensive: the timer is only started while collapsed, but a state
        // flip can race with the next tick. Bail without expanding.
        guard panel?.isVisible == true,
              appState.surface == .collapsed else {
            hoverCursorInsideVisibleIsland = false
            return
        }
        let inside = isMouseInsideVisibleIsland(
            width: visibleIslandWidth, height: visibleIslandHeight)
        if inside == hoverCursorInsideVisibleIsland { return }
        hoverCursorInsideVisibleIsland = inside
        guard inside else { return }
        // Edge-triggered: only on outside→inside transition. Expand immediately
        // (no debounce) — explicit user requirement.
        triggerHoverExpand()
    }

    @MainActor
    private func triggerHoverExpand() {
        // Smart suppress: don't auto-expand when the active session's terminal
        // is the foreground app. The user is busy in the terminal — they
        // didn't ask for a panel. (Default off; opt-in via settings.)
        if UserDefaults.standard.bool(forKey: SettingsKey.smartSuppress),
           isActiveTerminalForeground() { return }
        if UserDefaults.standard.bool(forKey: SettingsKey.hapticOnHover) {
            let performer = NSHapticFeedbackManager.defaultPerformer
            let intensity = UserDefaults.standard.integer(forKey: SettingsKey.hapticIntensity)
            switch intensity {
            case 3:
                performer.perform(.levelChange, performanceTime: .now)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    performer.perform(.levelChange, performanceTime: .now)
                }
            case 2:
                performer.perform(.levelChange, performanceTime: .default)
            default:
                performer.perform(.alignment, performanceTime: .default)
            }
        }
        refreshUsageMonitorsFromHover()
        withAnimation(NotchAnimation.open) {
            appState.surface = .sessionList
            appState.cancelCompletionQueue()
            if appState.activeSessionId == nil {
                appState.activeSessionId = appState.sessions.keys.sorted().first
            }
        }
    }

    @MainActor
    private func refreshUsageMonitorsFromHover() {
        let now = Date()
        guard now.timeIntervalSince(lastUsageHoverRefreshAt) >= Self.usageHoverRefreshMinInterval else { return }
        lastUsageHoverRefreshAt = now
        Task { @MainActor in
            await RateLimitMonitor.shared.refresh()
            await CodexUsageMonitor.shared.refresh()
        }
    }

    /// Fast check: is the terminal running the active session the foreground app?
    /// Main-thread safe — no AppleScript or subprocess calls.
    func isActiveTerminalForeground() -> Bool {
        guard let sessionId = appState.activeSessionId,
              let session = appState.sessions[sessionId],
              session.termApp != nil else { return false }
        return TerminalVisibilityDetector.isTerminalFrontmostForSession(session)
    }

    func windowDidMove(_ notification: Notification) {
        // Drag is handled by setupHorizontalDragMonitor — no correction needed here.
    }

    deinit {
        autoScreenPoller?.invalidate()
        fullscreenPoller?.invalidate()
        hoverPollingTimer?.invalidate()
        for observer in settingsObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localDragMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
