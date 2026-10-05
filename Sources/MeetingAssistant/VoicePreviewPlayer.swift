import AVFoundation
import CoreAudio
import MeetingCore
import SwiftUI

/// Local, bundled samples only. Never uses the interpreter's virtual output or API credentials.
@MainActor final class VoicePreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingVoice: InterpreterVoice?
    @Published private(set) var error = ""
    @Published private(set) var outputName = ""
    private var player: AVAudioPlayer?
    private var routeMonitor: Timer?
    private var generation = UUID()

    deinit { routeMonitor?.invalidate(); player?.stop() }

    static func sampleURL(for voice: InterpreterVoice, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: voice.rawValue, withExtension: "wav", subdirectory: "VoicePreviews")
    }

    func toggle(_ voice: InterpreterVoice) {
        let stopping = playingVoice == voice
        stop()
        error = ""
        guard !stopping else { return }
        do {
            let outputID = try AudioDevices.value(AudioObjectID(kAudioObjectSystemObject),
                kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
            guard let output = try AudioDevices.list().first(where: { $0.id == outputID && $0.output && !$0.virtual }) else {
                throw MeetingError.message("请先在 macOS 中把声音输出设为耳机或扬声器，再试听。")
            }
            // Aggregate and multi-output devices may include a virtual meeting input.
            let transport = try AudioDevices.value(output.id, kAudioDevicePropertyTransportType, initial: UInt32(0))
            guard transport != kAudioDeviceTransportTypeAggregate else {
                throw MeetingError.message("请在 macOS 中直接选择耳机或扬声器试听，不要选择聚合或多输出设备。")
            }
            guard let url = Self.sampleURL(for: voice) else {
                throw MeetingError.message("找不到 \(voice.name) 的试听片段，请重新安装完整应用。")
            }
            let audio = try AVAudioPlayer(contentsOf: url)
            audio.currentDevice = output.uid
            audio.delegate = self
            guard audio.prepareToPlay(), audio.currentDevice == output.uid, audio.play() else {
                throw MeetingError.message("无法在 \(output.name) 播放试听，请检查声音输出。")
            }
            player = audio; playingVoice = voice; outputName = output.name
            let token = generation
            routeMonitor = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, let audio = self.player else { return }
                    let current = try? AudioDevices.value(AudioObjectID(kAudioObjectSystemObject),
                        kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
                    let alive = try? AudioDevices.value(output.id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))
                    if current != output.id || alive != 1 || audio.currentDevice != output.uid {
                        self.stop(); self.error = "声音输出设备已变化，试听已停止。请重新点击试听。"
                    }
                }
            }
        } catch {
            stop(); self.error = error.localizedDescription
        }
    }

    func stop() {
        generation = UUID()
        routeMonitor?.invalidate(); routeMonitor = nil
        player?.stop(); player = nil
        playingVoice = nil; outputName = ""
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.stop()
            if !flag { self.error = "试听播放未完成，请重试。" }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.stop(); self.error = "试听片段无法播放，请重新安装完整应用。"
        }
    }
}
