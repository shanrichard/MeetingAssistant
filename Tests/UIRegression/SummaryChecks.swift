import Foundation
import MeetingCore

private final class SummaryCredentialStorage: CredentialStorage {
    private var value: String? = "sk-offline-summary-test"
    func read() throws -> String? { value }
    func save(_ key: String) throws { value = key }
    func delete() throws { value = nil }
}

private final class SummaryProtocol: URLProtocol {
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

@MainActor func checkSummaryPreservation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingSummaryChecks-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root); SummaryProtocol.handler = nil }
    let store = try MeetingStore(root: root)
    var meeting = Meeting(title: "Synthetic transcript loss regression")
    meeting.state = "complete"
    meeting.liveSegments = (0..<16).map { .init(id: "live-\($0)", source: .system,
        start: Double($0 * 10), end: Double($0 * 10 + 8), text: "Original statement \($0)", translation: "原译文 \($0)", isFinal: true) }
    meeting.finalSegments = [.init(id: "final-0", source: .system, start: 1, end: 2, text: "Incomplete", translation: "不完整", speakerID: "speaker-0", isFinal: true)]
    meeting.chunks = [.init(filename: "system_0.wav", source: .system, start: 0, duration: 160)]
    meeting.processedChunks = ["system_0.wav"]
    meeting.speakerNames = ["speaker-0": "A"]
    meeting.summary = .init(overview: [.init(text: "Old summary", evidence: ["final-0"])], decisions: [], actions: [], questions: [])
    try store.save(meeting)
    let audio = Data("Synthetic audio sentinel".utf8)
    let audioURL = store.folder(meeting.id).appendingPathComponent("system_0.wav")
    try audio.write(to: audioURL)
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SummaryProtocol.self]
    let controller = MeetingController(storageRoot: root, apiSession: URLSession(configuration: config),
                                       credentialStorage: SummaryCredentialStorage())
    controller.error = nil
    var checks = 0, requests = 0
    func check(_ condition: Bool, _ message: String) throws {
        checks += 1
        if !condition { throw MeetingError.message(message) }
    }
    SummaryProtocol.handler = { request in
        requests += 1
        guard request.url?.path == "/v1/responses" else { throw MeetingError.message("Summary attempted audio or translation work") }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        }
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        guard json["model"] as? String == "gpt-5.6-luna",
              let input = json["input"] as? String,
              input.contains("live-0"), input.contains("live-15"), !input.contains("final-0"),
              input.split(separator: "\n").count == 16 else { throw MeetingError.message("Summary dropped or replaced original speech") }
        let summary = "{\"overview\":[{\"text\":\"New summary\",\"evidence\":[\"live-15\"]}],\"decisions\":[],\"actions\":[],\"questions\":[]}"
        return (200, try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["content": [["type": "output_text", "text": summary]]]]]))
    }
    await controller.updateSummary()
    let updated = try store.load(meeting.id)
    try check(controller.error == nil && !controller.processing, "Successful update left an error or busy state")
    try check(requests == 1, "Summary did not send exactly one text request")
    try check(updated.liveSegments == meeting.liveSegments, "Live original or translation changed")
    try check(updated.finalSegments == meeting.finalSegments, "Recording transcript changed")
    try check(updated.chunks == meeting.chunks && updated.processedChunks == meeting.processedChunks, "Audio processing metadata changed")
    try check(updated.speakerNames == meeting.speakerNames && updated.state == meeting.state, "Speaker or completion state changed")
    try check(updated.summary?.overview.first?.evidence == ["live-15"] && !updated.summaryUsesDifferentTranscript, "Summary evidence did not refer to original speech")
    try check(try Data(contentsOf: audioURL) == audio, "Audio file changed")
    let saved = try Data(contentsOf: store.folder(meeting.id).appendingPathComponent("meeting.json"))
    SummaryProtocol.handler = { _ in requests += 1; return (500, Data("{\"error\":{\"message\":\"Synthetic failure\"}}".utf8)) }
    await controller.updateSummary()
    try check(controller.error != nil && !controller.processing, "Failed update did not report the failure")
    try check(try Data(contentsOf: store.folder(meeting.id).appendingPathComponent("meeting.json")) == saved, "Failed update overwrote saved data")
    try check(controller.current?.summary?.overview.first?.text == "New summary", "Failed update removed the existing summary")
    controller.processing = true
    await controller.updateSummary()
    try check(requests == 2, "Busy update started another request")
    controller.processing = false
    // Finalization persists the final realtime segment before starting text summarization.
    let tail = TranscriptSegment(id: "tail", source: .microphone, start: 160, end: 165, text: "Final commitment", isFinal: true)
    controller.meetings[0].liveSegments.append(tail)
    controller.error = nil
    SummaryProtocol.handler = { request in
        requests += 1
        guard request.url?.path == "/v1/responses" else { throw MeetingError.message("Finalization attempted to upload audio") }
        let durable = try store.load(meeting.id)
        guard durable.liveSegments.last == tail, durable.state == "recorded", durable.duration == 165 else {
            throw MeetingError.message("Summary started before the realtime tail was saved")
        }
        let summary = "{\"overview\":[{\"text\":\"Tail summary\",\"evidence\":[\"tail\"]}],\"decisions\":[],\"actions\":[],\"questions\":[]}"
        return (200, try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["content": [["type": "output_text", "text": summary]]]]]))
    }
    await controller.finalizeRecording(id: meeting.id, chunks: meeting.chunks, duration: 165, generateSummary: true)
    let finished = try store.load(meeting.id)
    try check(requests == 3 && controller.error == nil && !controller.busy, "Finalization did extra work or failed")
    try check(finished.state == "complete" && finished.summary?.overview.first?.evidence == ["tail"], "Finalization did not summarize the realtime tail")
    try check(finished.liveSegments == meeting.liveSegments + [tail] && finished.finalSegments == meeting.finalSegments, "Finalization rewrote transcript content")
    try check(try Data(contentsOf: audioURL) == audio, "Finalization changed stored audio")
    await controller.finalizeRecording(id: meeting.id, chunks: meeting.chunks, duration: 165, generateSummary: false)
    try check(requests == 3 && (try store.load(meeting.id)).state == "recorded", "Save-only finalization started API work")
    SummaryProtocol.handler = { request in
        requests += 1
        guard request.url?.path == "/v1/responses" else { throw MeetingError.message("Failure fallback attempted audio upload") }
        return (500, Data("{}".utf8))
    }
    await controller.finalizeRecording(id: meeting.id, chunks: meeting.chunks, duration: 165, generateSummary: true)
    let failed = try store.load(meeting.id)
    try check(requests == 4 && failed.state == "recorded" && controller.error != nil, "Failed finalization hid its failure or started fallback requests")
    try check(failed.liveSegments == finished.liveSegments && failed.summary?.overview.first?.text == "Tail summary", "Failed finalization lost the original or existing summary")
    // Neither missing nor blank realtime text may fall back to legacy file transcription.
    for originals: [TranscriptSegment] in [[], [.init(id: "blank", source: .system, start: 0, end: 1, text: " \n")]] {
        controller.meetings[0].liveSegments = originals
        try store.save(controller.meetings[0])
        let before = try Data(contentsOf: store.folder(meeting.id).appendingPathComponent("meeting.json"))
        controller.error = nil
        await controller.updateSummary()
        try check(requests == 4, "No realtime text fell back to an API request")
        try check(controller.error?.contains("没有可总结的实时原文") == true, "No-source check attempted credential access")
        try check(try Data(contentsOf: store.folder(meeting.id).appendingPathComponent("meeting.json")) == before, "No-source check changed saved data")
    }
    print("Summary preservation: \(checks) assertions, 0 failures")
}
