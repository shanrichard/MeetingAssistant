import Foundation
import AVFoundation
import AudioToolbox
import AudioSafety
import MeetingCore

@MainActor protocol VoicePlayback: AnyObject {
    var onConfigurationChange: (() -> Void)? { get set }
    var isRunning: Bool { get }
    func start(device: AudioDevice) throws
    func validateRoute(device: AudioDevice) throws
    func schedule(_ pcm: Data, completion: @escaping @MainActor () -> Void) throws
    func stop()
}

@MainActor final class EngineVoicePlayback: VoicePlayback {
    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private var configurationObserver: NSObjectProtocol?
    var onConfigurationChange: (() -> Void)?
    var isRunning: Bool { engine.isRunning && player.isPlaying }

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        engine.attach(player)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // AVAudioEngine posts on an internal queue. Never stop or release it
            // synchronously from its notification callback.
            Task { @MainActor [weak self] in self?.onConfigurationChange?() }
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    private func currentDevice() throws -> AudioObjectID {
        guard let unit = engine.outputNode.audioUnit else { throw MeetingError.message("译音输出设备不可用。") }
        var id = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        try AudioDevices.check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &id, &size), "无法读取译音输出设备")
        return id
    }

    func validateRoute(device: AudioDevice) throws {
        let actual = try currentDevice()
        let uid = try AudioDevices.value(actual, kAudioDevicePropertyDeviceUID, initial: "" as CFString) as String
        let alive = try AudioDevices.value(actual, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))
        guard device.virtual, device.output, actual == device.id, uid == device.uid, alive != 0 else {
            throw MeetingError.message("译音输出未连接到所选虚拟设备，已停止发送。")
        }
    }

    func start(device: AudioDevice) throws {
        stop()
        guard device.virtual, device.output, let unit = engine.outputNode.audioUnit else {
            throw MeetingError.message("译音输出设备不可用。")
        }
        // Only set CurrentDevice when needed. Reassigning on every recovery can
        // itself produce another delayed configuration-change notification.
        if try currentDevice() != device.id {
            var id = device.id
            try AudioDevices.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioObjectID>.size)), "无法连接虚拟麦克风")
        }
        try validateRoute(device: device)
        let format = engine.outputNode.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            throw MeetingError.message("虚拟音频设备的格式暂时不可用。")
        }
        try AudioSafety.startPlayback(engine, player: player, outputFormat: format)
        do { try validateRoute(device: device) }
        catch { stop(); throw error }
    }

    func schedule(_ pcm: Data, completion: @escaping @MainActor () -> Void) throws {
        let count = pcm.count / 2
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw MeetingError.message("无法准备译音播放缓冲区。")
        }
        buffer.frameLength = AVAudioFrameCount(count)
        pcm.withUnsafeBytes { raw in
            for index in 0..<count {
                let sample = raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
                buffer.floatChannelData![0][index] = Float(Int16(littleEndian: sample)) / 32768
            }
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            Task { @MainActor in completion() }
        }
    }

    func stop() { AudioSafety.stopPlayback(engine, player: player) }
}
