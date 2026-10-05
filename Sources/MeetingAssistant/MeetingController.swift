import Foundation
import SwiftUI
import AVFoundation
import MeetingCore

@MainActor final class AudioLevels: ObservableObject {
    @Published var microphone = 0.0
    @Published var system = 0.0
}

@MainActor final class MeetingController: ObservableObject {
    @Published var preferences: AppPreferences
    @Published var meetings: [Meeting] = []
    /// Selecting a record replaces any calendar item in the detail pane.
    @Published var selectedID: UUID? { didSet { if selectedID != nil { calendarSelection = nil } } }
    enum CalendarSelection: Hashable { case event(String), agenda }
    /// A calendar event or the agenda shown in the detail pane instead of a record.
    @Published var calendarSelection: CalendarSelection?
    @Published var devices: [AudioDevice] = []
    @Published var hasSavedKey = false
    @Published var needsKeySetup = false
    var hasKey: Bool { hasSavedKey }
    @Published var error: String?
    @Published var keyStatus = ""
    @Published var status = "准备开始"
    @Published var recording = false
    @Published var paused = false
    @Published var processing = false
    @Published var starting = false
    @Published var elapsed = 0.0
    let audioLevels = AudioLevels()
    let audioSetup = BlackHoleSetup()
    let captionOverlay = CaptionOverlay()
    let calendar: CalendarController
    let briefs: BriefController
    /// Generic start entries show this when calendar meetings are due, instead of guessing by time.
    @Published var startChooserPresented = false
    var micLevel: Double { get { audioLevels.microphone } set { audioLevels.microphone = newValue } }
    var systemLevel: Double { get { audioLevels.system } set { audioLevels.system = newValue } }
    @Published var micState = "未连接"
    @Published var systemState = "未连接"
    @Published var voiceState = "译音未发送"
    @Published var voiceRouteState = "开启同传会自动切换系统麦克风，停止后恢复"
    @Published var sendingVoice = false
    var voiceNeedsRouteRestore: Bool { microphoneRoute.active && !sendingVoice }
    @Published var translationStates: [AudioSource: String] = [:]
    private let store: MeetingStore
    private let apiSession: URLSession?
    private let credentials: CredentialSession
    private var capture: AudioCapture?
    private var client: OpenAIClient?
    private var timer: Timer?
    private var translators: [AudioSource: RealtimeTranslator] = [:]
    private var closingTranslators: [Task<Void, Never>] = []
    private var translationEpoch = UUID()
    private var outgoingTranslator: LiveInterpreter?
    private let voice = VoiceOutput()
    private let microphoneRoute: MicrophoneRoute
    private var lastOutgoingStatistics: TranslationStatistics?
    private var stoppedVoiceTasks: [Task<Void, Never>] = []
    private var activeID: UUID?
    private var voiceEpoch = UUID()
    private var audioRouter: AudioPacketRouter?
    private var lastSaved = Date.distantPast
    private var lastDiagnostics = Date.distantPast
    var storageURL: URL { store.root }
    var current: Meeting? { meetings.first { $0.id == selectedID } }
    /// The meeting being captured, independent of the library selection.
    var liveMeeting: Meeting? {
        guard recording, let activeID else { return nil }
        return meetings.first { $0.id == activeID }
    }
    var busy: Bool { recording || processing || starting }
    var microphones: [AudioDevice] { devices.filter { $0.input && !$0.virtual && !$0.name.contains("MeetingAssistant") } }
    var virtualOutputs: [AudioDevice] { devices.filter { $0.input && $0.output && $0.virtual } }
    var modelNames: String { "字幕 gpt-realtime-translate / gpt-live-transcribe · 译音 \(LiveInterpreter.model)（\(preferences.outgoingVoice.name)）· 总结 \(OpenAIClient.textModel)" }

    init(storageRoot: URL? = nil, apiSession: URLSession? = nil, credentialStorage: CredentialStorage = KeychainCredentialStorage(),
         calendar: CalendarController? = nil) {
        self.apiSession = apiSession
        let calendar = calendar ?? CalendarController()
        self.calendar = calendar
        // Test stores keep their briefs beside the meetings; MeetingStore ignores non-UUID folders.
        briefs = BriefController(calendar: calendar, storeRoot: storageRoot?.appendingPathComponent("Briefs", isDirectory: true),
                                 apiSession: apiSession)
        credentials = CredentialSession(storage: credentialStorage)
        preferences = UserDefaults.standard.data(forKey: "preferences").flatMap { try? JSONDecoder().decode(AppPreferences.self, from: $0) } ?? AppPreferences()
        do { store = try MeetingStore(root: storageRoot) } catch { fatalError("无法打开会议存储目录：\(error.localizedDescription)") }
        microphoneRoute = MicrophoneRoute(journal: store.root.appendingPathComponent("microphone-route.json"))
        do { try microphoneRoute.restore() }
        catch { self.error = error.localizedDescription }
        do {
            meetings = try store.all()
            for index in meetings.indices { try store.recover(&meetings[index]) }
            selectedID = meetings.first?.id
        } catch { self.error = error.localizedDescription }
        audioSetup.configureDevices = { [weak self] devices in self?.configureDevices(devices) }
        audioSetup.meetingIsBusy = { [weak self] in self?.busy ?? true }
        captionOverlay.attach(self)
        refreshDevices()
        // Avoid prompting for Keychain access at every launch; read only when the user initiates API work.
        hasSavedKey = UserDefaults.standard.bool(forKey: "hasSavedCredentialV2")
        if !hasSavedKey, UserDefaults.standard.bool(forKey: "hasKey") {
            keyStatus = "升级后请重新填写 Key 并保存。"
        }
        briefs.makeClient = { [unowned self] in try self.makeClient().1 }
        briefs.history = { [unowned self] event in self.seriesRecords(for: event) }
        briefs.language = { [unowned self] in self.preferences.subtitleLanguage }
        briefs.hasOpenAIKey = { [unowned self] in self.hasSavedKey }
        calendar.onSynced = { [weak self] in
            guard let self else { return }
            self.briefs.reload()
            Task { await self.briefs.generateDue() }
        }
        calendar.onDisconnected = { [weak self] in self?.briefs.clear() }
        voice.onState = { [weak self] text in self?.voiceState = text }
        voice.onError = { [weak self] text in
            guard let self else { return }
            self.outgoingFailure(text, epoch: self.voiceEpoch)
        }
    }
    func savePreferences() {
        if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "preferences") }
    }
    func refreshDevices() {
        if !busy { audioSetup.refresh(); return }
        do {
            _ = configureDevices(try AudioDevices.list())
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult private func configureDevices(_ available: [AudioDevice]) -> AudioDevice? {
        devices = available
        let before = (preferences.microphoneUID, preferences.outputUID)
        if preferences.microphoneUID.isEmpty {
            let id = try? AudioDevices.defaultInput()
            preferences.microphoneUID = microphones.first { $0.id == id }?.uid ?? microphones.first?.uid ?? ""
        }
        let preferred = AudioDevices.preferredTranslationOutput(in: available, currentUID: preferences.outputUID)
        // An in-flight meeting must not silently change to a different output.
        if let preferred, !busy || preferences.outputUID.isEmpty || preferred.uid == preferences.outputUID {
            preferences.outputUID = preferred.uid
        }
        if before != (preferences.microphoneUID, preferences.outputUID) { savePreferences() }
        return virtualOutputs.first { $0.uid == preferences.outputUID }
    }
    @discardableResult func saveKey(_ key: String) -> Bool {
        do {
            try credentials.save(key); hasSavedKey = true
            client = nil
            UserDefaults.standard.set(true, forKey: "hasSavedCredentialV2")
            keyStatus = "Key 已保存，下次启动可继续使用。"
            Task { await briefs.generateDue() }
            return true
        } catch { keyStatus = error.localizedDescription; return false }
    }
    func removeKey() {
        do {
            try credentials.deleteSaved(); hasSavedKey = false; UserDefaults.standard.set(false, forKey: "hasSavedCredentialV2")
            client = nil; keyStatus = "已删除保存的 Key。"
        }
        catch { keyStatus = error.localizedDescription }
    }
    private func makeClient() throws -> (String, OpenAIClient) {
        let key = try credentials.key()
        return (key, OpenAIClient(key: key, session: apiSession))
    }
    func verifyKey() async {
        keyStatus = "正在验证…"
        do {
            let (_, client) = try makeClient()
            let models = try await client.models()
            let missing = ["gpt-live-transcribe", RealtimeTranslator.model, LiveInterpreter.model].filter { !models.contains($0) }
            keyStatus = missing.isEmpty ? "Key 有效，已发现实时字幕与固定音色译音模型；实际会话权限在开始时验证" :
                "Key 有效；账户未列出 \(missing.joined(separator: "、"))，需确认模型权限"
        } catch { keyStatus = "验证失败：\(error.localizedDescription)" }
    }
    /// Calendar occurrences that already have a record no longer lead the start entries.
    var recordedEventKeys: Set<CalendarEventKey> { Set(meetings.compactMap { $0.calendar?.key }) }
    var prominentEvents: [CalendarEvent] {
        guard let account = calendar.account else { return [] }
        return CalendarSchedule.prominent(calendar.events, at: calendar.now, account: account, recorded: recordedEventKeys)
    }
    var upcomingEvents: [CalendarEvent] {
        calendar.account == nil ? [] : CalendarSchedule.upcoming(calendar.events, at: calendar.now)
    }
    var selectedEvent: CalendarEvent? {
        guard case .event(let id) = calendarSelection else { return nil }
        return calendar.events.first { $0.id == id }
    }
    func seriesRecords(for event: CalendarEvent) -> [Meeting] {
        guard let account = calendar.account else { return [] }
        return CalendarSchedule.seriesRecords(meetings, for: event, account: account)
    }
    var startableEvents: [CalendarEvent] {
        calendar.account == nil ? [] : CalendarSchedule.startable(calendar.events, at: calendar.now)
    }
    func records(for event: CalendarEvent) -> [Meeting] {
        guard let key = calendar.key(for: event) else { return [] }
        return meetings.filter { $0.calendar?.key == key }
    }
    /// The sidebar, welcome page and ⌘N all come here, so no entry skips choosing the calendar meeting.
    func requestStart() async {
        guard !busy else { return }
        if prominentEvents.isEmpty { await startMeeting() } else { startChooserPresented = true }
    }
    func startMeeting(event: CalendarEvent) async {
        guard let link = calendar.link(for: event) else {
            error = "Google 账号已断开，无法关联这场日程。请重新连接后再开始，或开始临时会议。"; return
        }
        await startMeeting(link: link)
    }
    /// Adds another record for the same occurrence, e.g. after an interruption.
    func appendRecord(to meeting: Meeting) async {
        guard var link = meeting.calendar else { return }
        link.linkedAt = Date()
        await startMeeting(link: link)
    }
    func startMeeting(link: CalendarLink? = nil) async {
        guard !busy else { return }
        startChooserPresented = false
        guard !audioSetup.working else { error = "音频组件正在准备安装，请完成或取消后再开始会议。"; return }
        starting = true; defer { starting = false }
        status = "正在准备会议…"
        var createdMeetingID: UUID?
        do {
            let (key, client) = try makeClient()
            refreshDevices()
            guard let microphone = microphones.first(where: { $0.uid == preferences.microphoneUID }) else {
                throw MeetingError.message("请选择当前连接的真实麦克风。")
            }
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else { throw MeetingError.message("请在系统设置 → 隐私与安全性 → 麦克风中允许 MeetingAssistant。") }
            var meeting = Meeting(calendar: link, subtitleLanguage: preferences.subtitleLanguage, outgoingLanguage: preferences.outgoingLanguage)
            // The record keeps the brief as it stood at the start, as background for its summary.
            if let link, link.account == calendar.account { meeting.brief = briefs.brief(for: link.eventID) }
            // The record and its calendar link are saved before capture; a failure here starts nothing.
            try store.save(meeting)
            createdMeetingID = meeting.id
            meetings.insert(meeting, at: 0); selectedID = meeting.id; activeID = meeting.id
            self.client = client; translationStates = [:]; translationEpoch = UUID()
            lastOutgoingStatistics = nil
            let capture = AudioCapture(); self.capture = capture
            let router = AudioPacketRouter(); audioRouter = router
            capture.onPacket = { packet in router.append(packet) }
            capture.onLevel = { [weak self] source, value in Task { @MainActor in
                if source == .microphone { self?.micLevel = value } else { self?.systemLevel = value }
            } }
            capture.onFailure = { [weak self] message in Task { @MainActor in
                guard let self, self.recording else { return }
                self.error = message; self.notice(message); await self.finishMeeting(process: false)
            } }
            for source in AudioSource.allCases {
                translators[source] = makeTranslator(source: source, key: key, language: meeting.subtitleLanguage, meetingID: meeting.id)
            }
            updateAudioRoutes()
            try await capture.start(folder: store.folder(meeting.id), microphone: microphone)
            recording = true; paused = false; elapsed = 0; status = "正在记录"
            for translator in translators.values { Task { await translator.start() } }
            captionOverlay.meetingStarted()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.elapsed = self.capture?.elapsed ?? self.elapsed
                    self.checkVoiceRoute()
                    self.updateActive { $0.duration = self.elapsed }
                    self.saveActive()
                    if Date().timeIntervalSince(self.lastDiagnostics) >= 5 {
                        self.lastDiagnostics = Date()
                        await self.saveAudioDiagnostics()
                    }
                }
            }
        } catch {
            if error is CredentialError { keyStatus = error.localizedDescription; needsKeySetup = true }
            else { self.error = error.localizedDescription }
            let chunks = capture?.stop() ?? []; capture = nil
            await audioRouter?.finish(); audioRouter = nil
            recording = false
            for translator in translators.values { await translator.stop() }
            translators = [:]
            if createdMeetingID != nil {
                updateActive { $0.chunks = chunks; $0.state = "interrupted"; $0.addNotice(error.localizedDescription) }
                saveActive()
            }
        }
    }
    private func updateActive(_ change: (inout Meeting) -> Void) {
        guard let id = activeID, let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[index])
    }
    private func saveActive() {
        guard let id = activeID, let meeting = meetings.first(where: { $0.id == id }) else { return }
        do { try store.save(meeting); lastSaved = Date() } catch { self.error = "保存失败：\(error.localizedDescription)" }
    }
    private func notice(_ text: String) { updateActive { $0.addNotice(text) } }
    private func updateAudioRoutes() {
        var routes: [AudioSource: [AudioPacketRouter.Sink]] = [:]
        for (source, translator) in translators {
            routes[source, default: []].append { packet in await translator.append(packet) }
        }
        if let outgoingTranslator {
            routes[.microphone, default: []].append { packet in await outgoingTranslator.append(packet) }
        }
        audioRouter?.setRoutes(routes)
    }
    private func saveAudioDiagnostics() async {
        guard let id = activeID, let capture else { return }
        let counts = capture.byteCounts
        var connections: [String: TranslationStatistics] = [:]
        for (source, translator) in translators { connections[source.rawValue] = await translator.statistics }
        if let outgoingTranslator { lastOutgoingStatistics = await outgoingTranslator.statistics }
        connections["outgoing"] = lastOutgoingStatistics
        guard activeID == id else { return }
        struct Snapshot: Encodable {
            let capturedBytes: [String: Int]
            let dispatchDroppedBytes: [String: Int]
            let connections: [String: TranslationStatistics]
            let voicePlayback: VoiceOutput.Statistics
            let automaticMicrophoneRouteActive: Bool
        }
        let snapshot = Snapshot(capturedBytes: Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) }),
            dispatchDroppedBytes: Dictionary(uniqueKeysWithValues: (audioRouter?.droppedBytes ?? [:]).map { ($0.key.rawValue, $0.value) }),
            connections: connections, voicePlayback: voice.statistics, automaticMicrophoneRouteActive: microphoneRoute.active)
        // Counts and protocol event names only: no audio, transcript or credentials.
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: store.folder(id).appendingPathComponent("audio-diagnostics.json"), options: .atomic)
        } catch { self.error = "无法保存音频诊断：\(error.localizedDescription)" }
    }
    private func makeTranslator(source: AudioSource, key: String, language: String, meetingID: UUID) -> RealtimeTranslator {
        let epoch = translationEpoch
        return RealtimeTranslator(source: source, key: key, language: language,
            onSegment: { [weak self] segment in await self?.receiveTranslation(segment, meetingID: meetingID) },
            onState: { [weak self] state in await self?.translationState(state, source: source, meetingID: meetingID, epoch: epoch) })
    }
    private func receiveTranslation(_ segment: TranscriptSegment, meetingID: UUID) {
        guard activeID == meetingID else { return }
        updateActive { $0.upsert(segment) }
        if Date().timeIntervalSince(lastSaved) > 1 { saveActive() }
    }
    private func translationState(_ state: String, source: AudioSource, meetingID: UUID, epoch: UUID) {
        guard activeID == meetingID else { return }
        if state.contains("未完整") || state.contains("未确认") { notice(state) }
        guard epoch == translationEpoch else { return }
        translationStates[source] = state
        if source == .microphone { micState = state } else { systemState = state }
    }
    func togglePause() {
        guard recording else { return }
        paused.toggle(); capture?.setPaused(paused)
        stopVoice(); updateActive { $0.state = paused ? "paused" : "recording" }
        translationEpoch = UUID()
        if paused {
            for translator in translators.values {
                closingTranslators.append(Task { await translator.finish() })
            }
            translators = [:]; updateAudioRoutes(); translationStates = [:]; micState = "已暂停"; systemState = "已暂停"
        } else if let meeting = current {
            do {
                let (key, _) = try makeClient()
                for source in AudioSource.allCases {
                    let translator = makeTranslator(source: source, key: key, language: meeting.subtitleLanguage, meetingID: meeting.id)
                    translators[source] = translator; Task { await translator.start() }
                }
                updateAudioRoutes()
            } catch { self.error = error.localizedDescription }
        }
        status = paused ? "已暂停采集" : "正在记录"; saveActive()
    }
    func toggleVoice() {
        guard recording, !paused else { return }
        if voiceNeedsRouteRestore { stopVoice(); return }
        if sendingVoice { stopVoice(); return }
        do {
            refreshDevices()
            guard let device = virtualOutputs.first(where: { $0.uid == preferences.outputUID }) else {
                throw MeetingError.message("同传音频设备尚未就绪。请结束会议后，在设置中完成 BlackHole 安装或重新检测设备。")
            }
            let (key, _) = try makeClient()
            voiceEpoch = UUID(); let epoch = voiceEpoch
            try voice.start(device: device)
            try microphoneRoute.start(device: device)
            sendingVoice = true
            voiceRouteState = "系统麦克风已切换到 \(device.name) · 停止同传后恢复"
            let translator = LiveInterpreter(key: key,
                language: current?.outgoingLanguage ?? preferences.outgoingLanguage,
                voice: preferences.outgoingVoice,
                onState: { [weak self] state in await self?.outgoingState(state, epoch: epoch) },
                onAudio: { [weak self] pcm in await self?.receiveVoice(pcm, epoch: epoch) },
                onFatal: { [weak self] message in await self?.outgoingFailure(message, epoch: epoch) })
            outgoingTranslator = translator
            updateAudioRoutes()
            Task { await translator.start() }
        } catch { stopVoice(); self.error = error.localizedDescription }
    }
    private func checkVoiceRoute() {
        guard sendingVoice else { return }
        do { try microphoneRoute.validate() }
        catch { stopVoice(); self.error = error.localizedDescription; voiceRouteState = error.localizedDescription }
    }
    private func outgoingState(_ state: String, epoch: UUID) {
        guard voiceEpoch == epoch, sendingVoice else { return }
        voiceState = state
    }
    private func receiveVoice(_ pcm: Data, epoch: UUID) {
        guard voiceEpoch == epoch, sendingVoice, !paused, recording else { return }
        voice.enqueuePCM(pcm)
    }
    private func outgoingFailure(_ message: String, epoch: UUID) {
        guard voiceEpoch == epoch, sendingVoice else { return }
        stopVoice(restoreMicrophone: false); error = message; voiceState = message
    }
    func stopVoice(restoreMicrophone: Bool = true) {
        voiceEpoch = UUID()
        if let translator = outgoingTranslator {
            let meetingID = activeID, epoch = voiceEpoch
            stoppedVoiceTasks.append(Task { [weak self] in
                await translator.stop()
                let statistics = await translator.statistics
                guard let self, self.activeID == meetingID, self.voiceEpoch == epoch else { return }
                self.lastOutgoingStatistics = statistics
            })
        }
        outgoingTranslator = nil
        updateAudioRoutes()
        voice.stop(); sendingVoice = false
        if restoreMicrophone {
            do {
                try microphoneRoute.restore()
                voiceRouteState = "同传未开启 · 系统麦克风已恢复或保留你的当前选择"
            } catch { self.error = error.localizedDescription; voiceRouteState = error.localizedDescription }
        } else {
            voiceRouteState = "译音故障，虚拟麦克风保持静音 · 点击恢复原麦克风"
        }
    }
    func finishMeeting(process: Bool = true) async {
        guard recording, let id = activeID else { return }
        recording = false; paused = false; starting = true; status = "正在保存尾音…"
        stopVoice(); timer?.invalidate(); timer = nil
        for task in stoppedVoiceTasks { await task.value }; stoppedVoiceTasks = []
        await saveAudioDiagnostics()
        elapsed = capture?.elapsed ?? elapsed
        let chunks = capture?.stop() ?? []; capture = nil
        await audioRouter?.finish(); audioRouter = nil
        async let micTranslation: Void? = translators[.microphone]?.finish()
        async let systemTranslation: Void? = translators[.system]?.finish()
        _ = await (micTranslation, systemTranslation); translators = [:]
        for task in closingTranslators { await task.value }; closingTranslators = []
        micLevel = 0; systemLevel = 0; starting = false
        await finalizeRecording(id: id, chunks: chunks, duration: elapsed, generateSummary: process)
    }
    // Called after capture and all realtime connections have drained their final segments.
    func finalizeRecording(id: UUID, chunks: [AudioChunk], duration: Double, generateSummary: Bool) async {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].chunks = chunks; meetings[index].duration = duration; meetings[index].state = "recorded"
        do { try store.save(meetings[index]); lastSaved = Date() }
        catch { self.error = "保存失败：\(error.localizedDescription)"; status = "记录尚未保存"; return }
        status = "实时原文与录音已保存"
        if generateSummary { await updateSummary(for: id) }
    }
    func updateSummary(for meetingID: UUID? = nil) async {
        guard !busy, let id = meetingID ?? selectedID, let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        processing = true
        defer { processing = false }
        do {
            let meeting = meetings[index]
            guard meeting.liveSegments.contains(where: \.hasText) else {
                throw MeetingError.message("没有可总结的实时原文。录音已保存在本地。")
            }
            let (_, client) = try makeClient()
            var background = meeting, backgroundNote = ""
            // A linked record without a brief gets one first, so the summary can compare against mail and earlier meetings.
            if let link = meeting.calendar, meeting.brief == nil, link.account == calendar.account {
                status = "正在整理会前背景（日历、邮件和历史记录）…"
                do {
                    let brief = try await briefs.briefAfterwards(for: link)
                    background.brief = brief
                    if var stored = meetings.first(where: { $0.id == id }) {
                        stored.brief = brief
                        try store.save(stored); replace(stored)
                    }
                } catch {
                    backgroundNote = "；未能读取会前背景（\(error.localizedDescription)），本次只基于实时原文"
                }
            }
            status = "正在根据\(meeting.defaultTranscriptSource.title)生成总结…"
            let summary = try await client.summarize(background)
            // A manual rename may arrive while the request is in flight.
            guard var updated = meetings.first(where: { $0.id == id }) else { return }
            updated.applySummary(summary)
            try store.save(updated); replace(updated)
            status = "会议总结已更新" + backgroundNote
        } catch {
            if error is CredentialError { keyStatus = error.localizedDescription; needsKeySetup = true }
            self.error = error.localizedDescription
            status = "总结未更新，原有记录已保留"
        }
    }
    private func replace(_ meeting: Meeting) { if let i = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[i] = meeting } }
    func deleteMeeting(_ id: UUID) {
        guard !busy, let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        do {
            try store.delete(id)
            if activeID == id { activeID = nil }
            meetings.remove(at: index)
            if selectedID == id {
                selectedID = meetings.isEmpty ? nil : meetings[min(index, meetings.count - 1)].id
            }
        } catch {
            self.error = "删除会议失败：\(error.localizedDescription)"
        }
    }
    func renameMeeting(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = selectedID, let i = meetings.firstIndex(where: { $0.id == id }), !text.isEmpty else { return }
        var meeting = meetings[i]
        meeting.title = text; meeting.titleSource = .manual
        do { try store.save(meeting); replace(meeting) } catch { self.error = error.localizedDescription }
    }
    /// Links, corrects or removes a record's calendar occurrence without touching recordings, transcript or summary.
    func linkMeeting(_ id: UUID, to event: CalendarEvent?) {
        guard !busy, let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        var meeting = meetings[index]
        if let event {
            guard let link = calendar.link(for: event) else { error = "Google 账号已断开，无法关联日程。"; return }
            if meeting.calendar?.key != link.key { meeting.brief = briefs.brief(for: event.id) }
            meeting.link(link)
        } else { meeting.link(nil); meeting.brief = nil }
        do { try store.save(meeting); replace(meeting) } catch { self.error = "关联未保存：\(error.localizedDescription)" }
    }
    func revealInFinder(_ id: UUID) {
        NSWorkspace.shared.activateFileViewerSelecting([store.folder(id)])
    }
    func export() {
        guard let meeting = current else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = meeting.title + ".md"; panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            do { try meeting.markdown().write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
        }
    }
}
