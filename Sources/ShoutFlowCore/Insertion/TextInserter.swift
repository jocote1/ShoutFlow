import AppKit
import Carbon

public final class TextInserter {
    public static let shared = TextInserter()

    private struct SavedClipboardItem {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    private init() {}

    public func insertText(_ text: String, config: ShoutFlowConfig.InsertionConfig) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general

        var savedItems: [SavedClipboardItem] = []
        if config.restoreClipboard {
            // Backup current clipboard contents
            if let items = pasteboard.pasteboardItems {
                for item in items {
                    for type in item.types {
                        if let data = item.data(forType: type) {
                            savedItems.append(SavedClipboardItem(type: type, data: data))
                        }
                    }
                }
            }
        }

        if config.method.lowercased() == "keystrokes" {
            // Direct keystroke simulation
            simulateKeystrokes(text)

            // If user did NOT request restore, also place on clipboard
            if !config.restoreClipboard {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
            return
        }

        // Default & recommended method: Pasteboard + Cmd-V
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Wait a tiny moment to ensure pasteboard sync
        let delayMicros = UInt32(max(10, config.pasteDelayMs) * 1000)
        usleep(delayMicros)

        // Synthesize Cmd+V
        simulateCmdV()

        if config.restoreClipboard && !savedItems.isEmpty {
            // Restore previous clipboard after target app has consumed the paste
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                pasteboard.clearContents()
                for saved in savedItems {
                    pasteboard.setData(saved.data, forType: saved.type)
                }
            }
        }
    }

    private func simulateCmdV() {
        let vKeyCode: CGKeyCode = 9 // 'v' key code in US layout

        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = [] // Clean release without lingering modifiers

        keyDown.post(tap: .cghidEventTap)
        usleep(25_000) // 25ms hold so target apps reliably register the keystroke
        keyUp.post(tap: .cghidEventTap)
    }

    private func simulateKeystrokes(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)

        // Send one full character per event so surrogate pairs (emoji, rare scripts) stay intact
        for character in text {
            var units = Array(String(character).utf16)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            keyDown?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            keyUp?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)

            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            usleep(2000) // 2ms between keystrokes
        }
    }
}
