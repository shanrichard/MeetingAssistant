import AppKit
import Foundation
import MeetingCore

/// The connected Google account and the coming week's calendar. Only reads; never changes the calendar.
@MainActor final class CalendarController: ObservableObject {
    enum SyncState: Equatable { case idle, syncing, synced, failed(String) }
    @Published private(set) var account: String?
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var syncState: SyncState = .idle
    @Published private(set) var lastSynced: Date?
    @Published private(set) var connecting = false
    /// The stored authorization no longer works; automatic syncing waits for the user to reconnect.
    @Published private(set) var needsReconnect = false
    @Published var status = ""
    /// Granted Google scopes; mail is optional and may be missing on connections made before it was requested.
    @Published private(set) var scopes: [String] = []
    var mailAuthorized: Bool { scopes.contains(GoogleScope.mail) }
    var onSynced: (() -> Void)?
    var onDisconnected: (() -> Void)?
    /// Advanced by a timer so countdowns and the start window follow the clock.
    @Published private(set) var now = Date()
    let configured: Bool
    private let session: GoogleSession?
    private let auth: GoogleAuthClient?
    private let client: GoogleCalendarClient
    private var receiver: LoopbackRedirectReceiver?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var lastAttempt: Date?
    private static let accountKey = "googleAccountEmail"
    private static let scopesKey = "googleScopes"
    static let syncInterval: TimeInterval = 5 * 60
    /// How far ahead the agenda reads.
    static let range: TimeInterval = 7 * 24 * 3600
    private let diagnostics: URL?

    init(info: [String: Any]? = Bundle.main.infoDictionary, apiSession: URLSession? = nil,
         storage: CredentialStorage = KeychainCredentialStorage(service: "com.meetingassistant.google", account: "oauth-v1",
                                                                label: "Meeting Assistant Google 授权"),
         diagnostics: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MeetingAssistant/calendar-sync.json")) {
        client = GoogleCalendarClient(session: apiSession)
        self.diagnostics = diagnostics
        if let configuration = GoogleOAuthConfiguration(info: info) {
            let auth = GoogleAuthClient(configuration: configuration, session: apiSession)
            self.auth = auth; session = GoogleSession(auth: auth, storage: storage); configured = true
        } else { auth = nil; session = nil; configured = false }
        // The address only labels the connection; the authorization itself lives in the Keychain.
        if configured {
            account = UserDefaults.standard.string(forKey: Self.accountKey)
            scopes = UserDefaults.standard.stringArray(forKey: Self.scopesKey) ?? []
        }
    }

    /// Begins clock ticks and syncing. Called once the main window appears.
    func start() {
        guard !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let center = NotificationCenter.default, workspace = NSWorkspace.shared.notificationCenter
        for (notifications, name) in [(center, NSApplication.didBecomeActiveNotification), (center, .NSSystemClockDidChange),
                                      (center, .NSSystemTimeZoneDidChange), (workspace, NSWorkspace.didWakeNotification)] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    // Waking, clock and time zone changes invalidate everything computed from the old time.
                    let force = notification.name != NSApplication.didBecomeActiveNotification
                    self?.tick(force: force)
                }
            })
        }
        tick(force: true)
    }

    private func tick(force: Bool = false) {
        now = Date()
        guard account != nil, !needsReconnect, syncState != .syncing else { return }
        // Failures retry sooner than the regular refresh, without hammering an offline network.
        let interval = syncState == .synced ? Self.syncInterval : 60
        let due = lastAttempt.map { now.timeIntervalSince($0) >= interval || $0 > now } ?? true
        if force || due { Task { await sync() } }
    }

    var connectionLabel: String {
        guard configured else { return "此版本未配置 Google 客户端" }
        guard let account else { return "未连接" }
        return account
    }

    func connect() async {
        guard let auth, let session, !connecting else { return }
        connecting = true; defer { connecting = false; receiver = nil }
        status = "请在浏览器中使用公司 Google 账号完成授权…"
        do {
            let state = PKCE.randomVerifier(), pkce = PKCE()
            let receiver = try await LoopbackRedirectReceiver.start(state: state)
            self.receiver = receiver
            let url = auth.authorizationURL(redirectURI: receiver.redirectURI, state: state, pkce: pkce,
                                            scopes: GoogleScope.all, loginHint: account)
            guard NSWorkspace.shared.open(url) else { throw MeetingError.message("无法打开浏览器完成授权。") }
            let code = try await receiver.code()
            let connected = try await session.connect(code: code, redirectURI: receiver.redirectURI, pkce: pkce)
            account = connected.email; needsReconnect = false
            UserDefaults.standard.set(connected.email, forKey: Self.accountKey)
            setScopes(connected.scopes)
            NSApp.activate(ignoringOtherApps: true)
            status = mailAuthorized ? "已连接 \(connected.email)，可读取日历和邮件。" : "已连接 \(connected.email)。未允许读取邮件，会前说明不会参考邮件。"
            await sync()
        } catch is CancellationError {
            status = "已取消连接。"
        } catch {
            status = error.localizedDescription
        }
    }

    func cancelConnect() { receiver?.cancel() }

    func disconnect() async {
        guard let session else { return }
        do {
            try await session.disconnect()
            UserDefaults.standard.removeObject(forKey: Self.accountKey)
            account = nil; events = []; lastSynced = nil; syncState = .idle; needsReconnect = false
            setScopes([])
            onDisconnected?()
            status = "已断开 Google 账号。已关联的会议记录保持不变，缓存的会前说明已删除。"
        } catch { status = error.localizedDescription }
    }

    /// Meetings that have not ended yet and start within the coming week.
    func sync() async {
        guard account != nil, syncState != .syncing else { return }
        syncState = .syncing; lastAttempt = Date()
        defer { saveDiagnostics() }
        do {
            let start = Date()
            events = try await fetch(from: start, to: start.addingTimeInterval(Self.range))
            lastSynced = Date(); syncState = .synced
            // Connections made before mail was requested have no stored scopes; read them once from the authorization.
            if scopes.isEmpty, let granted = try? await session?.scopes() { setScopes(granted) }
            onSynced?()
        } catch {
            // Failing to read the calendar is not the same as having no meetings; keep what was last read and say so.
            syncState = .failed(error.localizedDescription)
            if let error = error as? GoogleError, error == .reconnectRequired || error == .notConnected {
                needsReconnect = true; status = GoogleError.reconnectRequired.localizedDescription
                syncState = .failed(GoogleError.reconnectRequired.localizedDescription)
            }
        }
        now = Date()
    }

    /// Counts and times only: no titles, people or account, so the file can be shared when diagnosing sync.
    private func saveDiagnostics() {
        guard let diagnostics else { return }
        struct Snapshot: Encodable {
            let state: String, error: String?, lastAttempt: Date?, lastSynced: Date?
            let events: Int, meetings: Int, startable: Int, rangeDays: Int
        }
        var failure: String?
        if case .failed(let message) = syncState { failure = message }
        let snapshot = Snapshot(state: failure == nil ? "synced" : "failed", error: failure, lastAttempt: lastAttempt, lastSynced: lastSynced,
                                events: events.count, meetings: CalendarSchedule.upcoming(events, at: Date()).count,
                                startable: CalendarSchedule.startable(events, at: Date()).count, rangeDays: Int(Self.range / 86400))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(snapshot).write(to: diagnostics, options: .atomic)
    }

    /// Events around a past record's start, for linking it afterwards.
    func events(around date: Date) async throws -> [CalendarEvent] {
        CalendarSchedule.linkable(try await fetch(from: date.addingTimeInterval(-12 * 3600), to: date.addingTimeInterval(12 * 3600)),
                                  around: date)
    }

    private func fetch(from: Date, to: Date) async throws -> [CalendarEvent] {
        try await withAccessToken { try await self.client.events(accessToken: $0, from: from, to: to) }
    }

    /// Runs a Google API call; an access token revoked early is refreshed once before giving up.
    func withAccessToken<T>(_ call: @escaping (String) async throws -> T) async throws -> T {
        guard let session else { throw GoogleError.notConfigured }
        guard account != nil else { throw GoogleError.notConnected }
        do {
            return try await call(try await session.accessToken())
        } catch GoogleCalendarClient.Failure.unauthorized {
            await session.invalidateAccessToken()
            do { return try await call(try await session.accessToken()) }
            catch GoogleCalendarClient.Failure.unauthorized { throw GoogleError.reconnectRequired }
        }
    }

    /// Mail was refused although it looked granted, e.g. revoked in the Google account settings.
    func mailAccessRevoked() { setScopes(scopes.filter { $0 != GoogleScope.mail }) }

    private func setScopes(_ granted: [String]) {
        scopes = granted
        UserDefaults.standard.set(granted, forKey: Self.scopesKey)
    }

    /// Fixed calendar state for offline previews and checks, without network or Keychain access.
    func preview(account: String?, events: [CalendarEvent], now: Date = Date(), syncState: SyncState = .synced, mail: Bool = true) {
        self.account = account; self.events = events; self.now = now; self.syncState = syncState
        lastSynced = now; needsReconnect = false
        scopes = account == nil ? [] : GoogleScope.identity + [GoogleScope.calendar] + (mail ? [GoogleScope.mail] : [])
    }

    func link(for event: CalendarEvent) -> CalendarLink? {
        account.map { CalendarLink(event: event, account: $0) }
    }
    func key(for event: CalendarEvent) -> CalendarEventKey? {
        account.map { CalendarEventKey(account: $0, calendarID: event.calendarID, eventID: event.id) }
    }
}
