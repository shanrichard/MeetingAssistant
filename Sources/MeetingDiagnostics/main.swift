import Foundation
import MeetingCore

actor Probe {
    var segments: [TranscriptSegment] = []
    var states: [String] = []
    func segment(_ value: TranscriptSegment) { segments.append(value) }
    func state(_ value: String) { states.append(value) }
    var ready: Bool { states.contains("实时字幕已连接") }
    var finalText: String { segments.filter(\.isFinal).map(\.text).joined(separator: " ") }
}

actor TranslationProbe {
    var ready = false
    var startedAt: Date?
    var firstTextDelay: Double?
    var outputBytes = 0
    var segments: [String: TranscriptSegment] = [:]
    func state(_ value: String) { ready = value == "实时同传已连接" }
    func begin() { startedAt = Date() }
    func segment(_ value: TranscriptSegment) {
        if firstTextDelay == nil, !(value.translation ?? "").isEmpty, let startedAt { firstTextDelay = Date().timeIntervalSince(startedAt) }
        segments[value.id] = value
    }
    func audio(_ data: Data) { outputBytes += data.count }
    var text: String { segments.values.sorted { $0.start < $1.start }.compactMap(\.translation).joined() }
    var sourceText: String { segments.values.sorted { $0.start < $1.start }.map(\.text).joined() }
}

@main struct Diagnostics {
    static func report(_ name: String, _ status: String, _ detail: String = "") {
        let object = ["check": name, "status": status, "detail": detail]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text); fflush(stdout) }
    }
    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else {
            report("credentials", "not_run", "OPENAI_API_KEY is required in the process environment; no key is saved."); return
        }
        let client = OpenAIClient(key: key)
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--replay"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
            await replay(file: ProcessInfo.processInfo.arguments[index + 1], key: key)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--translation-only") {
            await checkLiveTranslation(client: client, key: key); return
        }
        var models: Set<String> = []
        do { models = try await client.models(); report("authentication", "pass", "Required model access is checked separately.") }
        catch { report("authentication", "fail", error.localizedDescription); return }
        for model in ["gpt-live-transcribe", RealtimeTranslator.model, OpenAIClient.textModel, "gpt-4o-mini-tts"] {
            report("model:" + model, models.contains(model) ? "listed" : "not_listed")
        }
        let text = "We will meet next Tuesday at ten in the morning. The budget is three thousand dollars."
        do {
            let pcm = try await client.speech(text)
            report("speech_synthesis", "pass", "\(pcm.count / 48000) seconds of synthetic audio")
            let probe = Probe()
            let transcriber = RealtimeTranscriber(source: .microphone, key: key, vocabulary: "",
                onSegment: { value in Task { await probe.segment(value) } },
                onState: { value in report("realtime_state", "info", value); Task { await probe.state(value) } },
                onEventType: { value in report("realtime_event", "info", value) })
            await transcriber.start()
            for _ in 0..<300 { if await probe.ready { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            if await probe.ready {
                var offset = 0
                while offset < pcm.count {
                    let end = min(pcm.count, offset + 4800)
                    await transcriber.append(.init(source: .microphone, pcm: pcm.subdata(in: offset..<end), time: Double(offset) / 48000))
                    offset = end; try await Task.sleep(nanoseconds: 100_000_000)
                }
                for n in 0..<15 {
                    await transcriber.append(.init(source: .microphone, pcm: Data(repeating: 0, count: 4800), time: Double(pcm.count) / 48000 + Double(n) / 10))
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                await transcriber.finish()
                let result = await probe.finalText
                report("realtime_transcription", result.isEmpty ? "fail" : "pass", result)
            } else { await transcriber.stop(); report("realtime_transcription", "fail", await probe.states.last ?? "No session.updated acknowledgment") }
        } catch { report("audio_pipeline", "fail", error.localizedDescription) }
        do {
            let segments = [TranscriptSegment(id: "test-1", source: .microphone, start: 0, end: 6, text: text, isFinal: true)]
            let summary = try await client.summarize(segments, language: "zh")
            report("summary_evidence", "pass", "\(summary.overview.count) overview points, all references validated")
        } catch { report("summary_evidence", "fail", error.localizedDescription) }
    }
    @MainActor static func replay(file: String, key: String) async {
        let arguments = ProcessInfo.processInfo.arguments
        func number(_ name: String, fallback: Double) -> Double {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return fallback }
            return Double(arguments[index + 1]) ?? fallback
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: file))
            guard data.count >= 44, String(decoding: data.prefix(4), as: UTF8.self) == "RIFF" else {
                throw MeetingError.message("Expected a captured 24 kHz mono PCM16 WAV file")
            }
            let start = max(0, Int(number("--start", fallback: 0) * 24000)) * 2 + 44
            let end = min(data.count, start + Int(number("--duration", fallback: 20) * 24000) * 2)
            guard start < end else { throw MeetingError.message("Replay range is outside the recording") }
            var pcm = data.subdata(in: start..<end)
            let leadingSilence = max(0, number("--leading-silence", fallback: 0))
            if leadingSilence > 0 { pcm = Data(repeating: 0, count: Int(leadingSilence * 24000) * 2) + pcm }
            let gain = number("--gain", fallback: 1)
            if gain != 1 {
                pcm.withUnsafeMutableBytes { raw in
                    let samples = raw.bindMemory(to: Int16.self)
                    for i in samples.indices { samples[i] = Int16(max(-32768, min(32767, Double(samples[i]) * gain))) }
                }
            }
            let frames = max(1, Int(number("--packet-frames", fallback: 256)))
            let probe = TranslationProbe()
            let translator = RealtimeTranslator(source: .system, key: key, language: "zh",
                onSegment: { await probe.segment($0) },
                onState: { state in report("replay_state", "info", state); await probe.state(state) },
                onAudio: { await probe.audio($0) })
            await translator.start()
            for _ in 0..<220 {
                if await probe.ready { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard await probe.ready else { await translator.stop(); report("replay", "fail", "Connection failed"); return }
            await probe.begin()
            let router = AudioPacketRouter()
            router.setRoutes([.system: [{ packet in await translator.append(packet) }]])
            let clock = ContinuousClock(), began = clock.now
            var offset = 0
            let silenceBytes = 3 * 48000
            while offset < pcm.count + silenceBytes {
                let stop = min(pcm.count + silenceBytes, offset + frames * 2)
                var packet = Data()
                if offset < pcm.count { packet.append(pcm.subdata(in: offset..<min(stop, pcm.count))) }
                if stop > pcm.count { packet.append(Data(repeating: 0, count: stop - max(pcm.count, offset))) }
                router.append(.init(source: .system, pcm: packet, time: Double(offset) / 48000))
                offset = stop
                try await clock.sleep(until: began.advanced(by: .seconds(Double(offset) / 48000)))
            }
            await router.finish()
            await translator.finish()
            let stats = await translator.statistics
            report("replay_bytes", "info", "received=\(stats.receivedBytes) sent=\(stats.sentBytes) dropped=\(stats.droppedBytes)")
            report("replay_events", "info", stats.events.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
            let source = await probe.sourceText, translated = await probe.text
            report("replay_transcript", source.isEmpty ? "fail" : "pass", "source_chars=\(source.count) translation_chars=\(translated.count) output_bytes=\(await probe.outputBytes)")
            if let delay = await probe.firstTextDelay { report("replay_first_translation", "measured", String(format: "%.2fs", delay)) }
        } catch { report("replay", "fail", error.localizedDescription.replacingOccurrences(of: key, with: "[redacted]")) }
    }
    static func checkLiveTranslation(client: OpenAIClient, key: String) async {
        // Synthetic speech only; never starts capture or opens meeting files.
        do {
            let pcm = try await client.speech("We will meet next Tuesday at ten in the morning. The budget is three thousand dollars.")
            let probe = TranslationProbe()
            let translator = RealtimeTranslator(source: .system, key: key, language: "zh",
                onSegment: { await probe.segment($0) },
                onState: { state in report("live_translation_state", "info", state); await probe.state(state) },
                onAudio: { await probe.audio($0) },
                onTranscriptEvent: { input, text, time in
                    report(input ? "source_delta" : "translation_delta", "info", "\(time ?? -1) ms: \(text)")
                })
            await translator.start()
            for _ in 0..<220 {
                if await probe.ready { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard await probe.ready else { await translator.stop(); report("live_translation", "fail", "No session.updated acknowledgment"); return }
            await probe.begin()
            var offset = 0
            while offset < pcm.count {
                let end = min(pcm.count, offset + 4800)
                await translator.append(.init(source: .system, pcm: pcm.subdata(in: offset..<end), time: Double(offset) / 48000))
                offset = end; try await Task.sleep(nanoseconds: 100_000_000)
            }
            for n in 0..<20 {
                await translator.append(.init(source: .system, pcm: Data(repeating: 0, count: 4800), time: Double(pcm.count) / 48000 + Double(n) / 10))
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            await translator.finish()
            let text = await probe.text, bytes = await probe.outputBytes
            report("live_translation", text.isEmpty || bytes == 0 ? "fail" : "pass", text)
            let sourceText = await probe.sourceText
            report("paired_source_transcript", sourceText.isEmpty ? "fail" : "pass", sourceText)
            if let delay = await probe.firstTextDelay {
                report("first_translated_text", "measured", String(format: "%.2f seconds from synthetic audio start; not a real-meeting latency benchmark", delay))
            }
            report("translated_audio", bytes > 0 ? "pass" : "fail", "\(bytes) PCM bytes received; not played")
        } catch { report("live_translation", "fail", error.localizedDescription) }
    }
}
