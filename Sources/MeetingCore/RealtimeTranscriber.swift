import Foundation

public actor RealtimeTranscriber {
    private let source: AudioSource
    private let key: String
    private let vocabulary: String
    private let onSegment: @Sendable (TranscriptSegment) -> Void
    private let onState: @Sendable (String) -> Void
    private let onEventType: @Sendable (String) -> Void
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    private var connectionID = UUID()
    private var reducer: TranscriptReducer
    private var ready = false
    private var ended = false
    private var finishing = false
    private var tailBytes = 0
    private var pending: [AudioPacket] = []
    private var pendingBytes = 0
    private var sending = false
    private var reconnecting = false
    private var failureCount = 0
    private var detector = LocalTurnDetector()
    private var committedRanges: [(start: Double, end: Double)] = []
    private var outstandingCommits = 0
    public init(source: AudioSource, key: String, vocabulary: String,
        onSegment: @escaping @Sendable (TranscriptSegment) -> Void, onState: @escaping @Sendable (String) -> Void,
        onEventType: @escaping @Sendable (String) -> Void = { _ in }) {
        self.source = source; self.key = key; self.vocabulary = vocabulary
        self.onSegment = onSegment; self.onState = onState; self.onEventType = onEventType
        reducer = TranscriptReducer(source: source)
    }
    public func start() async { await connect() }
    private func connect() async {
        guard !ended else { return }
        ready = false; reducer = TranscriptReducer(source: source); tailBytes = 0
        detector = LocalTurnDetector(); committedRanges = []; outstandingCommits = 0
        let generation = UUID(); connectionID = generation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request); self.socket = socket; socket.resume()
        onState("连接中")
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                    guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    await self?.receive(event, generation: generation)
                }
            } catch { await self?.failed(error, generation: generation) }
        }
        handshakeTask?.cancel()
        handshakeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            await self?.handshakeExpired(generation)
        }
        do {
            var transcription: [String: Any] = ["model": "gpt-live-transcribe", "delay": "low"]
            let keywords = vocabulary.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == "，" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.contains("<") && !$0.contains(">") }
            if !keywords.isEmpty { transcription["keywords"] = Array(keywords.prefix(100)) }
            try await send(["type": "session.update", "session": ["type": "transcription", "audio": ["input": [
                "format": ["type": "audio/pcm", "rate": 24000], "transcription": transcription,
                "turn_detection": NSNull()
            ]]]])
        } catch { await failed(error, generation: generation) }
    }
    private func send(_ event: [String: Any]) async throws {
        guard let socket else { throw MeetingError.message("连接未建立") }
        let data = try JSONSerialization.data(withJSONObject: event)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    private func receive(_ event: [String: Any], generation: UUID) async {
        guard !ended, generation == connectionID else { return }
        let type = event["type"] as? String ?? ""
        onEventType(type)
        if type == "session.updated" || type == "transcription_session.updated" {
            handshakeTask?.cancel(); handshakeTask = nil
            ready = true; failureCount = 0; onState("实时字幕已连接"); await drain(); return
        }
        if type == "error" || type == "conversation.item.input_audio_transcription.failed" {
            if finishing { return }
            let detail = (event["error"] as? [String: Any])?["message"] as? String ?? "实时转写失败"
            await failed(MeetingError.message(detail.replacingOccurrences(of: key, with: "[redacted]"))); return
        }
        if type == "input_audio_buffer.committed", let item = event["item_id"] as? String, !committedRanges.isEmpty {
            let range = committedRanges.removeFirst()
            if let segment = reducer.setRange(item: item, start: range.start, end: range.end) { onSegment(segment) }
        }
        if type == "conversation.item.input_audio_transcription.completed" { outstandingCommits = max(0, outstandingCommits - 1) }
        if let segment = reducer.receive(event), !segment.text.isEmpty { onSegment(segment) }
    }
    public func append(_ packet: AudioPacket) async {
        guard !ended else { return }
        // Keep at most ten seconds in memory; durable audio is the recovery source.
        guard pendingBytes + packet.pcm.count <= 480_000 else {
            onState("网络积压，字幕稍后从录音补全"); return
        }
        pending.append(packet); pendingBytes += packet.pcm.count
        await drain()
    }
    private func drain() async {
        guard ready, !sending, !ended else { return }
        sending = true
        defer { sending = false }
        do {
            while ready, !pending.isEmpty, !ended {
                let packet = pending.removeFirst(); pendingBytes -= packet.pcm.count
                let actions = detector.receive(packet)
                try await send(actions)
            }
        } catch { await failed(error) }
    }
    private func send(_ actions: [LocalTurnDetector.Action]) async throws {
        for action in actions {
            switch action {
            case .append(let packet):
                reducer.timeline.append(byteCount: packet.pcm.count, at: packet.time)
                let end = packet.time + Double(packet.pcm.count) / 48000
                reducer.currentTurn = (reducer.currentTurn?.start ?? packet.time, end)
                tailBytes += packet.pcm.count
                try await send(["type": "input_audio_buffer.append", "audio": packet.pcm.base64EncodedString()])
            case .commit:
                if tailBytes >= 4800, let range = reducer.currentTurn {
                    committedRanges.append(range); outstandingCommits += 1
                    tailBytes = 0; reducer.currentTurn = nil
                    try await send(["type": "input_audio_buffer.commit"])
                }
            }
        }
    }
    private func handshakeExpired(_ generation: UUID) async {
        guard !ready else { return }
        await failed(MeetingError.message("实时字幕连接超时"), generation: generation)
    }
    private func failed(_ error: Error, generation: UUID? = nil) async {
        guard generation == nil || generation == connectionID else { return }
        guard !ended, !finishing, !reconnecting else { return }
        reconnecting = true; ready = false; failureCount += 1
        handshakeTask?.cancel(); handshakeTask = nil
        receiver?.cancel(); socket?.cancel(with: .goingAway, reason: nil); session?.invalidateAndCancel()
        pending.removeAll(); pendingBytes = 0
        onState("\(error.localizedDescription.prefix(180)) · 本地录音继续，将重连")
        let delay = UInt64(min(20, failureCount * 2)) * 1_000_000_000
        // Separate task: cancelling the receiver must not cancel the retry delay.
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            await self?.reconnect()
        }
    }
    private func reconnect() async {
        reconnecting = false
        if !ended, !finishing { await connect() }
    }
    public func finish() async {
        finishing = true
        if ready {
            for _ in 0..<20 where sending || !pending.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
            let finalActions = detector.finish()
            try? await send(finalActions)
            for _ in 0..<40 {
                if outstandingCommits == 0 { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        await stop()
    }
    public func stop() async {
        ended = true; ready = false; receiver?.cancel(); receiver = nil
        reconnectTask?.cancel(); reconnectTask = nil; handshakeTask?.cancel(); handshakeTask = nil
        socket?.cancel(with: .normalClosure, reason: nil); session?.invalidateAndCancel()
        socket = nil; session = nil; pending.removeAll(); pendingBytes = 0
    }
}

public struct AudioPacket: Sendable {
    public let source: AudioSource
    public let pcm: Data
    public let time: Double
    public init(source: AudioSource, pcm: Data, time: Double) { self.source = source; self.pcm = pcm; self.time = time }
}
