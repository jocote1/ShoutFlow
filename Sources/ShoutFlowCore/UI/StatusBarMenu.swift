import AppKit

public protocol StatusBarMenuDelegate: AnyObject {
    func statusBarDidToggleEnabled(_ isEnabled: Bool)
    func statusBarDidChangeProvider(_ provider: String)
}

public final class StatusBarMenu: NSObject, NSMenuDelegate {
    public weak var delegate: StatusBarMenuDelegate?

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    public private(set) var isEnabled = true

    private var enabledMenuItem: NSMenuItem!
    private var manualDictateItem: NSMenuItem!
    private var priorityProviderItem: NSMenuItem!
    private var localWhisperItem: NSMenuItem!
    private var groqWhisperItem: NSMenuItem!
    private var openaiWhisperItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var hotkeyItem: NSMenuItem!

    public override init() {
        super.init()
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            updateStatusItemIcon()
            button.toolTip = "ShoutFlow AI Dictation"
        }

        buildMenu()
    }

    private func updateStatusItemIcon() {
        guard let button = statusItem.button else { return }

        let symbolName = isEnabled ? "waveform" : "waveform.badge.minus"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ShoutFlow") {
            image.isTemplate = true
            button.image = image
        } else {
            // Fallback text if system symbols not available
            button.title = isEnabled ? "ShoutFlow" : "ShoutFlow (off)"
        }
    }

    private func buildMenu() {
        menu = NSMenu()
        menu.delegate = self

        // App Header
        let titleItem = NSMenuItem(title: "ShoutFlow", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        // On/Off Toggle
        enabledMenuItem = NSMenuItem(title: "ShoutFlow Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledMenuItem.target = self
        enabledMenuItem.state = isEnabled ? .on : .off
        menu.addItem(enabledMenuItem)

        // Manual / Test Dictation Trigger
        manualDictateItem = NSMenuItem(title: "Start Dictation (Test)", action: #selector(toggleManualDictation), keyEquivalent: "d")
        manualDictateItem.target = self
        menu.addItem(manualDictateItem)

        menu.addItem(NSMenuItem.separator())

        // Engine Submenu
        let engineItem = NSMenuItem(title: "Transcription Provider", action: nil, keyEquivalent: "")
        let engineSubmenu = NSMenu()

        priorityProviderItem = NSMenuItem(title: "Automatic Fallback (Local, then Groq, then OpenAI)", action: #selector(selectPriorityProvider), keyEquivalent: "")
        priorityProviderItem.target = self
        engineSubmenu.addItem(priorityProviderItem)

        localWhisperItem = NSMenuItem(title: "Local Whisper (whisper.cpp)", action: #selector(selectLocalWhisper), keyEquivalent: "")
        localWhisperItem.target = self
        engineSubmenu.addItem(localWhisperItem)

        groqWhisperItem = NSMenuItem(title: "Groq Whisper API", action: #selector(selectGroqWhisper), keyEquivalent: "")
        groqWhisperItem.target = self
        engineSubmenu.addItem(groqWhisperItem)

        openaiWhisperItem = NSMenuItem(title: "OpenAI Transcription API", action: #selector(selectOpenAIWhisper), keyEquivalent: "")
        openaiWhisperItem.target = self
        engineSubmenu.addItem(openaiWhisperItem)

        engineItem.submenu = engineSubmenu
        menu.addItem(engineItem)

        // Hotkey Display
        hotkeyItem = NSMenuItem(title: StatusBarMenu.hotkeyMenuTitle(), action: #selector(openSettingsWindow), keyEquivalent: "")
        hotkeyItem.target = self
        menu.addItem(hotkeyItem)

        menu.addItem(NSMenuItem.separator())

        // Settings Window
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Local Models Management & Confirmation
        let modelStatusItem = NSMenuItem(title: "Local Models & Downloads...", action: #selector(showModelStatusAndDownload), keyEquivalent: "")
        modelStatusItem.target = self
        menu.addItem(modelStatusItem)

        let logItem = NSMenuItem(title: "View Debug Logs (shoutflow.log)...", action: #selector(openLogFile), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(NSMenuItem.separator())

        // Launch at login
        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        // Check Permissions
        let permItem = NSMenuItem(title: "Check System Permissions...", action: #selector(checkPermissions), keyEquivalent: "")
        permItem.target = self
        menu.addItem(permItem)

        let fixPermItem = NSMenuItem(title: "Fix / Reset Accessibility...", action: #selector(resetAccessibilityAndPrompt), keyEquivalent: "")
        fixPermItem.target = self
        menu.addItem(fixPermItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit ShoutFlow", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshEngineSelection()
    }

    public func menuWillOpen(_ menu: NSMenu) {
        enabledMenuItem.state = isEnabled ? .on : .off
        launchAtLoginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        refreshHotkeyTitle()
        refreshEngineSelection()
    }

    public func refreshHotkeyTitle() {
        hotkeyItem?.title = StatusBarMenu.hotkeyMenuTitle()
    }

    private static func hotkeyMenuTitle() -> String {
        let hotkeyType = ConfigManager.shared.config.hotkey.type
        let hotkeyDisplay: String
        switch hotkeyType.lowercased() {
        case "fn": hotkeyDisplay = "Fn (Globe)"
        case "rightoption": hotkeyDisplay = "Right Option"
        case "mouse4": hotkeyDisplay = "Mouse Button 4"
        case "mouse5": hotkeyDisplay = "Mouse Button 5"
        case "rightcommand": hotkeyDisplay = "Right Command"
        case "rightcontrol": hotkeyDisplay = "Right Control"
        case "ctrlspace": hotkeyDisplay = "Control + Space"
        case "optspace": hotkeyDisplay = "Option + Space"
        default: hotkeyDisplay = hotkeyType.capitalized
        }
        return "Hotkey: \(hotkeyDisplay) (hold to talk, 2 taps for hands-free, 3 taps to cancel)"
    }

    private func refreshEngineSelection() {
        let currentProvider = ConfigManager.shared.config.transcription.provider.lowercased()
        priorityProviderItem.state = (currentProvider == "priority") ? .on : .off
        localWhisperItem.state = (currentProvider == "local") ? .on : .off
        groqWhisperItem.state = (currentProvider == "groq") ? .on : .off
        openaiWhisperItem.state = (currentProvider == "openai") ? .on : .off
    }

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        updateStatusItemIcon()
        enabledMenuItem.state = isEnabled ? .on : .off
        delegate?.statusBarDidToggleEnabled(isEnabled)
    }

    @objc private func selectPriorityProvider() {
        ConfigManager.shared.updateTranscriptionProvider("priority")
        refreshEngineSelection()
        delegate?.statusBarDidChangeProvider("priority")
    }

    @objc private func selectLocalWhisper() {
        ConfigManager.shared.updateTranscriptionProvider("local")
        refreshEngineSelection()
        delegate?.statusBarDidChangeProvider("local")
    }

    @objc private func selectGroqWhisper() {
        ConfigManager.shared.updateTranscriptionProvider("groq")
        refreshEngineSelection()
        delegate?.statusBarDidChangeProvider("groq")
    }

    @objc private func selectOpenAIWhisper() {
        ConfigManager.shared.updateTranscriptionProvider("openai")
        refreshEngineSelection()
        delegate?.statusBarDidChangeProvider("openai")
    }

    @objc private func openSettingsWindow() {
        SettingsWindowController.shared.showSettingsWindow()
    }

    @objc private func openConfig() {
        openSettingsWindow()
    }

    @objc private func showModelStatusAndDownload() {
        let models = ModelManager.availableModels
        let installed = models.filter { $0.isInstalled }

        let alert = NSAlert()
        alert.messageText = "Local Whisper Models"

        if installed.isEmpty {
            alert.informativeText = "No local whisper models are installed yet.\n\nOpen Settings to download the recommended 'small' model (~461 MB) for fast, offline transcription."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            let resp = alert.runModal()
            if resp == .alertFirstButtonReturn {
                openSettingsWindow()
            }
        } else {
            var info = "Installed models:\n"
            for m in installed {
                let isActive = ModelManager.shared.isModelActive(m)
                let tag = isActive ? " (active)" : ""
                info += "- \(m.name), \(m.diskSizeString ?? m.estimatedSize)\(tag)\n"
            }
            info += "\nOffline dictation is ready to use."
            alert.informativeText = info
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Settings...")
            let resp = alert.runModal()
            if resp == .alertSecondButtonReturn {
                openSettingsWindow()
            }
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let newState = !LaunchAtLogin.isEnabled
        LaunchAtLogin.isEnabled = newState
        launchAtLoginItem.state = newState ? .on : .off
    }

    @objc private func checkPermissions() {
        let isAccess = Permissions.isAccessibilityGranted
        let isMic = Permissions.isMicrophoneGranted

        let alert = NSAlert()
        alert.messageText = "ShoutFlow System Permissions"
        var info = ""
        info += "Accessibility: \(isAccess ? "Granted" : "Missing (required for the hotkey and Esc)")\n"
        info += "Microphone: \(isMic ? "Granted" : "Missing (required to record your voice)")\n\n"
        info += "If hotkeys or pasting do not work, make sure ShoutFlow (or Terminal) is enabled in macOS System Settings."

        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        if !isAccess {
            alert.addButton(withTitle: "Open Accessibility Settings")
        }
        if !isMic {
            alert.addButton(withTitle: "Open Microphone Settings")
        }

        let resp = alert.runModal()
        if resp == .alertSecondButtonReturn {
            if !isAccess {
                Permissions.openAccessibilitySettings()
            } else if !isMic {
                Permissions.openMicrophoneSettings()
            }
        } else if resp == .alertThirdButtonReturn {
            Permissions.openMicrophoneSettings()
        }
    }

    public func setManualRecordingState(isRecording: Bool) {
        DispatchQueue.main.async { [weak self] in
            if isRecording {
                self?.manualDictateItem.title = "Stop Dictation and Paste"
            } else {
                self?.manualDictateItem.title = "Start Dictation (Test)"
            }
        }
    }

    @objc private func toggleManualDictation() {
        AppDelegate.shared?.toggleManualDictation()
    }

    @objc private func openLogFile() {
        let url = AppLogger.logFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            AppLogger.shared.log("Log initialized.")
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func resetAccessibilityAndPrompt() {
        let alert = NSAlert()
        alert.messageText = "Fix macOS Accessibility"
        alert.informativeText = """
        If macOS System Settings shows ShoutFlow as enabled but dictation still does not respond:

        1. Open System Settings > Privacy & Security > Accessibility.
        2. Click on 'ShoutFlow' and click the minus (-) button to remove it.
        3. Click the (+) button and re-add ShoutFlow from your Applications folder.

        Click 'Open System Settings' below to open the settings pane now.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Request Permission Now")
        alert.addButton(withTitle: "Cancel")

        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            Permissions.openAccessibilitySettings()
        } else if resp == .alertSecondButtonReturn {
            Permissions.requestAccessibility()
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
