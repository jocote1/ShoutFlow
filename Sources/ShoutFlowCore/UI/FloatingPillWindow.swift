import AppKit

public enum PillState: Equatable {
    case hidden
    case holdToTalk
    case handsFree(elapsedSeconds: Int, maxSeconds: Int)
    case transcribing
    case cleaning
    case canceled
    case done
}

public final class FloatingPillWindowController: NSWindowController {
    public static let shared = FloatingPillWindowController()

    private var pillPanel: NSPanel!
    private var visualEffectView: NSVisualEffectView!
    private var containerView: NSView!

    // UI elements
    private var iconImageView: NSImageView!
    private var statusDot: NSView!
    private var titleLabel: NSTextField!
    private var subtitleLabel: NSTextField!
    private var spinner: NSProgressIndicator!

    // Audio waveform bars
    private var waveformStack: NSStackView!
    private var waveformBars: [NSView] = []
    private var meterTimer: Timer?

    private var currentState: PillState = .hidden

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 46),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        super.init(window: panel)
        self.pillPanel = panel

        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        containerView = NSView(frame: pillPanel.contentView!.bounds)
        containerView.autoresizingMask = [.width, .height]
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 23
        containerView.layer?.masksToBounds = true
        containerView.layer?.borderWidth = 1.0
        containerView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        visualEffectView = NSVisualEffectView(frame: containerView.bounds)
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.material = .hudWindow
        visualEffectView.state = .active
        visualEffectView.blendingMode = .behindWindow
        containerView.addSubview(visualEffectView)

        // Status Dot / Indicator
        statusDot = NSView(frame: NSRect(x: 14, y: 17, width: 12, height: 12))
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 6
        statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        containerView.addSubview(statusDot)

        // Waveform Bars (3 mini bars)
        waveformStack = NSStackView(frame: NSRect(x: 12, y: 14, width: 18, height: 18))
        waveformStack.orientation = .horizontal
        waveformStack.distribution = .fillEqually
        waveformStack.spacing = 2
        waveformStack.alignment = .centerY

        for _ in 0..<4 {
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.backgroundColor = NSColor.systemRed.cgColor
            bar.layer?.cornerRadius = 1.5
            bar.widthAnchor.constraint(equalToConstant: 2.5).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
            waveformBars.append(bar)
            waveformStack.addArrangedSubview(bar)
        }
        containerView.addSubview(waveformStack)
        waveformStack.isHidden = true

        // Spinner for transcribing
        spinner = NSProgressIndicator(frame: NSRect(x: 14, y: 15, width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        containerView.addSubview(spinner)

        // Title Label
        titleLabel = NSTextField(labelWithString: "Hold to Talk")
        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.frame = NSRect(x: 36, y: 22, width: 170, height: 16)
        containerView.addSubview(titleLabel)

        // Subtitle Label
        subtitleLabel = NSTextField(labelWithString: "Release to transcribe")
        subtitleLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.65)
        subtitleLabel.frame = NSRect(x: 36, y: 8, width: 170, height: 14)
        containerView.addSubview(subtitleLabel)

        pillPanel.contentView?.addSubview(containerView)
    }

    public func updateState(_ state: PillState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentState = state

            switch state {
            case .hidden:
                self.stopAudioMetering()
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.2
                    self.pillPanel.animator().alphaValue = 0.0
                }, completionHandler: {
                    self.pillPanel.orderOut(nil)
                })

            case .holdToTalk:
                self.showPanel()
                self.statusDot.isHidden = true
                self.waveformStack.isHidden = false
                self.spinner.isHidden = true
                self.spinner.stopAnimation(nil)

                self.setBarColors(NSColor.systemRed)
                self.titleLabel.stringValue = "Hold to Talk"
                self.subtitleLabel.stringValue = "Release to paste · Esc cancels"
                self.startAudioMetering()

            case .handsFree(let elapsed, let maxSec):
                self.showPanel()
                self.statusDot.isHidden = true
                self.waveformStack.isHidden = false
                self.spinner.isHidden = true
                self.spinner.stopAnimation(nil)

                self.setBarColors(NSColor.systemOrange)
                self.titleLabel.stringValue = "Hands-Free Session"
                let min = elapsed / 60
                let sec = elapsed % 60
                let maxMin = maxSec / 60
                let maxSecRemainder = maxSec % 60
                self.subtitleLabel.stringValue = String(format: "%d:%02d / %d:%02d · Tap hotkey to stop", min, sec, maxMin, maxSecRemainder)
                self.startAudioMetering()

            case .transcribing:
                self.showPanel()
                self.stopAudioMetering()
                self.statusDot.isHidden = true
                self.waveformStack.isHidden = true
                self.spinner.isHidden = false
                self.spinner.startAnimation(nil)

                self.titleLabel.stringValue = "Transcribing..."
                self.subtitleLabel.stringValue = "Whisper · Esc cancels"

            case .cleaning:
                self.showPanel()
                self.stopAudioMetering()
                self.statusDot.isHidden = true
                self.waveformStack.isHidden = true
                self.spinner.isHidden = false
                self.spinner.startAnimation(nil)

                self.titleLabel.stringValue = "Refining with AI..."
                self.subtitleLabel.stringValue = "Removing fillers & casing"

            case .canceled:
                self.stopAudioMetering()
                self.waveformStack.isHidden = true
                self.spinner.isHidden = true
                self.spinner.stopAnimation(nil)
                self.statusDot.isHidden = false
                self.statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor

                self.titleLabel.stringValue = "Canceled"
                self.subtitleLabel.stringValue = "Recording discarded"

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if self.currentState == .canceled {
                        self.updateState(.hidden)
                    }
                }

            case .done:
                self.stopAudioMetering()
                self.waveformStack.isHidden = true
                self.spinner.isHidden = true
                self.spinner.stopAnimation(nil)
                self.statusDot.isHidden = false
                self.statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor

                self.titleLabel.stringValue = "Pasted ✓"
                self.subtitleLabel.stringValue = "Clipboard updated"

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    if self.currentState == .done {
                        self.updateState(.hidden)
                    }
                }
            }
        }
    }

    private func showPanel() {
        reposition()
        if !pillPanel.isVisible || pillPanel.alphaValue < 0.1 {
            pillPanel.alphaValue = 0.0
            pillPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                self.pillPanel.animator().alphaValue = 1.0
            }
        }
    }

    private func reposition() {
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.visibleFrame
        let pillWidth: CGFloat = 224
        let pillHeight: CGFloat = 46

        let x = screenRect.origin.x + (screenRect.width - pillWidth) / 2.0
        let pos = ConfigManager.shared.config.ui.pillPosition.lowercased()

        let y: CGFloat
        if pos == "top" {
            y = screenRect.maxY - pillHeight - 20
        } else {
            // Default bottom
            y = screenRect.minY + 40
        }

        pillPanel.setFrame(NSRect(x: x, y: y, width: pillWidth, height: pillHeight), display: true)
    }

    private func setBarColors(_ color: NSColor) {
        for bar in waveformBars {
            bar.layer?.backgroundColor = color.cgColor
        }
    }

    private func startAudioMetering() {
        guard meterTimer == nil else { return }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let level = AudioRecorder.shared.getAudioLevel()
            self.animateWaveform(level: level)
        }
    }

    private func stopAudioMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        for bar in waveformBars {
            bar.constraints.first { $0.firstAttribute == .height }?.constant = 6
        }
    }

    private func animateWaveform(level: Float) {
        // Modulate bars with slight variance
        let multipliers: [CGFloat] = [0.8, 1.2, 1.4, 0.9]
        for (i, bar) in waveformBars.enumerated() {
            let mult = multipliers[i % multipliers.count]
            let h = max(4.0, min(16.0, CGFloat(level) * 16.0 * mult))
            bar.constraints.first { $0.firstAttribute == .height }?.constant = h
        }
    }
}
