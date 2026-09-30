import AppKit

public final class SoundManager {
    public static let shared = SoundManager()

    private init() {}

    public func playStartChime() {
        guard ConfigManager.shared.config.ui.soundEffectsEnabled else { return }
        NSSound(named: "Tink")?.play()
    }

    public func playStopChime() {
        guard ConfigManager.shared.config.ui.soundEffectsEnabled else { return }
        NSSound(named: "Pop")?.play()
    }

    public func playCancelChime() {
        guard ConfigManager.shared.config.ui.soundEffectsEnabled else { return }
        NSSound(named: "Basso")?.play()
    }
}
