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

        let source = CGEventSource(stateID: .combinedSessionState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func simulateKeystrokes(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(text.utf16)

        // Type in chunks or individual unicode characters
        for char in utf16 {
            var unit = char
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            keyDown?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            keyUp?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)

            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            usleep(2000) // 2ms between keystrokes
        }
    }
}
