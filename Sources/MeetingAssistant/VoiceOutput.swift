import Foundation
import MeetingCore

@MainActor final class VoiceOutput {
    struct Statistics: Encodable {
        var receivedBytes = 0
        var scheduledBytes = 0
        var completedBytes = 0
        var recoveries = 0
    }
    private(set) var statistics = Statistics()
    private let makePlayback: @MainActor () -> VoicePlayback
    private let listDevices: () throws -> [AudioDevice]
    private var playback: VoicePlayback?
    private var deviceUID: String?
    private var generation = UUID()
    private var playbackGeneration = UUID()
    private var recoveryTask: Task<Void, Never>?
    private var pendingPCM: [Data] = []
    private var queuedPCMBytes = 0
    var onState: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private(set) var running = false

    init(makePlayback: @escaping @MainActor () -> VoicePlayback = { EngineVoicePlayback() },
         listDevices: @escaping () throws -> [AudioDevice] = { try AudioDevices.list() }) {
        self.makePlayback = makePlayback; self.listDevices = listDevices
    }

    func start(device: AudioDevice) throws {
        stop()
        statistics = Statistics()
        guard device.virtual, device.output else { throw MeetingError.message("请选择 BlackHole 等虚拟音频输出设备。") }
        deviceUID = device.uid
        let playback = makePlayback(), token = generation
        self.playback = playback
        // Observe before binding the device. Its configuration notification can arrive
        // after start() returns, even though the user has not changed any hardware.
        playback.onConfigurationChange = { [weak self] in
            guard let self, self.running, self.generation == token else { return }
            self.recoverConfiguration()
        }
        do {
            try playback.start(device: selectedDevice())
            running = true
            onState?("等待你的下一句发言")
        } catch { stop(); throw error }
    }

    private func selectedDevice() throws -> AudioDevice {
        guard let device = try listDevices().first(where: { $0.uid == deviceUID && $0.virtual && $0.output }) else {
            throw MeetingError.message("所选虚拟音频设备不可用，已停止发送译音。请连接原设备后重新开始。")
        }
        return device
    }

    private func recoverConfiguration() {
        guard running, let playback else { return }
        // A stopped node's completion callbacks can still arrive. Invalidate them
        // before discarding interrupted audio; never replay an uncertain old tail.
        playbackGeneration = UUID()
        queuedPCMBytes = pendingPCM.reduce(0) { $0 + $1.count }
        playback.stop()
        guard recoveryTask == nil else { return }
        statistics.recoveries += 1
        onState?("正在恢复译音输出")
        let token = generation
        recoveryTask = Task { @MainActor [weak self] in
            for _ in 0..<3 {
                // Coalesce notifications from the same route/format transition.
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.running, self.generation == token else { return }
                let device: AudioDevice
                do { device = try self.selectedDevice() }
                catch { self.fail(error.localizedDescription); return }
                do {
                    // Reuse the engine and bind only the originally selected UID.
                    // Creating another engine would repeat the default-device switch.
                    try playback.start(device: device)
                    try await Task.sleep(for: .milliseconds(200))
                    guard self.running, self.generation == token else { return }
                    try playback.validateRoute(device: self.selectedDevice())
                    guard playback.isRunning else { continue }
                    self.recoveryTask = nil
                    let pending = self.pendingPCM; self.pendingPCM.removeAll()
                    self.onState?("等待你的下一句发言")
                    for pcm in pending {
                        guard self.running, self.generation == token else { break }
                        self.schedule(pcm)
                    }
                    return
                } catch is CancellationError { return }
                catch { playback.stop() }
            }
            guard let self, self.running, self.generation == token else { return }
            self.fail("无法恢复所选虚拟设备的译音输出，已停止发送。请确认设备可用后重新开始。")
        }
    }

    func enqueuePCM(_ pcm: Data) {
        guard running, !pcm.isEmpty, let playback else { return }
        statistics.receivedBytes += pcm.count
        // The engine can stop before its asynchronous notification reaches us.
        if recoveryTask == nil, !playback.isRunning { recoverConfiguration() }
        guard pcm.count % 2 == 0, pcm.count <= 480_000 - queuedPCMBytes else {
            fail("译音播放积压或音频无效，已停止发送。请确认输出设备后重新开始。"); return
        }
        queuedPCMBytes += pcm.count
        if recoveryTask != nil { pendingPCM.append(pcm) }
        else { schedule(pcm) }
    }

    private func schedule(_ pcm: Data) {
        let token = playbackGeneration
        do {
            try playback?.schedule(pcm) { [weak self] in
                guard let self, self.playbackGeneration == token else { return }
                self.queuedPCMBytes = max(0, self.queuedPCMBytes - pcm.count)
                self.statistics.completedBytes += pcm.count
            }
            statistics.scheduledBytes += pcm.count
            onState?("正在向虚拟麦克风发送实时译音")
        } catch { fail(error.localizedDescription) }
    }

    private func fail(_ message: String) { stop(); onError?(message) }

    func stop() {
        generation = UUID(); playbackGeneration = UUID(); running = false
        recoveryTask?.cancel(); recoveryTask = nil
        pendingPCM.removeAll(); queuedPCMBytes = 0; deviceUID = nil
        playback?.onConfigurationChange = nil
        playback?.stop(); playback = nil
        onState?("译音未发送")
    }
}
