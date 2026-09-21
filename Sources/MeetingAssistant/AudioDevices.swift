import Foundation
import CoreAudio
import AudioToolbox
import MeetingCore

struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let input: Bool
    let output: Bool
    let virtual: Bool
}

enum AudioDevices {
    static func preferredTranslationOutput(in devices: [AudioDevice], currentUID: String) -> AudioDevice? {
        let usable = devices.filter { $0.input && $0.output && $0.virtual }
        if let current = usable.first(where: { $0.uid == currentUID }) { return current }
        // Do not auto-select private meeting-app devices just because they are virtual.
        return usable.first { $0.uid == "BlackHole2ch_UID" }
    }
    static func check(_ status: OSStatus, _ context: String) throws {
        guard status == noErr else { throw MeetingError.message("\(context)（Core Audio \(status)）") }
    }
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var result = initial, size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutablePointer(to: &result) { pointer in
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer), "读取音频属性失败")
        }
        return result
    }
    static func hasChannels(_ object: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: 0)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(pointer.assumingMemoryBound(to: AudioBufferList.self)).contains { $0.mNumberChannels > 0 }
    }
    static func list() throws -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size), "无法枚举音频设备")
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids), "无法读取音频设备")
        return ids.compactMap { id in
            guard let name = try? value(id, kAudioObjectPropertyName, initial: "" as CFString) as String,
                  let uid = try? value(id, kAudioDevicePropertyDeviceUID, initial: "" as CFString) as String else { return nil }
            let transport = try? value(id, kAudioDevicePropertyTransportType, initial: UInt32(0))
            return AudioDevice(id: id, uid: uid, name: name, input: hasChannels(id, scope: kAudioDevicePropertyScopeInput),
                output: hasChannels(id, scope: kAudioDevicePropertyScopeOutput),
                virtual: transport == kAudioDeviceTransportTypeVirtual || name.localizedCaseInsensitiveContains("BlackHole") || name.localizedCaseInsensitiveContains("Loopback"))
        }
    }
    static func defaultInput() throws -> AudioObjectID {
        try value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID(0))
    }
    static func setDefaultInput(_ device: AudioDevice) throws {
        guard device.input else { throw MeetingError.message("所选设备不能作为麦克风。") }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = device.id
        try check(AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &id), "无法自动切换会议麦克风")
        guard try defaultInput() == device.id else {
            throw MeetingError.message("系统未确认麦克风切换，译音发送未开启。")
        }
    }
    static func ownProcess() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var pid = getpid(), object = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object), "无法排除助手自己的声音")
        guard object != 0 else { throw MeetingError.message("无法定位助手音频进程，已停止以避免音频循环。") }
        return object
    }
}
