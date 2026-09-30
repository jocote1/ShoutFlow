import Foundation
import CoreAudio
import AudioToolbox

public struct AudioInputDevice: Identifiable, Hashable {
    public let id: AudioDeviceID
    public let name: String
    public let isDefault: Bool

    public init(id: AudioDeviceID, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

public final class AudioDeviceManager {
    public static let shared = AudioDeviceManager()

    private init() {}

    public func getInputDevices() -> [AudioInputDevice] {
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize) == noErr else {
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        let defaultID = getDefaultInputDeviceID()
        var results: [AudioInputDevice] = []

        for id in deviceIDs {
            var streamProp = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamProp, 0, nil, &streamSize) == noErr, streamSize > 0 else {
                continue
            }

            var nameProp = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfName: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(id, &nameProp, 0, nil, &size, &cfName) == noErr,
               let name = cfName?.takeRetainedValue() as String? {
                results.append(AudioInputDevice(id: id, name: name, isDefault: (id == defaultID)))
            }
        }
        return results
    }

    public func getDefaultInputDeviceID() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var currentID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &currentID)
        return currentID
    }

    public func getDefaultInputDeviceName() -> String {
        let defaultID = getDefaultInputDeviceID()
        return getInputDevices().first(where: { $0.id == defaultID })?.name ?? "Unknown Microphone"
    }

    @discardableResult
    public func setDefaultInputDevice(id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var target = id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &target)
        if status == noErr {
            AppLogger.shared.log("[Audio] Default input device switched to ID: \(id)")
            return true
        }
        return false
    }

    public func getBuiltinMicrophone() -> AudioInputDevice? {
        let devices = getInputDevices()
        return devices.first(where: {
            let n = $0.name.lowercased()
            return n.contains("macbook") || n.contains("built-in") || n.contains("internal")
        })
    }

    /// Automatically switches to built-in microphone if the current default device is silent or disconnected
    public func fallbackToBuiltinMicrophoneIfNeeded() {
        if let builtin = getBuiltinMicrophone(), !builtin.isDefault {
            AppLogger.shared.log("[Audio] Switching from inactive/silent input to built-in microphone: \(builtin.name)")
            setDefaultInputDevice(id: builtin.id)
        }
    }
}
