import Foundation

public struct AudioTimeline: Sendable {
    private var anchors: [(stream: Double, meeting: Double)] = []
    public private(set) var duration = 0.0
    public init() {}
    public mutating func append(byteCount: Int, at meetingTime: Double) {
        if let last = anchors.last {
            if abs(last.meeting + duration - last.stream - meetingTime) > 0.15 { anchors.append((duration, meetingTime)) }
        } else { anchors.append((duration, meetingTime)) }
        duration += Double(byteCount) / 48000
    }
    public func meetingTime(milliseconds: Double) -> Double {
        let t = milliseconds / 1000
        guard let anchor = anchors.last(where: { $0.stream <= t }) ?? anchors.first else { return t }
        return max(0, anchor.meeting + t - anchor.stream)
    }
}

public struct TranscriptReducer {
    public let source: AudioSource
    public let connectionID: String
    public var timeline = AudioTimeline()
    public private(set) var items: [String: TranscriptSegment] = [:]
    private var events: Set<String> = []
    public var currentTurn: (start: Double, end: Double)?
    public init(source: AudioSource, connectionID: String = UUID().uuidString) {
        self.source = source; self.connectionID = connectionID
    }
    public mutating func receive(_ event: [String: Any]) -> TranscriptSegment? {
        if let eventID = event["event_id"] as? String, !events.insert(eventID).inserted { return nil }
        guard let item = event["item_id"] as? String, let type = event["type"] as? String else { return nil }
        var segment = items[item] ?? TranscriptSegment(id: "\(source.rawValue)-\(connectionID)-\(item)", source: source,
            start: currentTurn?.start ?? timeline.meetingTime(milliseconds: timeline.duration * 1000),
            end: currentTurn?.end ?? timeline.meetingTime(milliseconds: timeline.duration * 1000), text: "")
        switch type {
        case "input_audio_buffer.speech_started":
            if let ms = event["audio_start_ms"] as? Double { segment.start = timeline.meetingTime(milliseconds: ms) }
        case "input_audio_buffer.speech_stopped":
            if let ms = event["audio_end_ms"] as? Double { segment.end = timeline.meetingTime(milliseconds: ms) }
        case "conversation.item.input_audio_transcription.delta":
            guard !segment.isFinal else { return nil }
            segment.text += event["delta"] as? String ?? ""
        case "conversation.item.input_audio_transcription.completed":
            segment.text = event["transcript"] as? String ?? segment.text; segment.isFinal = true
        default: return nil
        }
        segment.end = max(segment.start, segment.end)
        items[item] = segment
        return segment
    }
    public mutating func setRange(item: String, start: Double, end: Double) -> TranscriptSegment? {
        var segment = items[item] ?? TranscriptSegment(id: "\(source.rawValue)-\(connectionID)-\(item)", source: source,
            start: start, end: end, text: "")
        segment.start = start; segment.end = end; items[item] = segment
        return segment.text.isEmpty ? nil : segment
    }
}
