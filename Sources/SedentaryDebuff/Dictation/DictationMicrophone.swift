import CoreAudio
import Foundation

/// 一个可用的麦克风（输入设备）。
struct DictationMicrophoneInfo: Equatable {
    let uid: String
    let name: String
}

/// macOS 的 AVAudioEngine 只能采「系统默认输入设备」，没有给单个应用指定麦克风的 API。
/// 因此“选择麦克风”在实现上是：录音期间用 CoreAudio 把系统默认输入设备切到所选麦克风，
/// 停止录音/锁屏/退出时再还原。这里封装所有 CoreAudio HAL 的读写，不持有任何状态。
enum DictationMicrophone {
    /// 当前所有可作为输入来源的设备（过滤掉系统隐藏项）。
    static func availableInputDevices() -> [DictationMicrophoneInfo] {
        guard let devices = deviceIDs() else { return [] }
        var result: [DictationMicrophoneInfo] = []
        for device in devices {
            guard isInputDevice(device), isAlive(device), !isHidden(device) else { continue }
            guard let uid = deviceUID(device), let name = deviceName(device) else { continue }
            result.append(DictationMicrophoneInfo(uid: uid, name: name))
        }
        return result
    }

    /// 当前系统默认输入设备的 uid。
    static func defaultInputDeviceUID() -> String? {
        guard let id = defaultInputDeviceID() else { return nil }
        return deviceUID(id)
    }

    /// 当前系统默认输入设备的显示名。
    static func defaultInputDeviceName() -> String? {
        guard let id = defaultInputDeviceID() else { return nil }
        return deviceName(id)
    }

    /// 按 uid 查设备显示名（仅查当前在线的输入设备）。
    static func name(forUID uid: String) -> String? {
        availableInputDevices().first { $0.uid == uid }?.name
    }

    /// 选一支用于「过渡切换」的输入设备 uid：优先用 preferred（若它可用且不等于
    /// excluding），否则任取一支其它在线输入。用于把系统默认输入临时切走再切回，
    /// 以触发互联设备重新握手。找不到可用的过渡设备时返回 nil。
    static func inputUIDPreferring(_ preferred: String?, excluding uid: String) -> String? {
        let devices = availableInputDevices()
        if let preferred, preferred != uid, devices.contains(where: { $0.uid == preferred }) {
            return preferred
        }
        return devices.first { $0.uid != uid }?.uid
    }

    /// 把系统默认输入设备切到指定 uid 的设备。失败（设备不在线等）返回 false。
    static func setDefaultInputDevice(uid: String) -> Bool {
        guard let target = deviceIDs()?.first(where: { deviceUID($0) == uid }) else { return false }
        var deviceID = target
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID
        )
        return status == noErr
    }

    // MARK: - CoreAudio 底层读取

    private static func deviceIDs() -> [AudioDeviceID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var out = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &out) == noErr else {
            return nil
        }
        return out
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    /// 是否拥有输入流（能作为麦克风使用）。
    private static func isInputDevice(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(object, &address) else { return false }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func isAlive(_ object: AudioObjectID) -> Bool {
        uint32Property(of: object, selector: kAudioDevicePropertyDeviceIsAlive) == 1
    }

    /// 系统是否在正常设备列表里隐藏该设备（如部分聚合/系统设备）。
    private static func isHidden(_ object: AudioObjectID) -> Bool {
        uint32Property(of: object, selector: kAudioDevicePropertyIsHidden) == 1
    }

    private static func uint32Property(of object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func deviceUID(_ object: AudioObjectID) -> String? {
        stringProperty(of: object, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func deviceName(_ object: AudioObjectID) -> String? {
        stringProperty(of: object, selector: kAudioObjectPropertyName)
    }

    /// 读一个返回 CFString 的对象属性。CoreAudio 的该属性返回 +1 的 CFString，
    /// 用 Unmanaged.takeRetainedValue() 接管释放，避免每查一次泄漏一个 CFString。
    private static func stringProperty(of object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let retained = value else { return nil }
        return retained.takeRetainedValue() as String
    }
}
