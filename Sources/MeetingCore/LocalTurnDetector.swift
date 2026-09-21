import Foundation

/// Lightweight energy-based endpointing. File transcription remains the recovery source for quiet speech.
public struct LocalTurnDetector {
    public enum Action { case append(AudioPacket), commit }
    private var preRoll: [AudioPacket] = []
    private var preRollDuration = 0.0
    private var speaking = false
    private var quietDuration = 0.0
    private var turnDuration = 0.0
    private var previousEnd: Double?
    public init() {}
    public mutating func receive(_ packet: AudioPacket) -> [Action] {
        guard !packet.pcm.isEmpty, packet.pcm.count % 2 == 0 else { return [] }
        let duration = Double(packet.pcm.count) / 48000
        let rms = packet.pcm.withUnsafeBytes { raw -> Double in
            let samples = raw.bindMemory(to: Int16.self)
            return sqrt(samples.reduce(0.0) { $0 + pow(Double($1) / 32768, 2) } / Double(samples.count))
        }
        var actions: [Action] = []
        if let previousEnd, packet.time - previousEnd > 0.25 {
            if speaking { actions.append(.commit) }
            reset()
        }
        previousEnd = packet.time + duration
        let audible = rms >= (speaking ? 0.0035 : 0.006)
        if !speaking {
            preRoll.append(packet); preRollDuration += duration
            while preRoll.count > 1, preRollDuration - Double(preRoll[0].pcm.count) / 48000 >= 0.3 {
                preRollDuration -= Double(preRoll.removeFirst().pcm.count) / 48000
            }
            guard audible else { return actions }
            speaking = true; turnDuration = preRollDuration
            actions += preRoll.map(Action.append); preRoll = []; preRollDuration = 0
        } else {
            actions.append(.append(packet)); turnDuration += duration
        }
        quietDuration = audible ? 0 : quietDuration + duration
        if quietDuration >= 0.65 || turnDuration >= 15 {
            actions.append(.commit); reset()
        }
        return actions
    }
    public mutating func finish() -> [Action] {
        let result: [Action] = speaking ? [.commit] : []
        reset(); return result
    }
    private mutating func reset() {
        speaking = false; quietDuration = 0; turnDuration = 0
        preRoll = []; preRollDuration = 0; previousEnd = nil
    }
}
