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

    private var state: MonitorState = .idle
    private var isFnCurrentlyPressed = false
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
        setupGlobalMonitorFallback()
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

        cancelTimers()
        state = .idle
    }

    private func cancelTimers() {
        doubleTapWorkItem?.cancel()
        doubleTapWorkItem = nil
        handsFreeTimer?.invalidate()
        handsFreeTimer = nil
    }

    public func setTranscribingState() {
        state = .transcribing
    }

    public func setIdleState() {
        cancelTimers()
        state = .idle
        isFnCurrentlyPressed = false
    }

    // MARK: - Event Tap Setup

    private func setupEventTap() {
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
            print("[ShoutFlow] Note: CGEvent.tapCreate requires Accessibility permissions. Falling back to global NSEvent monitor.")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func setupGlobalMonitorFallback() {
        guard globalMonitor == nil else { return }

        // Global monitor for modifier flags and passive key down
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self = self else { return }
            self.handleNSEvent(event)
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
                // ALWAYS return unchanged so Esc reaches the active app!
                return Unmanaged.passRetained(event)
            }
        }

        // 2. Modifier Hotkey Monitoring (Fn or other modifiers)
        if type == .flagsChanged {
            let flags = event.flags
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            handleModifierChange(flags: flags, keyCode: keyCode)
        }

        return Unmanaged.passRetained(event)
    }

    private func handleNSEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 {
            handleEscPressed()
        } else if event.type == .flagsChanged {
            let cgFlags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            handleModifierChange(flags: cgFlags, keyCode: Int64(event.keyCode))
        }
    }

    private func handleEscPressed() {
        switch state {
        case .holding, .waitingForDoubleTap, .handsFree:
            cancelTimers()
            state = .idle
            isFnCurrentlyPressed = false
            delegate?.hotKeyDidCancel()
        case .transcribing:
            cancelTimers()
            state = .idle
            isFnCurrentlyPressed = false
            delegate?.hotKeyDidCancel()
        case .idle:
            break
        }
    }

    private func handleModifierChange(flags: CGEventFlags, keyCode: Int64) {
        let hotkeyType = configManager.config.hotkey.type.lowercased()

        let isPressed: Bool
        if hotkeyType == "fn" {
            // Check secondary Fn mask (0x800000 / maskSecondaryFn) or function modifier
            let fnMask: UInt64 = 0x800000
            isPressed = (flags.rawValue & fnMask) != 0 || flags.contains(.maskSecondaryFn)
        } else if hotkeyType == "rightcommand" {
            isPressed = (keyCode == 54) && flags.contains(.maskCommand)
        } else if hotkeyType == "rightoption" {
            isPressed = (keyCode == 61) && flags.contains(.maskAlternate)
        } else if hotkeyType == "rightcontrol" {
            isPressed = (keyCode == 62) && flags.contains(.maskControl)
        } else {
            // Default to Fn
            let fnMask: UInt64 = 0x800000
            isPressed = (flags.rawValue & fnMask) != 0 || flags.contains(.maskSecondaryFn)
        }

        if isPressed && !isFnCurrentlyPressed {
            // Key Down Transition
            isFnCurrentlyPressed = true
            DispatchQueue.main.async { [weak self] in
                self?.onHotkeyDown()
            }
        } else if !isPressed && isFnCurrentlyPressed {
            // Key Up Transition
            isFnCurrentlyPressed = false
            DispatchQueue.main.async { [weak self] in
                self?.onHotkeyUp()
            }
        }
    }

    // MARK: - State Machine Transitions

    private func onHotkeyDown() {
        switch state {
        case .idle:
            // First press: start holding mode
            state = .holding(startTime: Date())
            delegate?.hotKeyDidBeginHold()

        case .waitingForDoubleTap:
            // Second press within window! Double tap confirmed!
            cancelTimers()
            startHandsFreeSession()

        case .handsFree:
            // Tapping again while in hands-free stops the session!
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
                // Held longer than double-tap threshold: definitive hold-and-release!
                state = .transcribing
                delegate?.hotKeyDidReleaseHold()
            } else {
                // Quick tap: wait briefly to see if a second tap occurs (for hands-free)
                state = .waitingForDoubleTap(firstReleaseTime: Date())

                let workItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    if case .waitingForDoubleTap = self.state {
                        // Double tap did not happen. Treat as single quick tap release!
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

        // Timer that ticks every second and auto-stops at maxSeconds
        handsFreeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.handsFreeElapsedSeconds += 1
            self.delegate?.handsFreeTimerDidTick(elapsedSeconds: self.handsFreeElapsedSeconds, maxSeconds: maxSeconds)

            if self.handsFreeElapsedSeconds >= maxSeconds {
                print("[ShoutFlow] Hands-free auto-stop timer reached 5 minutes limit.")
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
