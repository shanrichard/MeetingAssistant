import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import MeetingCore

final class AudioCapture {
    private let queue = DispatchQueue(label: "com.meetingassistant.capture", qos: .userInitiated)
    private var microphoneCapture: MicrophoneCapture?
    private var tapID = AudioObjectID(0), aggregateID = AudioObjectID(0)
    private var ioProc: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var converters: [AudioSource: PCMConverter] = [:]
    private var recorders: [AudioSource: ChunkRecorder] = [:]
    private var chunks: [AudioChunk] = []
    private var capturedBytes: [AudioSource: Int] = [:]
    private var levelThrottles: [AudioSource: AudioLevelThrottle] = [:]
    private var paused = false, active = false, failed = false
    private var receivedMicrophoneFrames = false
    private var microphoneGeneration: UUID?
    private var failureMessage: String?
    private var epoch = 0.0
    var onPacket: ((AudioPacket) -> Void)?
    var onLevel: ((AudioSource, Double) -> Void)?
    var onFailure: ((String) -> Void)?

    // The owner awaits startup before stopping. Hardware setup runs outside the
    // main actor; render callbacks are confined to the capture queue.
    func start(folder: URL, microphone: AudioDevice) async throws {
        epoch = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        chunks = []; capturedBytes = [:]; failed = false; paused = false; receivedMicrophoneFrames = false; failureMessage = nil
        for source in AudioSource.allCases {
            levelThrottles[source] = AudioLevelThrottle()
            recorders[source] = ChunkRecorder(folder: folder, source: source) { [weak self] chunk in self?.chunks.append(chunk) }
        }
        do {
            converters[.microphone] = PCMConverter()
            // Start microphone capture before system-capture permission/setup
            // can delay startup. This also registers our Core Audio process.
            try await startMicrophone(microphone)
            let own = try AudioDevices.ownProcess()
            let description = CATapDescription(monoGlobalTapButExcludeProcesses: [own])
            description.name = "MeetingAssistant System Audio"; description.isPrivate = true; description.muteBehavior = .unmuted
            try AudioDevices.check(AudioHardwareCreateProcessTap(description, &tapID), "请在系统设置中允许录制系统音频")
            var asbd = try AudioDevices.value(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            guard let tapFormat = AVAudioFormat(streamDescription: &asbd) else { throw MeetingError.message("系统音频格式不可用。") }
            self.tapFormat = tapFormat; converters[.system] = PCMConverter()
            let configuration: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MeetingAssistant Capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try AudioDevices.check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregateID), "无法建立系统声音采集设备")
            try AudioDevices.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, queue) { [weak self] _, data, time, _, _ in
                guard let self, self.active, !self.paused, let format = self.tapFormat,
                      let buffer = Self.copy(data, format: format) else { return }
                self.consume(buffer, source: .system, hostTime: time.pointee.mHostTime)
            }, "无法连接系统声音采集")
            try queue.sync {
                if let failureMessage { throw MeetingError.message(failureMessage) }
                active = true
            }
            try AudioDevices.check(AudioDeviceStart(aggregateID, ioProc), "系统音频录制启动失败")
            if let message = queue.sync(execute: { failureMessage }) { throw MeetingError.message(message) }
        } catch { _ = stop(); throw error }
    }
    private func startMicrophone(_ microphone: AudioDevice) async throws {
        for attempt in 0..<2 {
            do { try await startMicrophoneAttempt(microphone); return }
            catch MicrophoneStartupError.noFrames where attempt == 0 {
                // A Bluetooth route transition can leave the first capture
                // session silent. Fully release it before creating a new one.
                queue.sync { microphoneGeneration = nil }
                microphoneCapture?.stop(); microphoneCapture = nil
                try await Task.sleep(for: .milliseconds(300))
            }
        }
    }
    private enum MicrophoneStartupError: LocalizedError {
        case noFrames
        var errorDescription: String? { "没有收到麦克风音频。请确认设备连接稳定后重试。" }
    }
    private func startMicrophoneAttempt(_ microphone: AudioDevice) async throws {
        let generation = UUID()
        queue.sync { receivedMicrophoneFrames = false; microphoneGeneration = generation }
        let capture = MicrophoneCapture(queue: queue, onBuffer: { [weak self] buffer, time in
            guard let self, self.microphoneGeneration == generation else { return }
            self.receivedMicrophoneFrames = true
            guard self.active, !self.paused else { return }
            self.consume(buffer, source: .microphone, hostTime: time)
        }, onFailure: { [weak self] message in
            guard let self, self.microphoneGeneration == generation else { return }
            self.reportFailure(message)
        })
        microphoneCapture = capture
        try capture.start(deviceUID: microphone.uid)
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            let state = queue.sync { (receivedMicrophoneFrames, failureMessage) }
            if let message = state.1 { throw MeetingError.message(message) }
            if state.0 { return }
        }
        throw MicrophoneStartupError.noFrames
    }
    private static func copy(_ data: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data))
        guard let first = buffers.first, first.mData != nil else { return nil }
        let stride = max(1, format.streamDescription.pointee.mBytesPerFrame)
        let frames = first.mDataByteSize / stride
        guard frames > 0, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        output.frameLength = frames
        for (from, to) in zip(buffers, UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)) {
            if let source = from.mData, let target = to.mData { memcpy(target, source, Int(min(from.mDataByteSize, to.mDataByteSize))) }
        }
        return output
    }
    private func consume(_ buffer: AVAudioPCMBuffer, source: AudioSource, hostTime: UInt64) {
        guard !failed else { return }
        do {
            guard let pcm = try converters[source]?.convert(buffer), !pcm.isEmpty else { return }
            let time = max(0, AVAudioTime.seconds(forHostTime: hostTime == 0 ? mach_absolute_time() : hostTime) - epoch)
            try recorders[source]?.append(pcm, at: time)
            capturedBytes[source, default: 0] += pcm.count
            let level = pcm.withUnsafeBytes { raw -> Double in
                let samples = raw.bindMemory(to: Int16.self)
                let sum = samples.reduce(0.0) { $0 + pow(Double($1) / 32768, 2) }
                return min(1, sqrt(sum / Double(max(1, samples.count))) * 5)
            }
            onPacket?(AudioPacket(source: source, pcm: pcm, time: time))
            if let displayed = levelThrottles[source]?.receive(level, at: time) { onLevel?(source, displayed) }
        } catch { reportFailure(error.localizedDescription) }
    }
    private func reportFailure(_ message: String) {
        guard !failed else { return }
        failed = true; failureMessage = message; onFailure?(message)
    }
    func setPaused(_ value: Bool) { queue.sync { paused = value } }
    var elapsed: Double { max(0, AVAudioTime.seconds(forHostTime: mach_absolute_time()) - epoch) }
    var byteCounts: [AudioSource: Int] { queue.sync { capturedBytes } }
    @discardableResult func stop() -> [AudioChunk] {
        microphoneCapture?.stop(); microphoneCapture = nil
        if aggregateID != 0, let ioProc { AudioDeviceStop(aggregateID, ioProc); AudioDeviceDestroyIOProcID(aggregateID, ioProc) }
        ioProc = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
        return queue.sync {
            active = false
            microphoneGeneration = nil
            for recorder in recorders.values { do { try recorder.close() } catch { onFailure?(error.localizedDescription) } }
            recorders.removeAll(); converters.removeAll()
            return chunks
        }
    }
}
