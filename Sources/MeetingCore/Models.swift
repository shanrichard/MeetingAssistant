import Foundation

public enum AudioSource: String, Codable, CaseIterable, Sendable {
    case microphone, system
    public var title: String { self == .microphone ? "我" : "系统声音" }
}

public enum TranscriptSource: String, CaseIterable, Sendable {
    case live, recording
    public var title: String { self == .live ? "实时原文" : "历史转写" }
}

public struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var source: AudioSource
    public var start: Double
    public var end: Double
    public var text: String
    public var translation: String?
    public var speakerID: String?
    public var isFinal: Bool
    public var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public init(id: String, source: AudioSource, start: Double, end: Double, text: String,
                translation: String? = nil, speakerID: String? = nil, isFinal: Bool = false) {
        self.id = id; self.source = source; self.start = start; self.end = end
        self.text = text; self.translation = translation; self.speakerID = speakerID; self.isFinal = isFinal
    }
}

public struct AudioChunk: Codable, Identifiable, Equatable, Sendable {
    public var id: String { filename }
    public var filename: String
    public var source: AudioSource
    public var start: Double
    public var duration: Double
    public init(filename: String, source: AudioSource, start: Double, duration: Double) {
        self.filename = filename; self.source = source; self.start = start; self.duration = duration
    }
}

public struct SummaryPoint: Codable, Identifiable, Sendable {
    public var id: String { text + evidence.joined() }
    public var text: String
    public var evidence: [String]
    public init(text: String, evidence: [String]) { self.text = text; self.evidence = evidence }
}

public struct MeetingSummary: Codable, Sendable {
    public var overview: [SummaryPoint]
    public var decisions: [SummaryPoint]
    public var actions: [SummaryPoint]
    public var questions: [SummaryPoint]
    public init(overview: [SummaryPoint], decisions: [SummaryPoint], actions: [SummaryPoint], questions: [SummaryPoint]) {
        self.overview = overview; self.decisions = decisions; self.actions = actions; self.questions = questions
    }
    public func validated(against ids: Set<String>) throws -> MeetingSummary {
        for point in overview + decisions + actions + questions {
            guard !point.text.isEmpty, !point.evidence.isEmpty, point.evidence.allSatisfy(ids.contains) else {
                throw MeetingError.message("总结包含无效的原文引用，请重新生成。")
            }
        }
        return self
    }
}

public struct Meeting: Codable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var duration: Double = 0
    public var state: String = "recording"
    public var subtitleLanguage: String
    public var outgoingLanguage: String
    public var chunks: [AudioChunk] = []
    public var liveSegments: [TranscriptSegment] = []
    public var finalSegments: [TranscriptSegment] = []
    public var speakerNames: [String: String] = [:]
    public var processedChunks: [String] = []
    public var summary: MeetingSummary?
    public var notices: [String] = []
    public init(id: UUID = UUID(), title: String, subtitleLanguage: String = "zh", outgoingLanguage: String = "en") {
        self.id = id; self.title = title; self.createdAt = Date()
        self.subtitleLanguage = subtitleLanguage; self.outgoingLanguage = outgoingLanguage
    }
    public var defaultTranscriptSource: TranscriptSource {
        .live
    }
    public func segments(from source: TranscriptSource) -> [TranscriptSegment] {
        let segments = source == .live ? liveSegments : finalSegments
        return segments.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
    public var displayedSegments: [TranscriptSegment] { segments(from: defaultTranscriptSource) }
    public func transcriptSource(forEvidence id: String) -> TranscriptSource? {
        if liveSegments.contains(where: { $0.id == id }) { return .live }
        if finalSegments.contains(where: { $0.id == id }) { return .recording }
        return nil
    }
    public var summaryUsesDifferentTranscript: Bool {
        guard let summary else { return false }
        let ids = Set(displayedSegments.filter(\.hasText).map(\.id))
        return (summary.overview + summary.decisions + summary.actions + summary.questions)
            .flatMap(\.evidence).contains { !ids.contains($0) }
    }
    public func speaker(for segment: TranscriptSegment) -> String {
        segment.source.title
    }
    public mutating func addNotice(_ text: String) {
        if notices.last != text { notices.append(text) }
    }
    public mutating func upsert(_ segment: TranscriptSegment) {
        if let index = liveSegments.firstIndex(where: { $0.id == segment.id }) {
            var updated = segment
            if updated.translation == nil, liveSegments[index].text == segment.text { updated.translation = liveSegments[index].translation }
            liveSegments[index] = updated
        } else { liveSegments.append(segment) }
    }
    public func markdown() -> String {
        var lines = ["# \(title)", "", "\(createdAt.formatted()) · \(timestamp(duration))", ""]
        if let summary {
            for (title, points) in [("会议概要", summary.overview), ("决策", summary.decisions), ("待办", summary.actions), ("待确认", summary.questions)] {
                lines += ["## \(title)", ""]
                lines += points.map { point in
                    "- \(point.text) " + point.evidence.map { "[原文](#\($0))" }.joined(separator: " ")
                }
                lines.append("")
            }
        }
        if summaryUsesDifferentTranscript {
            lines += ["这份历史总结引用了旧版转写。新的总结仅使用实时原文。", ""]
        }
        func appendTranscript(_ title: String, _ segments: [TranscriptSegment]) {
            lines += ["## \(title)", ""]
            for segment in segments {
                lines += ["<a id=\"\(segment.id)\"></a>", "", "**\(timestamp(segment.start)) · \(speaker(for: segment))**", "", segment.text, ""]
                if let translation = segment.translation { lines += ["> \(translation.replacingOccurrences(of: "\n", with: "\n> "))", ""] }
            }
        }
        appendTranscript("对话全文 · \(defaultTranscriptSource.title)", displayedSegments)
        let primaryIDs = Set(displayedSegments.map(\.id))
        let alternateSource: TranscriptSource = defaultTranscriptSource == .live ? .recording : .live
        let alternate = segments(from: alternateSource).filter { !primaryIDs.contains($0.id) }
        if !alternate.isEmpty {
            appendTranscript(alternateSource.title + "（独立记录）", alternate)
        }
        if !notices.isEmpty { lines += ["## 记录说明", ""] + notices.map { "- \($0)" } }
        return lines.joined(separator: "\n")
    }
}

public enum MeetingError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

public func timestamp(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
}

public struct AppPreferences: Codable, Sendable {
    public var subtitleLanguage = "zh"
    public var outgoingLanguage = "en"
    public var microphoneUID = ""
    public var outputUID = ""
    public var vocabulary = ""
    public init() {}
    public static let languages = [("zh", "简体中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어"), ("fr", "Français"), ("de", "Deutsch"), ("es", "Español")]
    public static func languageName(_ code: String) -> String { languages.first { $0.0 == code }?.1 ?? code }
}
