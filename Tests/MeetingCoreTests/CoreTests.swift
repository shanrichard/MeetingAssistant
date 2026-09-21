import Foundation
import MeetingCore

struct CoreTests {
    func testLiveTranslationPairsSourceAndTargetAcrossLateDeltas() throws {
        var reducer = LiveTranslationReducer(source: .system, connectionID: "test")
        reducer.timeline.append(byteCount: 96000, at: 10)
        let first = reducer.receive(["type": "session.input_transcript.delta", "event_id": "1", "elapsed_ms": 1200.0, "delta": "See you"]).last!
        expect(first.text == "See you"); expect(first.start == 11.2)
        let second = reducer.receive(["type": "session.output_transcript.delta", "event_id": "2", "elapsed_ms": 1200.0, "delta": "下周"]).last!
        expect(second.text == "See you"); expect(second.translation == "下周"); expect(second.id == first.id)
        expect(reducer.receive(["type": "session.output_transcript.delta", "event_id": "2", "delta": "重复"]).isEmpty)
        let third = reducer.receive(["type": "session.input_transcript.delta", "event_id": "3", "elapsed_ms": 1800.0, "delta": " Tuesday."]).last!
        expect(third.id == first.id); expect(third.text == "See you Tuesday."); expect(third.translation == "下周")
        let afterPause = reducer.receive(["type": "session.input_transcript.delta", "event_id": "4", "elapsed_ms": 5000.0, "delta": "Next topic"])
        expect(afterPause.count == 2); expect(afterPause.first?.isFinal == true)
        expect(afterPause.last?.id != first.id); expect(afterPause.last?.translation == nil)
        let late = reducer.receive(["type": "session.output_transcript.delta", "event_id": "5", "elapsed_ms": 1800.0, "delta": "二见。"]).last!
        expect(late.id == first.id); expect(late.translation == "下周二见。"); expect(late.isFinal)
        var meeting = Meeting(title: "Streaming")
        meeting.upsert(first); meeting.upsert(second); meeting.upsert(third)
        expect(meeting.liveSegments[0].translation == "下周")
        for segment in afterPause { meeting.upsert(segment) }; meeting.upsert(late)
        expect(meeting.liveSegments.count == 2)
        expect(meeting.markdown().contains("下周二见。")); expect(meeting.markdown().contains("See you Tuesday."))
        let encoded = try JSONEncoder().encode(meeting)
        let decoded = try JSONDecoder().decode(Meeting.self, from: encoded)
        expect(decoded.liveSegments[0].translation == "下周二见。")
        expect(reducer.finish()?.isFinal == true)
        let missingTime = reducer.receive(["type": "session.output_transcript.delta", "event_id": "6", "delta": "下个话题"]).last!
        expect(missingTime.id == afterPause.last?.id); expect(missingTime.text == "Next topic")
    }
    func testLocalEndpointingHandlesSilencePauseAndLongSpeech() {
        func packet(_ index: Int, audible: Bool, offset: Double = 0) -> AudioPacket {
            let sample: Int16 = audible ? 1200 : 0
            var samples = [Int16](repeating: sample, count: 2400)
            let data = samples.withUnsafeMutableBytes { Data($0) }
            return .init(source: .microphone, pcm: data, time: Double(index) / 10 + offset)
        }
        func commits(_ actions: [LocalTurnDetector.Action]) -> Int { actions.filter { if case .commit = $0 { return true }; return false }.count }
        var detector = LocalTurnDetector()
        for i in 0..<10 { expect(detector.receive(packet(i, audible: false)).isEmpty) }
        let start = detector.receive(packet(10, audible: true))
        expect(start.count >= 3) // Retain the initial consonant with pre-roll.
        var endings = 0
        for i in 11..<19 { endings += commits(detector.receive(packet(i, audible: false))) }
        expect(endings == 1); expect(detector.finish().isEmpty)
        _ = detector.receive(packet(20, audible: true))
        expect(commits(detector.receive(packet(21, audible: true, offset: 5))) == 1)
        expect(commits(detector.finish()) == 1)
        detector = LocalTurnDetector(); endings = 0
        for i in 0..<160 { endings += commits(detector.receive(packet(i, audible: true))) }
        expect(endings == 1); expect(commits(detector.finish()) == 1)
    }
    func testLocalRangesSurviveDelayedCompletionFromPreviousTurn() {
        var reducer = TranscriptReducer(source: .system, connectionID: "local")
        reducer.currentTurn = (10, 12)
        let partial = reducer.receive(["type": "conversation.item.input_audio_transcription.delta", "item_id": "old", "delta": "hello"])
        expect(partial?.start == 10)
        _ = reducer.setRange(item: "old", start: 10, end: 13)
        reducer.currentTurn = (20, 22)
        let final = reducer.receive(["type": "conversation.item.input_audio_transcription.completed", "item_id": "old", "transcript": "hello there"])
        expect(final?.start == 10); expect(final?.end == 13)
    }
    func testTranscriptCompletionReplacesPartialsAndIgnoresLateDuplicate() {
        var reducer = TranscriptReducer(source: .system, connectionID: "test")
        reducer.timeline.append(byteCount: 480000, at: 20)
        _ = reducer.receive(["type": "input_audio_buffer.speech_started", "item_id": "b", "audio_start_ms": 4000.0])
        _ = reducer.receive(["type": "conversation.item.input_audio_transcription.delta", "item_id": "b", "event_id": "1", "delta": "three"])
        expect(reducer.receive(["type": "conversation.item.input_audio_transcription.delta", "item_id": "b", "event_id": "1", "delta": "three"]) == nil)
        let final = reducer.receive(["type": "conversation.item.input_audio_transcription.completed", "item_id": "b", "transcript": "three thousand dollars"])
        expect(final?.text == "three thousand dollars"); expect(final?.start == 24)
        expect(reducer.receive(["type": "conversation.item.input_audio_transcription.delta", "item_id": "b", "delta": "bad late delta"]) == nil)
        let earlier = reducer.receive(["type": "input_audio_buffer.speech_started", "item_id": "a", "audio_start_ms": 1000.0])!
        var meeting = Meeting(title: "test"); meeting.upsert(final!); meeting.upsert(earlier)
        expect(meeting.displayedSegments.first?.id == earlier.id)
    }
    func testTimelinePreservesPauseAndReconnectOffsets() {
        var timeline = AudioTimeline()
        timeline.append(byteCount: 48000, at: 0)
        timeline.append(byteCount: 48000, at: 10)
        expect(timeline.meetingTime(milliseconds: 500) == 0.5)
        expect(timeline.meetingTime(milliseconds: 1500) == 10.5)
    }
    func testChunkRecorderRolloverHeadersAndPauseGap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var chunks: [AudioChunk] = []
        let recorder = ChunkRecorder(folder: root, source: .system, chunkSeconds: 1) { chunks.append($0) }
        try recorder.append(Data(repeating: 1, count: 72000), at: 0)
        try recorder.append(Data(repeating: 2, count: 24000), at: 10)
        try recorder.close()
        expect(chunks.count == 3)
        expect(chunks.map(\.start) == [0, 1, 10])
        expect(chunks.map(\.duration) == [1, 0.5, 0.5])
        let data = try Data(contentsOf: root.appendingPathComponent(chunks[0].filename))
        expect(data.count == 48044); expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        let count = data[40..<44].enumerated().reduce(0) { $0 + (Int($1.element) << ($1.offset * 8)) }
        expect(count == 48000)
    }
    func testCrashRecoveryRepairsWAVAndPreservesMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Recovered")
        try store.save(meeting)
        try (WAV.header(byteCount: 0) + Data(repeating: 0, count: 48000))
            .write(to: store.folder(meeting.id).appendingPathComponent("microphone_2000.wav"))
        try store.recover(&meeting)
        expect(meeting.state == "interrupted"); expect(meeting.chunks.count == 1)
        expect(meeting.duration == 3)
        expect(try store.load(meeting.id).chunks[0].duration == 1)
    }
    func testDeleteRemovesOnlyTheChosenMeetingAndAllItsFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let removed = Meeting(title: "Delete me"), retained = Meeting(title: "Keep me")
        try store.save(removed); try store.save(retained)
        for filename in ["microphone_0.wav", "system_0.wav", "speakers.json"] {
            try Data("synthetic test data".utf8).write(to: store.folder(removed.id).appendingPathComponent(filename))
        }
        let exported = root.appendingPathComponent("export.md")
        try Data("exported copy".utf8).write(to: exported)
        try store.delete(removed.id)
        expect(!FileManager.default.fileExists(atPath: store.folder(removed.id).path))
        expect(try store.load(retained.id).title == retained.title)
        expect(FileManager.default.fileExists(atPath: exported.path))
        expect(try MeetingStore(root: root).all().map(\.id) == [retained.id])
        try store.delete(removed.id)
        expect(try store.all().count == 1)
    }
    func testSummaryRejectsMissingOrInventedEvidence() throws {
        let summary = MeetingSummary(overview: [.init(text: "test", evidence: ["invented"])], decisions: [], actions: [], questions: [])
        expectThrows { _ = try summary.validated(against: ["real"]) }
        _ = try summary.validated(against: ["invented"])
    }
    func testResponseRejectsTruncatedOutputAndExtractsOnlyText() throws {
        expectThrows { _ = try OpenAIClient.responseText(Data("{\"status\":\"incomplete\",\"output\":[]}".utf8)) }
        let response = Data("{\"status\":\"completed\",\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}]}".utf8)
        expect(try OpenAIClient.responseText(response) == "ok")
    }
    func testPreferencesNeverSerializeAPIKey() throws {
        let data = try JSONEncoder().encode(AppPreferences())
        let object = try require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        expect(Set(object.keys) == ["subtitleLanguage", "outgoingLanguage", "microphoneUID", "outputUID", "vocabulary"])
    }
    func testExportRetainsTranslationAndEvidence() {
        var meeting = Meeting(title: "demo")
        meeting.liveSegments = [.init(id: "a", source: .microphone, start: 4, end: 5, text: "你好", translation: "Hello", isFinal: true)]
        meeting.summary = .init(overview: [.init(text: "Greeting", evidence: ["a"])], decisions: [], actions: [], questions: [])
        let exported = meeting.markdown()
        expect(exported.contains("[原文](#a)")); expect(exported.contains("> Hello"))
        expect(exported.contains("00:00:04"))
    }
    func testPostProcessingPreservesOriginalTranscriptAndLegacyEvidence() throws {
        var meeting = Meeting(title: "Transcript preservation")
        meeting.liveSegments = (0..<16).map { .init(id: "live-\($0)", source: .system,
            start: Double($0 * 10), end: Double($0 * 10 + 8), text: "Original statement \($0)",
            translation: "原译文 \($0)", isFinal: true) }
        meeting.finalSegments = (0..<5).map { .init(id: "final-\($0)", source: .system,
            start: Double($0 * 20), end: Double($0 * 20 + 1), text: "Incomplete retranscription \($0)", isFinal: true) }
        let originals = meeting.liveSegments
        for state in ["recorded", "processing", "complete", "interrupted"] {
            meeting.state = state
            expect(meeting.displayedSegments == originals)
            expect(meeting.defaultTranscriptSource == .live)
        }
        meeting.summary = .init(overview: [.init(text: "Legacy summary", evidence: ["final-0"])], decisions: [], actions: [], questions: [])
        expect(meeting.summaryUsesDifferentTranscript)
        expect(meeting.transcriptSource(forEvidence: "final-0") == .recording)
        expect(meeting.transcriptSource(forEvidence: "live-15") == .live)
        expect(meeting.transcriptSource(forEvidence: "missing") == nil)
        let reloaded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        expect(reloaded.displayedSegments == originals)
        expect(reloaded.finalSegments == meeting.finalSegments)
        let exported = reloaded.markdown()
        expect(exported.contains("Original statement 15"))
        expect(exported.contains("原译文 15"))
        expect(exported.contains("[原文](#final-0)"))
        expect(exported.contains("<a id=\"final-0\"></a>"))
        expect(exported.contains("历史转写（独立记录）"))
        meeting.summary = .init(overview: [.init(text: "New summary", evidence: ["live-15"])], decisions: [], actions: [], questions: [])
        expect(!meeting.summaryUsesDifferentTranscript)
        meeting.liveSegments = []
        expect(meeting.defaultTranscriptSource == .live)
        expect(meeting.displayedSegments.isEmpty)
        meeting.liveSegments = [.init(id: "blank", source: .system, start: 0, end: 1, text: " \n")]
        expect(meeting.defaultTranscriptSource == .live)
    }
}

final class MockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

struct APIContractTests {
    private func requestJSON(_ request: URLRequest) throws -> [String: Any] {
        let body: Data
        if let data = request.httpBody { body = data }
        else if let input = request.httpBodyStream {
            input.open(); defer { input.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while input.hasBytesAvailable {
                let count = input.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        } else { throw MeetingError.message("Missing request body") }
        return try require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
    func testSummarySkipsBlankSegmentsAndRejectsEmptyMeetingsLocally() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        var requests = 0
        MockProtocol.handler = { request in
            requests += 1
            let json = try requestJSON(request)
            let input = try require(json["input"] as? String)
            let lines = try input.split(separator: "\n").map {
                try require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String])
            }
            expect(lines.count == 1); expect(lines.first?["id"] == "speech")
            expect(lines.first?["text"] == "Hello")
            let summary = "{\"overview\":[{\"text\":\"Greeting\",\"evidence\":[\"speech\"]}],\"decisions\":[],\"actions\":[],\"questions\":[]}"
            return (200, try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["content": [["type": "output_text", "text": summary]]]]]))
        }
        let client = OpenAIClient(key: "test-key", session: URLSession(configuration: config))
        let blank = TranscriptSegment(id: "blank", source: .microphone, start: 0, end: 1, text: " \t\n\u{3000}", isFinal: true)
        for segments: [TranscriptSegment] in [[], [blank]] {
            do { _ = try await client.summarize(segments, language: "zh"); recordFailure("Expected no-speech error") }
            catch { expect(error.localizedDescription == "没有可总结的发言。") }
        }
        expect(requests == 0)
        var legacyOnly = Meeting(title: "Legacy transcript cannot be summarized")
        legacyOnly.finalSegments = [.init(id: "legacy", source: .system, start: 0, end: 2, text: "Old transcription")]
        for originals: [TranscriptSegment] in [[], [blank]] {
            legacyOnly.liveSegments = originals
            do { _ = try await client.summarize(legacyOnly); recordFailure("Legacy transcript used as fallback") }
            catch { expect(error.localizedDescription == "没有可总结的发言。") }
        }
        expect(requests == 0)
        let speech = TranscriptSegment(id: "speech", source: .system, start: 1, end: 2, text: "Hello", isFinal: true)
        let result = try await client.summarize([blank, speech], language: "zh")
        expect(result.overview.first?.evidence == ["speech"]); expect(requests == 1)
    }
    func testOversizedFirstSegmentDoesNotCreateAnEmptySummaryBatch() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let speech = TranscriptSegment(id: "long", source: .system, start: 0, end: 300, text: String(repeating: "a", count: 50001), isFinal: true)
        var requests = 0
        MockProtocol.handler = { request in
            requests += 1
            let json = try requestJSON(request)
            let input = try require(json["input"] as? String)
            expect(!input.isEmpty)
            let summary = "{\"overview\":[],\"decisions\":[],\"actions\":[],\"questions\":[]}"
            return (200, try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["content": [["type": "output_text", "text": summary]]]]]))
        }
        _ = try await OpenAIClient(key: "test-key", session: URLSession(configuration: config)).summarize([speech], language: "zh")
        expect(requests == 1)
    }
    func testRequestUsesUserKeyAndOfficialEndpoint() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        MockProtocol.handler = { request in
            expect(request.url?.host == "api.openai.com")
            expect(request.url?.path == "/v1/models")
            expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            return (200, Data("{\"data\":[{\"id\":\"gpt-live-transcribe\"}]}".utf8))
        }
        let models = try await OpenAIClient(key: "test-key", session: URLSession(configuration: config)).models()
        expect(models.contains("gpt-live-transcribe"))
    }
    func testServerErrorCannotEchoCredential() async {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        MockProtocol.handler = { _ in (401, Data("{\"error\":{\"message\":\"bad test-private-key\"}}".utf8)) }
        do {
            _ = try await OpenAIClient(key: "test-private-key", session: URLSession(configuration: config)).models()
            recordFailure("Expected authentication error")
        } catch { expect(!(error.localizedDescription.contains("test-private-key"))); expect(error.localizedDescription.contains("[redacted]")) }
    }
}

var checkCount = 0
var failures: [String] = []
func expect(_ condition: @autoclosure () throws -> Bool, file: String = #fileID, line: Int = #line) {
    checkCount += 1
    do { if try !condition() { failures.append("\(file):\(line)") } }
    catch { failures.append("\(file):\(line) \(error.localizedDescription)") }
}
func expectThrows(_ operation: () throws -> Void) {
    checkCount += 1
    do { try operation(); failures.append("Expected an error") } catch {}
}
func require<T>(_ value: T?) throws -> T {
    guard let value else { throw MeetingError.message("Expected non-nil result") }; return value
}
func recordFailure(_ message: String) { failures.append(message) }

@main struct CoreCheckRunner {
    static func main() async {
        let core = CoreTests()
        do {
            await checkAudioRouting()
            try checkChangingAudioFormats()
            try checkCredentials()
            try core.testLiveTranslationPairsSourceAndTargetAcrossLateDeltas()
            core.testTranscriptCompletionReplacesPartialsAndIgnoresLateDuplicate()
            core.testLocalEndpointingHandlesSilencePauseAndLongSpeech()
            core.testLocalRangesSurviveDelayedCompletionFromPreviousTurn()
            core.testTimelinePreservesPauseAndReconnectOffsets()
            try core.testChunkRecorderRolloverHeadersAndPauseGap()
            try core.testCrashRecoveryRepairsWAVAndPreservesMetadata()
            try core.testDeleteRemovesOnlyTheChosenMeetingAndAllItsFiles()
            try core.testSummaryRejectsMissingOrInventedEvidence()
            try core.testResponseRejectsTruncatedOutputAndExtractsOnlyText()
            try core.testPreferencesNeverSerializeAPIKey()
            core.testExportRetainsTranslationAndEvidence()
            try core.testPostProcessingPreservesOriginalTranscriptAndLegacyEvidence()
            let api = APIContractTests()
            try await api.testSummarySkipsBlankSegmentsAndRejectsEmptyMeetingsLocally()
            try await api.testOversizedFirstSegmentDoesNotCreateAnEmptySummaryBatch()
            try await api.testRequestUsesUserKeyAndOfficialEndpoint()
            await api.testServerErrorCannotEchoCredential()
        } catch { failures.append(error.localizedDescription) }
        for failure in failures { print("FAIL: " + failure) }
        print("\(checkCount) assertions, \(failures.count) failures")
        if !failures.isEmpty { exit(1) }
    }
}
