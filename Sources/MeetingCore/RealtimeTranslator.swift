import Foundation

public struct TranslationStatistics: Codable, Sendable {
    public var receivedBytes = 0
    public var sentBytes = 0
    public var droppedBytes = 0
    public var connected = false
    public var events: [String: Int] = [:]
}

/// A continuous audio translation session. This protocol has no commit/response turns.
public actor RealtimeTranslator {
    public static let model = "gpt-realtime-translate"
    private let key: String
    private let language: String
    private let source: AudioSource
    private let onSegment: @Sendable (TranscriptSegment) async -> Void
    private let onState: @Sendable (String) async -> Void
    private let onAudio: @Sendable (Data) async -> Void
    private let onTranscriptEvent: @Sendable (Bool, String, Double?) async -> Void
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var handshake: Task<Void, Never>?
    private var generation = UUID()
    private var reducer: LiveTranslationReducer
    private var pending: [AudioPacket] = []
    private var pendingBytes = 0
    private var ready = false
    private var ended = false
    private var closing = false
    private var closed = false
    private var failures = 0
    private var backlogReported = false
    public private(set) var statistics = TranslationStatistics()

    public init(source: AudioSource, key: String, language: String,
        onSegment: @escaping @Sendable (TranscriptSegment) async -> Void,
        onState: @escaping @Sendable (String) async -> Void,
        onAudio: @escaping @Sendable (Data) async -> Void = { _ in },
        onTranscriptEvent: @escaping @Sendable (Bool, String, Double?) async -> Void = { _, _, _ in }) {
        self.source = source; self.key = key; self.language = language
        self.onSegment = onSegment; self.onState = onState; self.onAudio = onAudio
        self.onTranscriptEvent = onTranscriptEvent
        reducer = LiveTranslationReducer(source: source)
    }

    public func start() async { await connect() }
    private func connect() async {
        guard !ended, !closing else { return }
        ready = false; closed = false; statistics.connected = false
        generation = UUID(); let token = generation
        reducer = LiveTranslationReducer(source: source)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime/translations?model=\(Self.model)")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request); self.socket = socket; socket.resume()
        await onState("同传连接中")
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                    if let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        await self?.receive(event, generation: token)
                    }
                }
            } catch { await self?.failed(error, generation: token) }
        }
        handshake = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            await self?.failed(MeetingError.message("同传连接超时"), generation: token)
        }
        do {
            try await send(["type": "session.update", "session": ["audio": [
                "input": ["transcription": ["model": "gpt-live-transcribe"]], "output": ["language": language]]]])
        } catch { await failed(error, generation: token) }
    }

    private func send(_ event: [String: Any]) async throws {
        guard let socket else { throw MeetingError.message("同传连接未建立") }
        try await socket.send(.string(String(decoding: JSONSerialization.data(withJSONObject: event), as: UTF8.self)))
    }

    public func append(_ packet: AudioPacket) {
        guard !ended, !closing, packet.source == source else { return }
        statistics.receivedBytes += packet.pcm.count
        // Preserve silence; the translation model uses a continuous audio clock.
        guard pendingBytes + packet.pcm.count <= 480_000 else {
            statistics.droppedBytes += packet.pcm.count
            if !backlogReported {
                backlogReported = true
                Task { await onState("同传网络积压，部分字幕可能不完整；录音保留在本地") }
            }
            return
        }
        pending.append(packet); pendingBytes += packet.pcm.count
        startSender()
    }
    private func startSender() {
        guard ready, sender == nil, !pending.isEmpty else { return }
        let token = generation
        sender = Task { [weak self] in await self?.drain(generation: token) }
    }
    private func drain(generation token: UUID) async {
        defer { if token == generation { sender = nil } }
        do {
            while ready, !pending.isEmpty, !ended, token == generation, !Task.isCancelled {
                let packet = pending.removeFirst(); pendingBytes -= packet.pcm.count
                reducer.timeline.append(byteCount: packet.pcm.count, at: packet.time)
                try await send(["type": "session.input_audio_buffer.append", "audio": packet.pcm.base64EncodedString()])
                statistics.sentBytes += packet.pcm.count
            }
            if backlogReported, pending.isEmpty, token == generation {
                backlogReported = false; await onState("实时同传已连接")
            }
        } catch { await failed(error, generation: token) }
    }
    private func receive(_ event: [String: Any], generation token: UUID) async {
        guard token == generation, !ended, !closed else { return }
        if let type = event["type"] as? String { statistics.events[type, default: 0] += 1 }
        switch event["type"] as? String {
        case "session.updated":
            handshake?.cancel(); handshake = nil; ready = true; failures = 0
            statistics.connected = true
            await onState("实时同传已连接"); startSender()
        case "session.output_transcript.delta":
            await onTranscriptEvent(false, event["delta"] as? String ?? "", event["elapsed_ms"] as? Double)
            for segment in reducer.receive(event) { await onSegment(segment) }
        case "session.input_transcript.delta":
            await onTranscriptEvent(true, event["delta"] as? String ?? "", event["elapsed_ms"] as? Double)
            for segment in reducer.receive(event) { await onSegment(segment) }
        case "session.output_audio.delta":
            guard event["sample_rate"] as? Int ?? 24000 == 24000,
                  event["channels"] as? Int ?? 1 == 1,
                  event["format"] as? String ?? "pcm16" == "pcm16",
                  let delta = event["delta"] as? String, let pcm = Data(base64Encoded: delta), pcm.count % 2 == 0 else {
                await failed(MeetingError.message("同传返回了不支持的音频格式"), generation: token); return
            }
            await onAudio(pcm)
        case "session.closed":
            if let segment = reducer.finish() { await onSegment(segment) }
            closed = true; ready = false; statistics.connected = false
        case "error":
            let error = event["error"] as? [String: Any]
            let detail = error?["message"] as? String ?? "实时翻译失败"
            await failed(MeetingError.message(detail), generation: token)
        default: break
        }
    }

    private func failed(_ error: Error, generation token: UUID) async {
        guard token == generation, !ended, !closed else { return }
        generation = UUID(); ready = false; statistics.connected = false
        receiver?.cancel(); sender?.cancel(); sender = nil; handshake?.cancel(); handshake = nil
        socket?.cancel(with: .goingAway, reason: nil); session?.invalidateAndCancel()
        socket = nil; session = nil; pending = []; pendingBytes = 0
        if let segment = reducer.finish() { await onSegment(segment) }
        let detail = error.localizedDescription.replacingOccurrences(of: key, with: "[redacted]")
        guard !closing else { await onState("同传尾段未完整接收：\(detail.prefix(150))"); return }
        failures += 1
        await onState("同传暂不可用，将重连：\(detail.prefix(150))")
        let delay = UInt64(min(20, failures * 2)) * 1_000_000_000
        reconnect = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            await self?.connect()
        }
    }

    public func finish() async {
        guard !ended else { return }
        closing = true; reconnect?.cancel(); handshake?.cancel()
        // Bound both upload draining and the final flush so ending a meeting cannot hang.
        for _ in 0..<20 where sender != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        if ready, pending.isEmpty, sender == nil {
            do {
                try await send(["type": "session.close"])
                for _ in 0..<60 {
                    if closed || socket == nil { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            } catch { await onState("同传尾段未完整接收") }
        }
        if !closed { await onState("同传尾段未确认，已保留收到的原文和本地录音") }
        await stop()
    }
    public func stop() async {
        ended = true; ready = false; statistics.connected = false; generation = UUID()
        receiver?.cancel(); sender?.cancel(); reconnect?.cancel(); handshake?.cancel()
        receiver = nil; sender = nil; reconnect = nil; handshake = nil
        socket?.cancel(with: .normalClosure, reason: nil); session?.invalidateAndCancel()
        socket = nil; session = nil; pending = []; pendingBytes = 0
        if let segment = reducer.finish() { await onSegment(segment) }
    }
}

/// Source and target deltas share the translation session's frame clock. Keep them
/// together in speech passages; do not guess sentence correspondence across sockets.
/// A quiet gap starts a new passage. Late deltas still update their original passage.
public struct LiveTranslationReducer {
    public var timeline = AudioTimeline()
    private struct Passage {
        var startMS: Double
        var endMS: Double
        var segment: TranscriptSegment
    }
    private let source: AudioSource
    private let connectionID: String
    private var passages: [Passage] = []
    private var events: Set<String> = []
    public init(source: AudioSource, connectionID: String = UUID().uuidString) {
        self.source = source; self.connectionID = connectionID
    }
    public mutating func receive(_ event: [String: Any]) -> [TranscriptSegment] {
        let type = event["type"] as? String
        let input = type == "session.input_transcript.delta"
        guard input || type == "session.output_transcript.delta",
              let delta = event["delta"] as? String, !delta.isEmpty else { return [] }
        if let id = event["event_id"] as? String, !events.insert(id).inserted { return [] }
        let frame = event["elapsed_ms"] as? Double
        let milliseconds = frame ?? passages.last?.endMS ?? timeline.duration * 1000
        let time = timeline.meetingTime(milliseconds: milliseconds)
        var updates: [TranscriptSegment] = []
        // Break only on a source-side quiet gap after both streams have caught up.
        // Arbitrary fixed windows can attach the last words of a translation to the next sentence.
        let newPassage = passages.isEmpty || (input && frame != nil && milliseconds - passages.last!.endMS >= 2000)
        if newPassage {
            if !passages.isEmpty {
                passages[passages.count - 1].segment.isFinal = true
                updates.append(passages[passages.count - 1].segment)
            }
            let segment = TranscriptSegment(id: "caption-\(source.rawValue)-\(connectionID)-\(passages.count)",
                source: source, start: time, end: time, text: "")
            passages.append(Passage(startMS: milliseconds, endMS: milliseconds, segment: segment))
        }
        let index = passages.lastIndex(where: { $0.startMS <= milliseconds }) ?? 0
        if input { passages[index].segment.text += delta }
        else { passages[index].segment.translation = (passages[index].segment.translation ?? "") + delta }
        passages[index].endMS = max(passages[index].endMS, milliseconds)
        passages[index].segment.start = min(passages[index].segment.start, time)
        passages[index].segment.end = max(passages[index].segment.end, time)
        updates.append(passages[index].segment)
        return updates
    }
    public mutating func finish() -> TranscriptSegment? {
        guard !passages.isEmpty else { return nil }
        passages[passages.count - 1].segment.isFinal = true
        return passages.last?.segment
    }
}
