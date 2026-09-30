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

    private var state: MonitorState = .idle
    private var isHotkeyCurrentlyPressed = false
    private var doubleTapWorkItem: DispatchWorkItem?
    private var handsFreeTimer: Timer?
    private var handsFreeElapsedSeconds = 0
    private var recentTapTimestamps: [Date] = []

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
        recentTapTimestamps.removeAll()
    }

    private func cancelTimers() {
        doubleTapWorkItem?.cancel()
        doubleTapWorkItem = nil
        handsFreeTimer?.invalidate()
        handsFreeTimer = nil
    }

    public func setTranscribingState() {
        cancelTimers()
        state = .transcribing
    }

    public func setIdleState() {
        cancelTimers()
        state = .idle
        isHotkeyCurrentlyPressed = false
        recentTapTimestamps.removeAll()
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

    // MARK: - Event Tap Setup

    public func setupEventTap() {
        guard eventTap == nil else { return }

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) |
                                    (1 << CGEventType.keyDown.rawValue) |
                                    (1 << CGEventType.keyUp.rawValue) |
                                    (1 << CGEventType.otherMouseDown.rawValue) |
                                    (1 << CGEventType.otherMouseUp.rawValue)

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
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp, .otherMouseDown, .otherMouseUp]
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handleNSEvent(event)
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
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

        // 2. Mouse Button 4 & 5 Monitoring (Swallow event if target hotkey)
        if type == .otherMouseDown || type == .otherMouseUp {
            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            let hotkeyType = configManager.config.hotkey.type.lowercased()
            // Button 3 = Mouse Button 4 (Back), Button 4 = Mouse Button 5 (Forward)
            let isTargetMouse = (hotkeyType == "mouse4" && buttonNumber == 3) ||
                                (hotkeyType == "mouse5" && buttonNumber == 4)
            if isTargetMouse {
                let isDown = (type == .otherMouseDown)
                handleMouseEvent(buttonNumber: buttonNumber, isDown: isDown)
                return nil // Swallow event to avoid unwanted navigation/clicks in other apps
            }
            return Unmanaged.passRetained(event)
        }

        // 3. Modifier Hotkey Monitoring
        if type == .flagsChanged || type == .keyDown || type == .keyUp {
            let flags = event.flags
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            handleKeyEvent(flags: flags, keyCode: keyCode, isFlagsChanged: (type == .flagsChanged), isKeyDownEvent: (type == .keyDown))
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

        if event.type == .otherMouseDown || event.type == .otherMouseUp {
            let buttonNumber = event.buttonNumber
            let hotkeyType = configManager.config.hotkey.type.lowercased()
            let isTargetMouse = (hotkeyType == "mouse4" && buttonNumber == 3) ||
                                (hotkeyType == "mouse5" && buttonNumber == 4)
            if isTargetMouse {
                let isDown = (event.type == .otherMouseDown)
                handleMouseEvent(buttonNumber: Int64(buttonNumber), isDown: isDown)
            }
            return
        }

        if event.type == .flagsChanged || event.type == .keyDown || event.type == .keyUp {
            let cgFlags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            handleKeyEvent(flags: cgFlags, keyCode: Int64(event.keyCode), isFlagsChanged: (event.type == .flagsChanged), isKeyDownEvent: (event.type == .keyDown))
        }
    }

    private func handleMouseEvent(buttonNumber: Int64, isDown: Bool) {
        let hotkeyType = configManager.config.hotkey.type.lowercased()
        if isDown && !isHotkeyCurrentlyPressed {
            isHotkeyCurrentlyPressed = true
            AppLogger.shared.log("[HotKey] Mouse hotkey pressed down (type: \(hotkeyType), button: \(buttonNumber))")
            DispatchQueue.main.async { [weak self] in
                self?.onHotkeyDown()
            }
        } else if !isDown && isHotkeyCurrentlyPressed {
            isHotkeyCurrentlyPressed = false
            AppLogger.shared.log("[HotKey] Mouse hotkey released (type: \(hotkeyType), button: \(buttonNumber))")
            DispatchQueue.main.async { [weak self] in
                self?.onHotkeyUp()
            }
        }
    }

    private func handleEscPressed() {
        recentTapTimestamps.removeAll()
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

    public static func evaluateKeyIsPressed(
        hotkeyType: String,
        flags: CGEventFlags,
        keyCode: Int64,
        isFlagsChanged: Bool,
        isKeyDownEvent: Bool,
        isCurrentlyPressed: Bool
    ) -> Bool? {
        let type = hotkeyType.lowercased()
        switch type {
        case "fn":
            // Strict filtering: Arrow keys (123-126) and other extended keys share the maskSecondaryFn flag on macOS!
            // The physical Fn/Globe key has keyCode 63 (kVK_Function) and only emits flagsChanged events.
            guard isFlagsChanged || keyCode == 63 else { return nil }
            guard keyCode == 63 || isCurrentlyPressed else { return nil }

            let fnMask: UInt64 = 0x800000
            return (flags.rawValue & fnMask) != 0 || flags.contains(.maskSecondaryFn)

        case "rightcommand":
            guard isFlagsChanged || keyCode == 54 else { return nil }
            guard keyCode == 54 || isCurrentlyPressed else { return nil }
            return flags.contains(.maskCommand) && (keyCode == 54 || isCurrentlyPressed)

        case "rightoption":
            guard isFlagsChanged || keyCode == 61 else { return nil }
            guard keyCode == 61 || isCurrentlyPressed else { return nil }
            return flags.contains(.maskAlternate) && (keyCode == 61 || isCurrentlyPressed)

        case "rightcontrol":
            guard isFlagsChanged || keyCode == 62 else { return nil }
            guard keyCode == 62 || isCurrentlyPressed else { return nil }
            return flags.contains(.maskControl) && (keyCode == 62 || isCurrentlyPressed)

        case "ctrlspace":
            if keyCode == 49 && flags.contains(.maskControl) {
                return isKeyDownEvent
            } else if isCurrentlyPressed {
                return flags.contains(.maskControl)
            } else {
                return nil
            }

        case "optspace":
            if keyCode == 49 && flags.contains(.maskAlternate) {
                return isKeyDownEvent
            } else if isCurrentlyPressed {
                return flags.contains(.maskAlternate)
            } else {
                return nil
            }

        case "mouse4", "mouse5":
            return nil

        default:
            guard isFlagsChanged || keyCode == 63 else { return nil }
            guard keyCode == 63 || isCurrentlyPressed else { return nil }
            let fnMask: UInt64 = 0x800000
            return (flags.rawValue & fnMask) != 0 || flags.contains(.maskSecondaryFn)
        }
    }

    private func handleKeyEvent(flags: CGEventFlags, keyCode: Int64, isFlagsChanged: Bool, isKeyDownEvent: Bool) {
        let hotkeyType = configManager.config.hotkey.type
        guard let isPressed = HotKeyMonitor.evaluateKeyIsPressed(
            hotkeyType: hotkeyType,
            flags: flags,
            keyCode: keyCode,
            isFlagsChanged: isFlagsChanged,
            isKeyDownEvent: isKeyDownEvent,
            isCurrentlyPressed: isHotkeyCurrentlyPressed
        ) else {
            return
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
        let now = Date()
        recentTapTimestamps = recentTapTimestamps.filter { now.timeIntervalSince($0) < 0.85 }
        recentTapTimestamps.append(now)

        if configManager.config.hotkey.tripleTapToCancel && recentTapTimestamps.count >= 3 {
            switch state {
            case .holding, .waitingForDoubleTap, .handsFree, .transcribing:
                AppLogger.shared.log("[HotKey] Triple-tap cancel triggered (count=\(recentTapTimestamps.count))!")
                recentTapTimestamps.removeAll()
                cancelTimers()
                state = .idle
                isHotkeyCurrentlyPressed = false
                delegate?.hotKeyDidCancel()
                return
            case .idle:
                break
            }
        }

        switch state {
        case .idle:
            state = .holding(startTime: Date())
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
        recentTapTimestamps.removeAll()
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
