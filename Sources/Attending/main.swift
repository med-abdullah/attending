import AppKit
import SwiftUI
import AttendingCore
import OSLog
import Combine

final class NotchPanel: NSPanel {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
@MainActor final class TrackingHost: NSHostingView<ShellView> {
    var entered: (() -> Void)?
    var exited: (() -> Void)?
    /// Pointer position in SwiftUI coordinates (origin top-left).
    var moved: ((CGPoint) -> Void)?
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(next); area = next
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        var point = convert(event.locationInWindow, from: nil)
        if !isFlipped { point.y = bounds.height - point.y }
        moved?(point)
    }
    override func mouseEntered(with event: NSEvent) { entered?() }
    override func mouseExited(with event: NSEvent) { exited?() }
    // Clicks on the collapsed wings act immediately, even when Attending isn't active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private(set) var panel: NotchPanel!
    private var statusItem: NSStatusItem!
    private var shortcut: GlobalShortcut?
    private var hoverTask: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    private var tabDwell: Task<Void, Never>?
    private var dwellTab: Tab?
    private var settleTask: Task<Void, Never>?
    private var shutdownStarted = false
    private var shutdownComplete = false
    private var openMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var layoutSubscription: AnyCancellable?
    /// Where the island is (or is animating to), in screen coordinates.
    private var islandScreenRect: CGRect?
    private var layoutGeneration = 0
    private var lastLayoutKey = ""
    /// Dragging the island to a new spot: where the press started, and whether it's moving.
    private var dragStart: NSPoint?
    private var draggingIsland = false
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Attending", category: "lifecycle")
    private static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent two UI instances from consuming the same event inbox.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").filter({ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }).count > 0 { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.onEscape = { [weak self] in self?.model.setMode(.idle) }
        panel.isFloatingPanel = true; panel.level = .statusBar; panel.hidesOnDeactivate = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false; panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let host = TrackingHost(rootView: ShellView(model: model))
        host.entered = { [weak self] in self?.pointerEntered() }
        host.exited = { [weak self] in self?.pointerLeft() }
        host.moved = { [weak self] point in self?.hoverTab(at: point) }
        panel.contentView = host
        model.onModeChange = { [weak self] in self?.modeChanged() }
        model.onProjectPicker = { [weak self] choosing in
            guard let self else { return }
            model.pickerOpen = choosing
            if choosing { panel.orderOut(nil) } else { panel.orderFrontRegardless(); panel.makeKey() }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let symbol = NSImage(systemSymbolName: "stethoscope", accessibilityDescription: "Attending")
        symbol?.isTemplate = true
        statusItem.button?.image = symbol
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.lastLayoutKey = ""; self?.layout(animated: false) }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { [weak self] in self?.suspend() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.suspend() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] in self?.resume() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.resume() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in self?.model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.suspend() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.resume() }
        do {
            shortcut = try GlobalShortcut { [weak self] in
                guard let self else { return }
                if model.mode == .expanded && model.selectedTab == .assistant { model.setMode(.idle) } else { model.openAssistant() }
            }
        } catch { model.error = "Command–Shift–Space is unavailable. Use the menu bar icon." }
        // Content that changes the island's size (tabs, media, timer, alerts, HUD) re-lays
        // it out after SwiftUI applies the change; unchanged sizes are skipped.
        layoutSubscription = Publishers.MergeMany(model.objectWillChange.eraseToAnyPublisher(), model.media.objectWillChange.eraseToAnyPublisher(), model.timer.objectWillChange.eraseToAnyPublisher(), model.meeting.objectWillChange.eraseToAnyPublisher(), model.activities.objectWillChange.eraseToAnyPublisher(), model.calendar.objectWillChange.eraseToAnyPublisher(), model.sheets.objectWillChange.eraseToAnyPublisher(), model.anki.objectWillChange.eraseToAnyPublisher(), model.usage.objectWillChange.eraseToAnyPublisher())
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                layout(animated: true)
                model.media.updateSpectrum(awake: model.awake)
            }
        layout(animated: false); panel.orderFrontRegardless()
        model.stepAside.screen = { [weak self] in self?.islandScreen() }
        model.stepAside.onChange = { [weak self] _ in self?.updateVisibility() }
        model.prompter.placement = { [weak self] in
            guard let screen = self?.islandScreen() else { return nil }
            let top = screen.safeAreaInsets.top
            let width = top > 0 ? (screen.auxiliaryTopRightArea?.minX ?? 0) - (screen.auxiliaryTopLeftArea?.maxX ?? 0) : 0
            return (screen, top, max(0, width))
        }
        model.prompter.onRunningChange = { [weak self] running in
            if running { self?.model.setMode(.idle) }
            self?.updateVisibility()
        }
        installIslandDrag()
        model.stepAside.start()
        Task { await model.start() }
        model.onboarding.model = model
        DispatchQueue.main.async { [weak self] in
            if !MoveToApplications.offerIfNeeded() { self?.model.onboarding.showIfNeeded() }
        }
        runDevelopmentFlags()
    }

    /// Accessory apps have no menu bar, so standard editing shortcuts have nothing to
    /// dispatch through. A hidden main menu gives text fields and web views ⌘C/⌘V/⌘X/⌘A/⌘Z.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: Layout and animation

    /// The menu-bar screen when chosen in Settings (an external display, say); otherwise the notch's.
    private func islandScreen() -> NSScreen? {
        let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
        let chosen = model.islandOnMainScreen ? NSScreen.screens.first : nil
        return chosen ?? notched ?? NSScreen.main ?? NSScreen.screens.first
    }
    private func metrics(for anchor: IslandAnchor? = nil) -> NotchMetrics? {
        guard let screen = islandScreen() else { return nil }
        let useNotch = (anchor ?? model.islandAnchor) == .notch && screen.safeAreaInsets.top > 0
        return NotchMetrics(screen: screen.frame, visible: screen.visibleFrame, notchLeft: useNotch ? screen.auxiliaryTopLeftArea?.maxX : nil, notchRight: useNotch ? screen.auxiliaryTopRightArea?.minX : nil, height: useNotch ? screen.safeAreaInsets.top : 0, scale: screen.backingScaleFactor)
    }
    private func targetRect(_ m: NotchMetrics) -> CGRect {
        model.mode == .idle ? IslandGeometry.collapsed(m, wing: model.idleWing, anchor: model.islandAnchor) : IslandGeometry.panel(m, size: model.panelSize, anchor: model.islandAnchor)
    }
    /// Converts a screen rect into SwiftUI coordinates inside `canvas` (y down).
    private func local(_ rect: CGRect, in canvas: CGRect) -> CGRect {
        CGRect(x: rect.minX - canvas.minX, y: canvas.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The window briefly grows to cover both the old and new island, SwiftUI springs
    /// the island between them, then the window shrinks back to fit. Window frames
    /// never animate, which is what made the old transitions stutter.
    private func layout(animated: Bool) {
        // While the island is being dragged, it follows the pointer instead.
        guard !draggingIsland, let m = metrics() else { return }
        let notchHeight = m.hasNotch ? m.height : 0
        if model.notchHeight != notchHeight { model.notchHeight = notchHeight }
        if model.notchWidth != m.notchWidth { model.notchWidth = m.notchWidth }
        let target = targetRect(m)
        let key = "\(target)|\(model.mode)"
        guard key != lastLayoutKey else { return }
        lastLayoutKey = key
        let from = islandScreenRect ?? target
        islandScreenRect = target
        let animate = animated && panel.isVisible && !model.reduceMotion && from != target
        let canvas = animate ? from.union(target) : target
        if panel.frame != canvas {
            resize(to: canvas, islandAt: local(from, in: canvas))
        }
        let apply = { [self] in
            model.islandFrame = local(target, in: canvas)
            if model.shownMode != model.mode { model.shownMode = model.mode }
        }
        layoutGeneration += 1
        let generation = layoutGeneration
        settleTask?.cancel()
        if animate {
            // Next run-loop turn, so the starting frame renders before the spring begins.
            DispatchQueue.main.async { withAnimation(Self.spring) { apply() } }
            if canvas != target {
                settleTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(520))
                    guard let self, !Task.isCancelled, generation == layoutGeneration else { return }
                    resize(to: target, islandAt: local(target, in: target))
                }
            }
        } else {
            var still = Transaction(); still.disablesAnimations = true
            withTransaction(still) { apply() }
        }
        if model.debugLogging { log.debug("Island layout updated") }
    }

    /// Resizes the window and repositions the island in one screen update. Without
    /// this, one frame could draw the island at its old offset in the new window.
    private func resize(to frame: CGRect, islandAt island: CGRect) {
        panel.disableScreenUpdatesUntilFlush()
        var still = Transaction(); still.disablesAnimations = true
        withTransaction(still) { model.islandFrame = island }
        panel.setFrame(frame, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    /// Hides the island while it steps aside (full screen, an editor in front, the
    /// teleprompter) unless it's open, and brings it back with any alert that waited.
    private func updateVisibility() {
        defer { MediaKeyTap.passThrough = !panel.isVisible }
        guard model.awake, !model.pickerOpen else { return }
        if model.islandAside {
            if panel.isVisible { panel.orderOut(nil) }
        } else if !panel.isVisible {
            lastLayoutKey = ""; layout(animated: false); panel.orderFrontRegardless()
            model.releaseHeldAlert()
        }
    }

    private func modeChanged() {
        updateVisibility()
        if model.mode != .idle { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        layout(animated: true)
        updateOpenMonitors()
        if model.mode == .expanded {
            // Take keyboard focus without activating the app, so the menu bar and the
            // app you were using stay put.
            panel.makeKeyAndOrderFront(nil)
        } else if panel.isKeyWindow {
            panel.resignKey()
        }
    }

    // MARK: Moving the island

    /// Drag the island anywhere; on release it glides to the nearest spot (under the notch,
    /// top left, top right or bottom center). A press that doesn't move is still a click.
    private func installIslandDrag() {
        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp], handler: { [weak self] event in
            let type = event.type, window = event.windowNumber
            let consumed = MainActor.assumeIsolated { self?.handleIslandDrag(type, window: window) ?? false }
            return consumed ? nil : event
        }) else { return }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in NSEvent.removeMonitor(monitor) })
    }
    /// Returns true when the event was part of a drag (and shouldn't reach the island as a click).
    func handleIslandDrag(_ type: NSEvent.EventType, window: Int, at point: NSPoint? = nil) -> Bool {
        let mouse = point ?? NSEvent.mouseLocation
        switch type {
        case .leftMouseDown:
            let onIsland = islandScreenRect?.insetBy(dx: -6, dy: -6).contains(mouse) ?? false
            dragStart = window == panel.windowNumber && model.mode != .expanded && onIsland ? mouse : nil
            return false
        case .leftMouseDragged:
            guard let start = dragStart else { return false }
            if !draggingIsland {
                guard hypot(mouse.x - start.x, mouse.y - start.y) > 6 else { return false }
                draggingIsland = true
                hoverTask?.cancel(); leaveTask?.cancel()
                model.alert = nil
                if model.mode != .idle { model.setMode(.idle); model.shownMode = .idle }
                // A floating pill while it moves, whatever spot it left.
                model.notchHeight = 0
            }
            guard let m = metrics(for: .topLeft) else { return true }
            let size = IslandGeometry.collapsed(m, wing: model.idleWing, anchor: .topLeft).size
            let rect = CGRect(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2, width: size.width, height: size.height)
            islandScreenRect = rect
            resize(to: rect, islandAt: local(rect, in: rect))
            return true
        case .leftMouseUp:
            dragStart = nil
            guard draggingIsland else { return false }
            draggingIsland = false
            let drop = CGPoint(x: islandScreenRect?.midX ?? mouse.x, y: islandScreenRect?.midY ?? mouse.y)
            let candidates = IslandAnchor.allCases.compactMap { anchor -> (IslandAnchor, CGFloat)? in
                guard let m = metrics(for: anchor), anchor != .notch || m.hasNotch else { return nil }
                let rect = IslandGeometry.collapsed(m, wing: model.idleWing, anchor: anchor)
                return (anchor, hypot(rect.midX - drop.x, rect.midY - drop.y))
            }
            lastLayoutKey = ""
            if let best = candidates.min(by: { $0.1 < $1.1 })?.0, best != model.islandAnchor {
                model.islandAnchor = best   // lays out, springing from where it was dropped
            } else {
                layout(animated: true)
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            return true
        default:
            return false
        }
    }

    // MARK: Hover, leave and click-away

    private var pointerInIsland: Bool {
        guard let rect = islandScreenRect else { return false }
        return rect.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)
    }
    private func pointerEntered() {
        model.pointerInside = true
        leaveTask?.cancel()
        guard model.mode == .idle, model.hoverEnabled else { return }
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(model.hoverDelay))
            guard !Task.isCancelled, model.mode == .idle, pointerInIsland else { return }
            model.setMode(.preview)
        }
    }
    /// Resting on a tab icon for a moment switches to it, alongside clicking.
    private func hoverTab(at point: CGPoint) {
        guard model.mode == .expanded, UserDefaults.standard.object(forKey: "hoverTabs") as? Bool ?? true else { return }
        let hit = model.tabFrames.first { $0.value.insetBy(dx: -3, dy: -3).contains(point) }?.key
        guard let hit, hit != model.selectedTab, !(hit == .shelf && model.selectedTab == .clipboard) else {
            if hit == nil { tabDwell?.cancel(); dwellTab = nil }
            return
        }
        guard hit != dwellTab else { return }
        dwellTab = hit
        tabDwell?.cancel()
        tabDwell = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, dwellTab == hit, model.mode == .expanded else { return }
            withAnimation(.easeOut(duration: 0.18)) { model.selectedTab = hit }
            dwellTab = nil
        }
    }
    private func pointerLeft() {
        hoverTask?.cancel()
        // During transitions the window is larger than the island; decide by the island.
        if pointerInIsland { return }
        model.pointerInside = false
        scheduleLeaveClose()
    }
    private func scheduleLeaveClose() {
        guard model.mode != .idle else { return }
        leaveTask?.cancel()
        leaveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(model.mode == .preview ? 280 : 550))
            guard !Task.isCancelled else { return }
            // Clear first, so a suppressed check (typing, alert) can be retried by the next pointer move.
            leaveTask = nil
            guard !pointerInIsland, shouldAutoClose else { return }
            model.setMode(.idle)
        }
    }
    /// Leaving never closes the panel mid-task: while typing, dragging a file, choosing
    /// a project, or while an alert is showing (alerts time out on their own).
    private var shouldAutoClose: Bool {
        guard !model.pickerOpen, !model.holdOpen, !model.dropTargeted, !model.dragActive, model.alert == nil, !model.assistant.popupOpen else { return false }
        if model.mode == .preview { return true }
        guard model.autoClose else { return false }
        if Date().timeIntervalSince(model.lastTypingAt) < 8 { return false }
        if model.selectedTab == .assistant && !model.assistant.prompt.isEmpty { return false }
        return true
    }
    /// Monitors exist only while the island is open; nothing runs while collapsed.
    private func updateOpenMonitors() {
        openMonitors.forEach { NSEvent.removeMonitor($0) }; openMonitors.removeAll()
        leaveTask?.cancel(); leaveTask = nil
        guard model.mode != .idle else { return }
        if let move = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }) { openMonitors.append(move) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.trackPointer() }; return event
        }) { openMonitors.append(local) }
        // A click in any other app closes the island, like a popover.
        if let click = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedElsewhere() }
        }) { openMonitors.append(click) }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.model.lastTypingAt = Date() }; return event
        }) { openMonitors.append(keys) }
    }
    private func clickedElsewhere() {
        guard !model.pickerOpen, !model.holdOpen, !model.assistant.popupOpen, model.mode != .idle else { return }
        if model.mode == .expanded && !model.autoClose { return }
        model.alert = nil
        model.setMode(.idle)
    }
    private func trackPointer() {
        if pointerInIsland {
            model.pointerInside = true; leaveTask?.cancel(); leaveTask = nil
        } else if leaveTask == nil {
            model.pointerInside = false
            scheduleLeaveClose()
        }
    }

    // MARK: App lifecycle

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor @Sendable () -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in Task { @MainActor in action() } })
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shutdownComplete { return .terminateNow }
        if !shutdownStarted {
            shutdownStarted = true
            Task {
                await model.shutdown()
                shutdownComplete = true
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
        // Do not enter AppKit's nested termination loop while main-actor cleanup
        // still needs to execute. Retry termination after cleanup finishes.
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { shortcut?.invalidate() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { model.setMode(.expanded); return true }
    @objc private func statusClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Open Attending", action: #selector(openPanel), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Ask AI", action: #selector(askAI), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
            menu.addItem(withTitle: model.prompter.running ? "Stop Teleprompter" : "Teleprompter", action: #selector(togglePrompter), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Setup Guide…", action: #selector(setupGuide), keyEquivalent: "").target = self
            let clean = menu.addItem(withTitle: "Clean Screen", action: #selector(toggleCleanScreen), keyEquivalent: "")
            clean.target = self; clean.state = model.cleanScreen.on ? .on : .off
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Attending", action: #selector(quit), keyEquivalent: "q").target = self
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else { model.setMode(model.mode == .expanded ? .idle : .expanded) }
    }
    @objc private func openPanel() { model.setMode(.expanded) }
    @objc private func askAI() { model.openAssistant() }
    @objc private func settings() { model.open(.settings) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleCleanScreen() { model.cleanScreen.toggle() }
    @objc private func setupGuide() { model.onboarding.show(step: .setup) }
    @objc private func togglePrompter() {
        if model.prompter.running || model.prompter.words > 0 { model.prompter.toggle() } else { model.open(.prompter) }
    }
    private func suspend() {
        model.awake = false; hoverTask?.cancel(); leaveTask?.cancel()
        model.clipboard.stop(); model.mirror.stop()
        model.setMode(.idle); panel.orderOut(nil)
    }
    private func resume() {
        model.awake = true
        if model.clipboardEnabled { model.clipboard.start() }
        lastLayoutKey = ""; layout(animated: false)
        if !model.islandAside { panel.orderFrontRegardless() }
        MediaKeyTap.passThrough = !panel.isVisible
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
