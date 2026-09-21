import Foundation
import AVFoundation

/// Confined to the capture queue. The callback buffer, not a cached device
/// format, is authoritative when a Bluetooth microphone changes profile.
public final class PCMConverter {
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?

    public init() {}

    public func convert(_ input: AVAudioPCMBuffer) throws -> Data {
        guard input.frameLength > 0 else { return Data() }
        let source = input.format
        guard source.sampleRate.isFinite, source.sampleRate > 0, source.channelCount > 0 else {
            throw MeetingError.message("麦克风音频格式暂时不可用，请等待设备连接稳定后重试。")
        }
        if converter?.inputFormat != source {
            guard let updated = AVAudioConverter(from: source, to: target) else {
                throw MeetingError.message("无法转换音频格式。")
            }
            converter = updated
        }
        guard let converter else { throw MeetingError.message("音频转换器不可用。") }
        let capacity = ceil(Double(input.frameLength) * target.sampleRate / source.sampleRate) + 32
        guard capacity > 0, capacity < Double(UInt32.max),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(capacity)) else {
            throw MeetingError.message("无法分配音频缓冲区。")
        }
        var error: NSError?, supplied = false
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if let error { throw error }
        guard status != .error else { throw MeetingError.message("音频转换失败。") }
        guard let pointer = output.audioBufferList.pointee.mBuffers.mData else { return Data() }
        return Data(bytes: pointer, count: Int(output.frameLength) * 2)
    }
}
