import SwiftUI
import MeetingCore

// Render the production views with synthetic state, without starting capture or API work.
@MainActor final class RegressionState: ObservableObject {
    @Published var previewAudioSetup = false
    let controller: MeetingController
    private let folder: URL
    init() {
        if CommandLine.arguments.contains("--check-audio-levels") {
            do { try checkAudioLevelIsolation(); exit(0) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingUIRegression-" + UUID().uuidString)
        controller = MeetingController(storageRoot: folder)
    }
    func show(_ state: String) {
        controller.starting = state == "preparing"
        controller.recording = state == "recording"
        controller.processing = state == "processing"
        controller.paused = false
        controller.status = "离线界面测试"
        var meeting = Meeting(title: "离线测试会议")
        meeting.state = state
        do { try MeetingStore(root: folder).save(meeting) }
        catch { controller.error = error.localizedDescription }
        controller.meetings = [meeting]
        controller.selectedID = meeting.id
        controller.micLevel = 0.35
        controller.systemLevel = 0.7
    }
    func captions(complete: Bool = false) {
        show(complete ? "complete" : "recording")
        var meeting = controller.meetings[0]
        let samples = [("Can you hear me?", "你能听到我吗？"), ("We will meet next Tuesday at ten.", "我们下周二上午十点开会。"), ("我可以听见了，可以。", "我可以听见了，可以。")]
        let segments: [TranscriptSegment] = (0..<32).map { index -> TranscriptSegment in
            let sample = samples[index % 3]
            let source: AudioSource = index % 3 == 2 ? .microphone : .system
            let text = sample.0
            let translation: String? = sample.1
            return TranscriptSegment(id: "sample-\(index)", source: source,
                start: Double(index * 4), end: Double(index * 4 + 3), text: text,
                translation: translation, isFinal: true)
        }
        meeting.liveSegments = segments
        if complete { meeting.finalSegments = segments }
        controller.meetings = [meeting]
        controller.translationStates = [.microphone: "实时同传已连接", .system: "实时同传已连接"]
    }
    func append(translation: Bool = false, grow: Bool = false) {
        guard !controller.meetings.isEmpty else { return }
        if translation {
            guard let index = controller.meetings[0].liveSegments.indices.last else { return }
            controller.meetings[0].liveSegments[index].translation = "请确认下周的会议时间。"
        } else if grow, let index = controller.meetings[0].liveSegments.indices.last {
            controller.meetings[0].liveSegments[index].text += " This is an incremental update to the SAME utterance, testing text wrapping and automatic scrolling."
        } else {
            let index = controller.meetings[0].liveSegments.count
            controller.meetings[0].liveSegments.append(.init(id: "added-source-\(index)", source: .system,
                start: Double(index * 4), end: Double(index * 4 + 3), text: "Please confirm the next meeting.", isFinal: false))
        }
    }
    deinit { try? FileManager.default.removeItem(at: folder) }
}

@main struct MeetingUIRegressionApp: App {
    @StateObject private var state = RegressionState()
    init() {
        if CommandLine.arguments.contains("--check-summary") {
            Task { @MainActor in
                do { try await checkSummaryPreservation(); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
        }
        if CommandLine.arguments.contains("--check-deletion") {
            do { try checkMeetingDeletion(); exit(0) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
    }
    var body: some Scene {
        WindowGroup {
            if CommandLine.arguments.contains("--preview-blackhole") {
                BlackHolePreview()
            } else {
            VStack(spacing: 0) {
                HStack {
                    Text("离线回归：不录音、不联网").font(.caption)
                    Button("准备界面") { state.show("preparing") }
                    Button("录音界面") { state.show("recording") }
                    Button("空记录界面") { state.show("recorded") }
                    Button("总结界面") { state.show("processing") }
                    Button("错误提示") { state.controller.error = "离线测试错误：音频设备不可用" }
                    Button("实时字幕") { state.captions() }
                    Button("追加原文") { state.append() }
                    Button("同段增长") { state.append(grow: true) }
                    Button("追加译文") { state.append(translation: true) }
                    Button("会后全文") { state.captions(complete: true) }
                    Button("安装引导") { state.previewAudioSetup = true }
                }.padding(10)
                ContentView(controller: state.controller)
            }.frame(minWidth: 1100, minHeight: 760)
                .sheet(isPresented: $state.previewAudioSetup) { BlackHolePreview() }
            }
        }
    }
}
