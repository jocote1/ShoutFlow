import AppKit
import Carbon

public protocol HotKeyMonitorDelegate: AnyObject {
    func hotKeyDidBeginHold()
    func hotKeyDidReleaseHold()
    func hotKeyDidEnterHandsFree()
    func hotKeyDidExitHandsFree()
    func hotKeyDidCancel()
    func handsFreeTimerDidTick(elapsedSeconds: Int, maxSeconds: Int)
}

public enum MonitorState {
    case idle
    case holding(startTime: Date)
    case waitingForDoubleTap(firstReleaseTime: Date)
    case handsFree(startTime: Date)
    case transcribing
}

public final class HotKeyMonitor {
    public weak var delegate: HotKeyMonitorDelegate?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var retryTimer: Timer?
    private var holdPollTimer: Timer?

    private var state: MonitorState = .idle
    private var isHotkeyCurrentlyPressed = false
    private var doubleTapWorkItem: DispatchWorkItem?
    private var handsFreeTimer: Timer?
    private var handsFreeElapsedSeconds = 0

    private let configManager = ConfigManager.shared

    public init() {}

    deinit {
        stop()
    }

    public func start() {
        stop()
        setupEventTap()
        setupNSEventMonitors()
        startPermissionRetryTimer()
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }

        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }

        retryTimer?.invalidate()
        retryTimer = nil

        cancelTimers()
        state = .idle
    }

    private func cancelTimers() {
        doubleTapWorkItem?.cancel()
        doubleTapWorkItem = nil
        handsFreeTimer?.invalidate()
        handsFreeTimer = nil
        stopHoldPolling()
    }

    public func setTranscribingState() {
        stopHoldPolling()
        state = .transcribing
    }

    public func setIdleState() {
        cancelTimers()
        state = .idle
        isHotkeyCurrentlyPressed = false
    }

    // MARK: - Auto-Reconnect Timer for Accessibility

    private func startPermissionRetryTimer() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.eventTap == nil && Permissions.isAccessibilityGranted {
                AppLogger.shared.log("[HotKey] Accessibility granted! Reconnecting CGEvent.tapCreate...")
                self.setupEventTap()
            }
        }
    }

    // MARK: - Hardware Level Hold Polling
    // Solves macOS Apple Silicon firmware dropping Fn/Globe keyUp events

    private func startHoldPolling() {
        holdPollTimer?.invalidate()
        // Poll every 35ms while holding to detect physical release even if macOS drops the release event
        holdPollTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard case .holding = self.state else {
                self.stopHoldPolling()
                return
            }

            let hotkeyType = self.configManager.config.hotkey.type.lowercased()
            let currentFlags = CGEventSource.flagsState(.combinedSessionState)
            var isStillHeld = false

            switch hotkeyType {
            case "fn":
                let fnMask: UInt64 = 0x800000
                isStillHeld = (currentFlags.rawValue & fnMask) != 0 || currentFlags.contains(.maskSecondaryFn)
            case "rightcommand":
                isStillHeld = currentFlags.contains(.maskCommand)
            case "rightoption":
                isStillHeld = currentFlags.contains(.maskAlternate)
            case "rightcontrol":
                isStillHeld = currentFlags.contains(.maskControl)
            case "ctrlspace":
                isStillHeld = currentFlags.contains(.maskControl) && CGEventSource.keyState(.combinedSessionState, key: 49)
            case "optspace":
                isStillHeld = currentFlags.contains(.maskAlternate) && CGEventSource.keyState(.combinedSessionState, key: 49)
            default:
                let fnMask: UInt64 = 0x800000
                isStillHeld = (currentFlags.rawValue & fnMask) != 0 || currentFlags.contains(.maskSecondaryFn)
            }

            if !isStillHeld {
                self.stopHoldPolling()
                self.isHotkeyCurrentlyPressed = false
                AppLogger.shared.log("[HotKey] Hardware release detected via flagsState. Triggering onHotkeyUp().")
                DispatchQueue.main.async {
                    self.onHotkeyUp()
                }
            }
        }
    }

    private func stopHoldPolling() {
        holdPollTimer?.invalidate()
        holdPollTimer = nil
    }

    // MARK: - Event Tap Setup

    public func setupEventTap() {
        guard eventTap == nil else { return }

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) |
                                    (1 << CGEventType.keyDown.rawValue) |
                                    (1 << CGEventType.keyUp.rawValue)

        let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passRetained(event)
                }
                let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleCGEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: observer
        ) else {
            AppLogger.shared.log("[HotKey] CGEvent.tapCreate pending Accessibility permission. Using NSEvent monitors.")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        AppLogger.shared.log("[HotKey] CGEvent.tapCreate successfully connected with Accessibility!")
    }

    private func setupNSEventMonitors() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
                self?.handleNSEvent(event)
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
                self?.handleNSEvent(event)
                return event
            }
        }
    }

    // MARK: - Event Processing

    private func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        // 1. Passive Esc Monitoring (KeyCode 53 = kVK_Escape)
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 53 {
                DispatchQueue.main.async { [weak self] in
                    self?.handleEscPressed()
                }
                return Unmanaged.passRetained(event)
            }
        }

        // 2. Modifier Hotkey Monitoring
        if type == .flagsChanged || type == .keyDown || type == .keyUp {
            let flags = event.flags
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            handleKeyEvent(flags: flags, keyCode: keyCode, isKeyDownEvent: (type == .keyDown))
        }

        return Unmanaged.passRetained(event)
    }

    private func handleNSEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 {
            handleEscPressed()
            return
        }

        // If eventTap is connected, let CGEventTap handle it to avoid duplicate triggers
        if eventTap != nil {
            return
        }

        if event.type == .flagsChanged || event.type == .keyDown || event.type == .keyUp {
            let cgFlags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            handleKeyEvent(flags: cgFlags, keyCode: Int64(event.keyCode), isKeyDownEvent: (event.type == .keyDown))
        }
    }

    private func handleEscPressed() {
        switch state {
        case .holding, .waitingForDoubleTap, .handsFree:
            AppLogger.shared.log("[HotKey] Esc pressed: canceling active recording")
            cancelTimers()
            state = .idle
            isHotkeyCurrentlyPressed = false
            delegate?.hotKeyDidCancel()
        case .transcribing:
            AppLogger.shared.log("[HotKey] Esc pressed: aborting in-flight transcription")
            cancelTimers()
            state = .idle
            isHotkeyCurrentlyPressed = false
            delegate?.hotKeyDidCancel()
        case .idle:
            break
        }
    }

    private func handleKeyEvent(flags: CGEventFlags, keyCode: Int64, isKeyDownEvent: Bool) {
        let hotkeyType = configManager.config.hotkey.type.lowercased()

        var isPressed = false

        switch hotkeyType {
        case "fn":
            let fnMask: UInt64 = 0x800000
            let hasFnFlag = (flags.rawValue & fnMask) != 0 || flags.contains(.maskSecondaryFn)
            isPressed = hasFnFlag || (keyCode == 63 && hasFnFlag)

        case "rightcommand":
            isPressed = (keyCode == 54) && flags.contains(.maskCommand)

        case "rightoption":
            isPressed = (keyCode == 61) && flags.contains(.maskAlternate)

        case "rightcontrol":
            isPressed = (keyCode == 62) && flags.contains(.maskControl)

        case "ctrlspace":
            if keyCode == 49 && flags.contains(.maskControl) {
                isPressed = isKeyDownEvent
            }

        case "optspace":
            if keyCode == 49 && flags.contains(.maskAlternate) {
                isPressed = isKeyDownEvent
            }

        default:
            let fnMask: UInt64 = 0x800000
            isPressed = (flags.rawValue & fnMask) != 0 || flags.contains(.maskSecondaryFn) || keyCode == 63
        }

        if isPressed && !isHotkeyCurrentlyPressed {
            isHotkeyCurrentlyPressed = true
            AppLogger.shared.log("[HotKey] Hotkey pressed down (type: \(hotkeyType), keyCode: \(keyCode))")
            DispatchQueue.main.async { [weak self] in
                self?.onHotkeyDown()
            }
        } else if !isPressed && isHotkeyCurrentlyPressed {
            isHotkeyCurrentlyPressed = false
            AppLogger.shared.log("[HotKey] Hotkey released via event (type: \(hotkeyType))")
            DispatchQueue.main.async { [weak self] in
                self?.onHotkeyUp()
            }
        }
    }

    // MARK: - State Machine Transitions

    private func onHotkeyDown() {
        switch state {
        case .idle:
            state = .holding(startTime: Date())
            startHoldPolling()
            delegate?.hotKeyDidBeginHold()

        case .waitingForDoubleTap:
            cancelTimers()
            startHandsFreeSession()

        case .handsFree:
            stopHandsFreeSession()

        case .holding, .transcribing:
            break
        }
    }

    private func onHotkeyUp() {
        stopHoldPolling()
        let thresholdMs = configManager.config.hotkey.doubleTapThresholdMs
        let thresholdSec = Double(thresholdMs) / 1000.0

        switch state {
        case .holding(let startTime):
            let duration = Date().timeIntervalSince(startTime)
            if duration >= thresholdSec {
                state = .transcribing
                delegate?.hotKeyDidReleaseHold()
            } else {
                state = .waitingForDoubleTap(firstReleaseTime: Date())

                let workItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    if case .waitingForDoubleTap = self.state {
                        self.state = .transcribing
                        self.delegate?.hotKeyDidReleaseHold()
                    }
                }
                self.doubleTapWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + thresholdSec, execute: workItem)
            }

        case .waitingForDoubleTap, .handsFree, .transcribing, .idle:
            break
        }
    }

    private func startHandsFreeSession() {
        cancelTimers()
        handsFreeElapsedSeconds = 0
        state = .handsFree(startTime: Date())
        delegate?.hotKeyDidEnterHandsFree()

        let maxSeconds = configManager.config.handsFree.autoStopTimeoutSeconds

        handsFreeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.handsFreeElapsedSeconds += 1
            self.delegate?.handsFreeTimerDidTick(elapsedSeconds: self.handsFreeElapsedSeconds, maxSeconds: maxSeconds)

            if self.handsFreeElapsedSeconds >= maxSeconds {
                AppLogger.shared.log("[HotKey] Hands-free auto-stop safety timer reached \(maxSeconds) seconds")
                self.stopHandsFreeSession()
            }
        }
    }

    private func stopHandsFreeSession() {
        cancelTimers()
        state = .transcribing
        delegate?.hotKeyDidExitHandsFree()
    }
}
