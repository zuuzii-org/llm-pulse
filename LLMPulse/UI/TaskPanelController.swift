import AppKit
import Combine
import QuartzCore
import SwiftUI

enum TaskPanelPresentationSource: Equatable, Sendable {
    case edgeHover
    case statusItemClick
    case programmatic
}

@MainActor
final class TaskPanelVisibilityState {
    private(set) var isVisible = false

    func setVisible(_ isVisible: Bool) {
        self.isVisible = isVisible
    }
}

struct TaskPanelAutomaticDismissState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case hidden
        case statusClickGrace(deadline: TimeInterval, token: UInt64)
        case pointerTracking
        case hoverHeld
        case pointerExitGrace(deadline: TimeInterval, token: UInt64)
    }

    enum Effect: Equatable, Sendable {
        case cancelTimer
        case scheduleTimer(token: UInt64, delay: TimeInterval)
        case hide
    }

    private(set) var phase: Phase = .hidden

    private let statusClickDisplayDuration: TimeInterval
    private let pointerExitDismissDelay: TimeInterval
    private var nextToken: UInt64 = 0

    init(
        statusClickDisplayDuration: TimeInterval,
        pointerExitDismissDelay: TimeInterval
    ) {
        self.statusClickDisplayDuration = statusClickDisplayDuration
        self.pointerExitDismissDelay = pointerExitDismissDelay
    }

    mutating func present(
        source: TaskPanelPresentationSource,
        at uptime: TimeInterval,
        pointerInside: Bool
    ) -> [Effect] {
        invalidateScheduledTimer()

        switch source {
        case .statusItemClick:
            let token = makeToken()
            phase = .statusClickGrace(
                deadline: uptime + statusClickDisplayDuration,
                token: token
            )
            return [
                .cancelTimer,
                .scheduleTimer(token: token, delay: statusClickDisplayDuration),
            ]
        case .edgeHover, .programmatic:
            phase = pointerInside ? .hoverHeld : .pointerTracking
            return [.cancelTimer]
        }
    }

    mutating func pointerMoved(
        inside: Bool,
        at uptime: TimeInterval
    ) -> [Effect] {
        guard phase != .hidden else { return [] }

        if inside {
            switch phase {
            case .hoverHeld:
                return []
            case .hidden:
                return []
            case .statusClickGrace, .pointerTracking, .pointerExitGrace:
                invalidateScheduledTimer()
                phase = .hoverHeld
                return [.cancelTimer]
            }
        }

        switch phase {
        case .hidden, .statusClickGrace, .pointerExitGrace:
            return []
        case .pointerTracking, .hoverHeld:
            let token = makeToken()
            phase = .pointerExitGrace(
                deadline: uptime + pointerExitDismissDelay,
                token: token
            )
            return [
                .cancelTimer,
                .scheduleTimer(token: token, delay: pointerExitDismissDelay),
            ]
        }
    }

    mutating func timerFired(
        token: UInt64,
        at uptime: TimeInterval,
        pointerInside: Bool
    ) -> [Effect] {
        switch phase {
        case let .statusClickGrace(deadline, currentToken),
             let .pointerExitGrace(deadline, currentToken):
            guard token == currentToken else { return [] }
            if uptime + 0.000_001 < deadline {
                return [
                    .scheduleTimer(token: token, delay: max(0, deadline - uptime)),
                ]
            }
            if pointerInside {
                invalidateScheduledTimer()
                phase = .hoverHeld
                return [.cancelTimer]
            }
            invalidateScheduledTimer()
            phase = .hidden
            return [.hide]
        case .hidden, .pointerTracking, .hoverHeld:
            return []
        }
    }

    mutating func reset() -> [Effect] {
        invalidateScheduledTimer()
        phase = .hidden
        return [.cancelTimer]
    }

    private mutating func makeToken() -> UInt64 {
        nextToken &+= 1
        return nextToken
    }

    private mutating func invalidateScheduledTimer() {
        nextToken &+= 1
    }
}

@MainActor
final class TaskPanelController: NSObject, NSWindowDelegate {
    var onSelectAdjacentModel: ((ModelSelectionDirection) -> Void)?
    var isModelSelectionEnabled: () -> Bool = { false }

    private let panel: PulsePanel
    private let width: CGFloat
    private let visibilityState: TaskPanelVisibilityState
    private var languageCancellable: AnyCancellable?

    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var automaticDismissTimer: Timer?
    private var automaticDismissTimerToken: UInt64?
    private var automaticDismissState: TaskPanelAutomaticDismissState
    private weak var outsideDismissExcludedView: NSView?
    private(set) var isVisible = false
    private var presentationGeneration: UInt64 = 0
    private var modelSwipeState = HorizontalModelSwipeState()
    var preventsAutomaticDismiss = false

    init<Content: View>(
        width: CGFloat,
        dismissDelay: TimeInterval,
        statusItemDisplayDuration: TimeInterval,
        rootView: Content,
        visibilityState: TaskPanelVisibilityState = TaskPanelVisibilityState(),
        settings: PulseSettings? = nil
    ) {
        self.width = width
        self.visibilityState = visibilityState
        automaticDismissState = TaskPanelAutomaticDismissState(
            statusClickDisplayDuration: statusItemDisplayDuration,
            pointerExitDismissDelay: dismissDelay
        )
        panel = PulsePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()

        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }
        panel.onScrollWheel = { [weak self] event in
            self?.handleModelSwipe(event) ?? false
        }
        panel.onKeyDown = { [weak self] event in
            self?.handleModelSelectionKey(event) ?? false
        }
        panel.contentView = NSHostingView(rootView: rootView)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.title = PulseBrand.displayName
        updateLocalization(language: settings?.appLanguage ?? .system)
        languageCancellable = settings?.$appLanguage
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] language in
                self?.updateLocalization(language: language)
            }
    }

    private func updateLocalization(language: AppLanguage) {
        panel.setAccessibilityLabel(PulseL10n.text(
            "LLM Pulse 任务侧边栏",
            language: language
        ))
    }

    func setOutsideDismissExcludedView(_ view: NSView?) {
        outsideDismissExcludedView = view
    }

    func toggleFromStatusItem(on screen: NSScreen) {
        if isVisible {
            hide()
        } else {
            show(on: screen, source: .statusItemClick)
        }
    }

    func show(
        on screen: NSScreen,
        source: TaskPanelPresentationSource = .programmatic
    ) {
        presentationGeneration &+= 1
        cancelAutomaticDismissTimer()
        installEventMonitors()

        let targetFrame = panelFrame(on: screen)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let automaticDismissEffects = automaticDismissState.present(
            source: source,
            at: ProcessInfo.processInfo.systemUptime,
            pointerInside: targetFrame.contains(NSEvent.mouseLocation)
        )

        isVisible = true
        visibilityState.setVisible(true)
        panel.alphaValue = reduceMotion ? 1 : 0

        if reduceMotion {
            panel.setFrame(targetFrame, display: true)
            panel.orderFrontRegardless()
            panel.makeKey()
        } else {
            var startingFrame = targetFrame
            startingFrame.origin.x += 18
            panel.setFrame(startingFrame, display: true)
            panel.orderFrontRegardless()
            panel.makeKey()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(targetFrame, display: true)
                panel.animator().alphaValue = 1
            }
        }

        applyAutomaticDismissEffects(automaticDismissEffects)
    }

    func hide() {
        guard isVisible else { return }
        presentationGeneration &+= 1
        let hideGeneration = presentationGeneration
        isVisible = false
        visibilityState.setVisible(false)
        _ = automaticDismissState.reset()
        cancelAutomaticDismissTimer()
        removeEventMonitors()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduceMotion else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        var destinationFrame = panel.frame
        destinationFrame.origin.x += 18
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(destinationFrame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.presentationGeneration == hideGeneration,
                      !self.isVisible else {
                    return
                }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        }
    }

    func handlePointerMove(to location: CGPoint) {
        guard isVisible, !preventsAutomaticDismiss else { return }
        let effects = automaticDismissState.pointerMoved(
            inside: panel.frame.contains(location),
            at: ProcessInfo.processInfo.systemUptime
        )
        applyAutomaticDismissEffects(effects)
    }

    func windowWillClose(_ notification: Notification) {
        isVisible = false
        visibilityState.setVisible(false)
        _ = automaticDismissState.reset()
        cancelAutomaticDismissTimer()
        removeEventMonitors()
    }

    private func panelFrame(on screen: NSScreen) -> CGRect {
        Self.panelFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            width: width
        )
    }

    static func panelFrame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        width: CGFloat
    ) -> CGRect {
        let rightEdge = min(screenFrame.maxX, visibleFrame.maxX)
        return CGRect(
            x: rightEdge - width,
            y: visibleFrame.minY,
            width: width,
            height: visibleFrame.height
        )
    }

    private func installEventMonitors() {
        guard localEventMonitor == nil, globalEventMonitor == nil else { return }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }

            if event.type == .keyDown, event.keyCode == 53 {
                self.hide()
                return nil
            }

            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                let clickedExcludedView = event.window === self.outsideDismissExcludedView?.window
                if !self.preventsAutomaticDismiss,
                   event.window !== self.panel,
                   !clickedExcludedView {
                    self.hide()
                }
            }

            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            // AppKit invokes event-monitor handlers on the main thread. Handle
            // the click synchronously so an old event cannot be queued across a
            // fast hide/reopen cycle and close the new presentation.
            MainActor.assumeIsolated {
                guard let self, self.isVisible,
                      !self.preventsAutomaticDismiss,
                      !self.panel.frame.contains(NSEvent.mouseLocation) else {
                    return
                }
                self.hide()
            }
        }
    }

    private func removeEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func applyAutomaticDismissEffects(
        _ effects: [TaskPanelAutomaticDismissState.Effect]
    ) {
        for effect in effects {
            switch effect {
            case .cancelTimer:
                cancelAutomaticDismissTimer()
            case let .scheduleTimer(token, delay):
                scheduleAutomaticDismissTimer(token: token, delay: delay)
            case .hide:
                hide()
            }
        }
    }

    private func scheduleAutomaticDismissTimer(
        token: UInt64,
        delay: TimeInterval
    ) {
        cancelAutomaticDismissTimer()

        let timer = Timer(timeInterval: max(0.001, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      self.automaticDismissTimerToken == token else {
                    return
                }
                self.automaticDismissTimer = nil
                self.automaticDismissTimerToken = nil
                guard self.isVisible, !self.preventsAutomaticDismiss else { return }

                let effects = self.automaticDismissState.timerFired(
                    token: token,
                    at: ProcessInfo.processInfo.systemUptime,
                    pointerInside: self.panel.frame.contains(NSEvent.mouseLocation)
                )
                self.applyAutomaticDismissEffects(effects)
            }
        }
        automaticDismissTimerToken = token
        RunLoop.main.add(timer, forMode: .common)
        automaticDismissTimer = timer
    }

    private func cancelAutomaticDismissTimer() {
        automaticDismissTimer?.invalidate()
        automaticDismissTimer = nil
        automaticDismissTimerToken = nil
    }

    private func handleModelSwipe(_ event: NSEvent) -> Bool {
        guard isModelSelectionEnabled() else {
            modelSwipeState.reset()
            return false
        }
        let result = modelSwipeState.handle(HorizontalModelSwipeSample(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            phase: Self.swipePhase(event.phase),
            momentumPhase: Self.swipePhase(event.momentumPhase),
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            isShiftModified: event.modifierFlags.contains(.shift)
        ))
        if let direction = result.selectionDirection {
            switch direction {
            case .previous:
                onSelectAdjacentModel?(.previous)
            case .next:
                onSelectAdjacentModel?(.next)
            }
        }
        return result.eventDisposition == .consume
    }

    /// Keyboard equivalent of the two-finger swipe.
    ///
    /// A trackpad gesture is unreachable without a trackpad, so switching
    /// models has to be possible from the keyboard too. Control is the
    /// modifier because plain arrows move focus within the list.
    private func handleModelSelectionKey(_ event: NSEvent) -> Bool {
        guard isModelSelectionEnabled() else { return false }
        guard event.modifierFlags
            .intersection(.deviceIndependentFlagsMask) == .control
        else {
            return false
        }

        switch event.keyCode {
        case Self.leftArrowKeyCode:
            onSelectAdjacentModel?(.previous)
        case Self.rightArrowKeyCode:
            onSelectAdjacentModel?(.next)
        default:
            return false
        }
        return true
    }

    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124

    private static func swipePhase(_ phase: NSEvent.Phase) -> HorizontalModelSwipeSample.Phase {
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        return .none
    }
}

private final class PulsePanel: NSPanel {
    var onCancel: (() -> Void)?
    var onScrollWheel: ((NSEvent) -> Bool)?
    var onKeyDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func scrollWheel(with event: NSEvent) {
        if onScrollWheel?(event) == true { return }
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}
