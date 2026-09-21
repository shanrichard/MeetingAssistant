import Foundation
import AVFoundation
import MeetingCore

func checkChangingAudioFormats() throws {
    let converter = PCMConverter()
    // AirPods startup transition plus stereo/interleaving changes. A stale
    // AVAudioConverter would reject the second buffer or resample it incorrectly.
    let formats: [(Double, AVAudioChannelCount, Bool)] = [
        (48000, 1, false), (24000, 1, false), (44100, 2, false),
        (48000, 2, true), (24000, 1, false)
    ]
    for (rate, channels, interleaved) in formats {
        let format = try require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved))
        let buffer = try require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)))
        buffer.frameLength = buffer.frameCapacity
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in buffers {
            let values = try require(audioBuffer.mData?.assumingMemoryBound(to: Float.self))
            let channelStride = Int(audioBuffer.mNumberChannels)
            for frame in 0..<Int(buffer.frameLength) {
                for channel in 0..<channelStride {
                    values[frame * channelStride + channel] = Float(0.25 * sin(2 * .pi * 1000 * Double(frame) / rate))
                }
            }
        }
        let pcm = try converter.convert(buffer)
        print("Audio conversion: \(Int(rate)) Hz, \(channels) ch, interleaved=\(interleaved): \(pcm.count / 2) output frames")
        expect(pcm.count.isMultiple(of: 2))
        // Stereo conversion retains part of the first packet while priming.
        expect((44000...48128).contains(pcm.count))
        let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let settled = Array(samples.dropFirst(100))
        let rms = sqrt(settled.reduce(0.0) { $0 + pow(Double($1) / 32768, 2) } / Double(settled.count))
        expect((0.14...0.20).contains(rms))
        let crossings = zip(settled, settled.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        expect((1850...2050).contains(crossings)) // Pitch stays 1 kHz after every transition.
        var totalFrames = samples.count
        for _ in 0..<9 { totalFrames += try converter.convert(buffer).count / 2 }
        // Ten seconds must remain ten seconds, allowing < 100 ms initial
        // converter latency; a cached or constantly rebuilt converter fails this.
        expect((237600...240032).contains(totalFrames))
        buffer.frameLength = 0
        expect(try converter.convert(buffer).isEmpty)
    }
}
