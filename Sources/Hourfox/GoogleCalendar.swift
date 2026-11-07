import AppKit
import Combine
import CryptoKit
import Network
import Security
import SwiftUI

// MARK: - Модель

/// Событие Google Календаря на сегодня. Hourfox их только показывает и ничего не меняет.
struct GoogleEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let colorHex: String?
    let meetingURL: URL?
    let link: URL?

    func isCurrent(at now: Date) -> Bool { start <= now && now < end }
    var color: Color { Color(hex: colorHex) ?? .accentColor }
}

struct GoogleCalendarInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let colorHex: String?
    let isPrimary: Bool
    let isSelectedInGoogle: Bool
}

extension Color {
    init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let v = Int(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
}

// MARK: - Ключи клиента

/// Ключи OAuth-клиента лежат в GoogleOAuth.plist и в репозиторий не попадают.
/// Без них Google Календаря в приложении просто нет: ни вкладки, ни настройки.
struct GoogleOAuthConfig {
    let clientID: String
    let clientSecret: String

    static let current: GoogleOAuthConfig? = {
        let env = ProcessInfo.processInfo.environment
        if env["HOURFOX_GCAL_FAKE"] != nil { return GoogleOAuthConfig(clientID: "fake", clientSecret: "fake") }
        let url = env["HOURFOX_GOOGLE_CONFIG"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.url(forResource: "GoogleOAuth", withExtension: "plist")
        guard let url, let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let id = dict["ClientID"], let secret = dict["ClientSecret"],
              !id.isEmpty, !secret.isEmpty, !id.hasPrefix("PASTE_") else { return nil }
        return GoogleOAuthConfig(clientID: id, clientSecret: secret)
    }()
}

// MARK: - Разбор ответов Google

enum GoogleAPI {
    private struct EventsPage: Decodable {
        struct Item: Decodable {
            struct When: Decodable { let date: String?; let dateTime: String? }
            struct Attendee: Decodable { let `self`: Bool?; let responseStatus: String? }
            struct Conference: Decodable {
                struct EntryPoint: Decodable { let entryPointType: String?; let uri: String? }
                let entryPoints: [EntryPoint]?
            }
            let id: String
            let status: String?
            let summary: String?
            let start: When?
            let end: When?
            let attendees: [Attendee]?
            let hangoutLink: String?
            let htmlLink: String?
            let conferenceData: Conference?
            let eventType: String?
        }
        let items: [Item]?
        let nextPageToken: String?
    }

    private struct CalendarPage: Decodable {
        struct Item: Decodable {
            let id: String
            let summary: String?
            let summaryOverride: String?
            let backgroundColor: String?
            let primary: Bool?
            let selected: Bool?
            let deleted: Bool?
        }
        let items: [Item]?
        let nextPageToken: String?
    }

    private static func date(_ when: EventsPage.Item.When?) -> (Date, Bool)? {
        if let s = when?.dateTime {
            let f = ISO8601DateFormatter()
            if let d = f.date(from: s) { return (d, false) }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s).map { ($0, false) }
        }
        if let s = when?.date {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd"
            return f.date(from: s).map { ($0, true) }
        }
        return nil
    }

    /// Отменённые и отклонённые события не показываем.
    static func events(from data: Data, colorHex: String?, untitled: String) throws -> (events: [GoogleEvent], next: String?) {
        let page = try JSONDecoder().decode(EventsPage.self, from: data)
        let events = (page.items ?? []).compactMap { item -> GoogleEvent? in
            guard item.status != "cancelled",
                  item.attendees?.first(where: { $0.`self` == true })?.responseStatus != "declined",
                  let (start, allDay) = date(item.start), let (end, _) = date(item.end) else { return nil }
            let video = item.conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri
            return GoogleEvent(id: item.id,
                               title: item.summary?.isEmpty == false ? item.summary! : untitled,
                               start: start, end: end, isAllDay: allDay, colorHex: colorHex,
                               meetingURL: (item.hangoutLink ?? video).flatMap(URL.init(string:)),
                               link: item.htmlLink.flatMap(URL.init(string:)))
        }
        return (events, page.nextPageToken)
    }

    static func calendars(from data: Data) throws -> (calendars: [GoogleCalendarInfo], next: String?) {
        let page = try JSONDecoder().decode(CalendarPage.self, from: data)
        let list = (page.items ?? []).filter { $0.deleted != true }.map {
            GoogleCalendarInfo(id: $0.id, name: $0.summaryOverride ?? $0.summary ?? $0.id, colorHex: $0.backgroundColor,
                               isPrimary: $0.primary == true, isSelectedInGoogle: $0.selected == true)
        }
        return (list, page.nextPageToken)
    }

    /// События на экране: сперва весь день, затем по времени.
    static func sorted(_ events: [GoogleEvent]) -> [GoogleEvent] {
        events.sorted { a, b in
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            if a.start != b.start { return a.start < b.start }
            return a.title < b.title
        }
    }
}

// MARK: - Приём ответа из браузера

/// Маленький сервер на 127.0.0.1: сюда Google возвращает браузер после входа.
final class OAuthLoopbackServer {
    enum Failure: Error { case denied, cancelled, listener }

    private var listener: NWListener?
    private let state: String
    private var finish: ((Result<String, Error>) -> Void)?

    init(state: String) { self.state = state }

    func start(ready: @escaping (UInt16) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        finish = completion
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: params)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready: if let port = listener?.port?.rawValue { ready(port) }
                case .failed: self?.complete(.failure(Failure.listener))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            listener.start(queue: .main)
        } catch {
            complete(.failure(Failure.listener))
        }
    }

    func cancel() { complete(.failure(Failure.cancelled)) }

    private func complete(_ result: Result<String, Error>) {
        listener?.cancel()
        listener = nil
        let f = finish
        finish = nil
        f?(result)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            self.handle(String(decoding: data ?? Data(), as: UTF8.self), on: connection)
        }
    }

    private func handle(_ request: String, on connection: NWConnection) {
        let parts = request.split(separator: "\r\n", maxSplits: 1).first?.split(separator: " ") ?? []
        let target = parts.count > 1 ? String(parts[1]) : ""
        let items = URLComponents(string: target)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        // Запрос без нашего state — не от Google (или это /favicon.ico): просто игнорируем.
        guard target.hasPrefix("/?"), value("state") == state else {
            reply(connection, status: "404 Not Found", text: "")
            return
        }
        if let code = value("code") {
            reply(connection, status: "200 OK", text: L("Hourfox подключён. Можно вернуться в приложение."))
            complete(.success(code))
        } else {
            reply(connection, status: "200 OK", text: L("Не удалось подключиться. Вернитесь в Hourfox и попробуйте ещё раз."))
            complete(.failure(Failure.denied))
        }
    }

    private func reply(_ connection: NWConnection, status: String, text: String) {
        let html = "<!doctype html><meta charset=utf-8><title>Hourfox</title><body style=\"font:15px -apple-system;text-align:center;padding-top:80px\">\(text)"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: - Хранение ключа доступа

/// Токен Google живёт в Связке ключей, а не в data.json.
/// В тестах (HOURFOX_DATA_DIR) Связку не трогаем: держим токен только в памяти.
enum GoogleTokenStore {
    private static let service = "com.andmdesign.hourfox.google"
    private static let account = "refresh-token"
    private static var isTest: Bool { ProcessInfo.processInfo.environment["HOURFOX_DATA_DIR"] != nil }
    private static var memory: String?

    private static var query: [String: Any] { query(service: service) }

    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Вход, сделанный ещё в Tempo: читаем и сразу сохраняем под новым именем.
    private static func loadLegacy() -> String? {
        var q = query(service: "local.andrejm.tempo.google")
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let token = String(data: data, encoding: .utf8) else { return nil }
        save(token)
        return token
    }

    static func load() -> String? {
        if isTest { return memory }
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return loadLegacy() }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        if isTest { memory = token; return }
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess { NSLog("Hourfox: не удалось сохранить ключ Google: \(status)") }
    }

    static func delete() {
        if isTest { memory = nil; return }
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Подключение и загрузка событий

@MainActor
final class GoogleCalendar: ObservableObject {
    static let shared = GoogleCalendar()
    static var isConfigured: Bool { GoogleOAuthConfig.current != nil }

    enum Status: Equatable { case disconnected, connecting, connected }
    enum Failure: Error { case tokenRevoked, http(Int), badResponse }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var events: [GoogleEvent] = []
    @Published private(set) var calendars: [GoogleCalendarInfo] = []
    @Published private(set) var account: String?
    @Published private(set) var isOffline = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hiddenIDs: Set<String>

    private let scope = "https://www.googleapis.com/auth/calendar.readonly"
    private let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private let apiBase = "https://www.googleapis.com/calendar/v3"
    private let hiddenKey = "googleCalendar.hidden"
    private let knownKey = "googleCalendar.known"

    private var server: OAuthLoopbackServer?
    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var lastRefresh = Date.distantPast
    private var isRefreshing = false
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var started = false

    private init() {
        hiddenIDs = Set(UserDefaults.standard.stringArray(forKey: "googleCalendar.hidden") ?? [])
    }

    func start() {
        guard Self.isConfigured, !started else { return }
        started = true
        if ProcessInfo.processInfo.environment["HOURFOX_GCAL_FAKE"] != nil { return }
        scheduleUpdates()
        if GoogleTokenStore.load() != nil {
            status = .connected
            Task { await refresh() }
        }
    }

    /// Подставные данные для снимков: без сети и без Google.
    func useFakeData(_ events: [GoogleEvent], calendars: [GoogleCalendarInfo] = []) {
        status = .connected
        account = "demo@example.com"
        self.events = GoogleAPI.sorted(events)
        self.calendars = calendars
    }

    func useFakeDisconnected() {
        status = .disconnected
        events = []
    }

    // MARK: Вход

    func connect() {
        guard let config = GoogleOAuthConfig.current, status != .connecting else { return }
        status = .connecting
        errorMessage = nil
        let verifier = Self.randomURLSafe(bytes: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomURLSafe(bytes: 24)
        let server = OAuthLoopbackServer(state: state)
        self.server = server
        var redirect = ""

        server.start(ready: { port in
            redirect = "http://127.0.0.1:\(port)"
            var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            c.queryItems = [
                .init(name: "client_id", value: config.clientID),
                .init(name: "redirect_uri", value: redirect),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: self.scope),
                .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "state", value: state),
                .init(name: "access_type", value: "offline"),
                .init(name: "prompt", value: "consent"),
            ]
            NSWorkspace.shared.open(c.url!)
        }, completion: { [weak self] result in
            guard let self else { return }
            self.server = nil
            switch result {
            case .success(let code):
                Task { await self.finishConnecting(code: code, verifier: verifier, redirect: redirect, config: config) }
            case .failure(let error):
                self.status = .disconnected
                if case OAuthLoopbackServer.Failure.cancelled = error { return }
                self.errorMessage = L("Не удалось подключить Google Календарь. Попробуйте ещё раз.")
            }
        })
    }

    func cancelConnecting() { server?.cancel() }

    private func finishConnecting(code: String, verifier: String, redirect: String, config: GoogleOAuthConfig) async {
        do {
            let reply = try await postToken([
                "client_id": config.clientID,
                "client_secret": config.clientSecret,
                "code": code,
                "code_verifier": verifier,
                "grant_type": "authorization_code",
                "redirect_uri": redirect,
            ])
            guard let refresh = reply.refreshToken else { throw Failure.badResponse }
            GoogleTokenStore.save(refresh)
            accept(reply)
            status = .connected
            await self.refresh()
        } catch {
            NSLog("Hourfox: вход в Google не завершён: \(String(describing: error))")
            status = .disconnected
            errorMessage = L("Не удалось подключить Google Календарь. Попробуйте ещё раз.")
        }
    }

    func disconnect() {
        // Отзываем доступ и на стороне Google; если нет сети, ключ всё равно удаляется с этого Mac.
        if let token = GoogleTokenStore.load() {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(["token": token])
            URLSession.shared.dataTask(with: request).resume()
        }
        clearSession()
        errorMessage = nil
    }

    private func clearSession() {
        GoogleTokenStore.delete()
        accessToken = nil
        accessExpiry = .distantPast
        status = .disconnected
        events = []
        calendars = []
        account = nil
        isOffline = false
    }

    // MARK: Календари

    func isVisible(_ calendar: GoogleCalendarInfo) -> Bool { !hiddenIDs.contains(calendar.id) }

    func setVisible(_ visible: Bool, _ calendar: GoogleCalendarInfo) {
        if visible { hiddenIDs.remove(calendar.id) } else { hiddenIDs.insert(calendar.id) }
        UserDefaults.standard.set(Array(hiddenIDs), forKey: hiddenKey)
        Task { await refresh() }
    }

    /// Новый календарь по умолчанию показываем так же, как в самом Google Календаре.
    private func applyDefaults(to list: [GoogleCalendarInfo]) {
        let defaults = UserDefaults.standard
        var known = Set(defaults.stringArray(forKey: knownKey) ?? [])
        for c in list where !known.contains(c.id) {
            known.insert(c.id)
            if !c.isSelectedInGoogle && !c.isPrimary { hiddenIDs.insert(c.id) }
        }
        defaults.set(Array(known), forKey: knownKey)
        defaults.set(Array(hiddenIDs), forKey: hiddenKey)
    }

    // MARK: Загрузка

    private func scheduleUpdates() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInBackground() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInBackground() }
        }
    }

    private func refreshInBackground() {
        guard status == .connected else { return }
        Task { await refresh() }
    }

    /// Открыли вкладку: обновляем, только если данные старше минуты.
    func refreshIfStale() {
        guard Date().timeIntervalSince(lastRefresh) > 60 else { return }
        refreshInBackground()
    }

    func refresh() async {
        guard status == .connected, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let list = try await loadCalendars()
            applyDefaults(to: list)
            calendars = list
            account = list.first { $0.isPrimary }?.id
            let day = Calendar.current.dateInterval(of: .day, for: Date())!
            var loaded: [GoogleEvent] = []
            for calendar in list where isVisible(calendar) {
                do {
                    loaded += try await loadEvents(of: calendar, in: day)
                } catch Failure.http(let code) where code == 403 || code == 404 {
                    // Календарь недоступен: остальные всё равно показываем.
                    NSLog("Hourfox: календарь Google пропущен, код \(code)")
                }
            }
            events = GoogleAPI.sorted(loaded)
            isOffline = false
            lastRefresh = Date()
        } catch Failure.tokenRevoked {
            clearSession()
            errorMessage = L("Доступ к Google Календарю отозван. Подключите его снова.")
        } catch {
            // Нет связи: оставляем то, что уже загружено.
            NSLog("Hourfox: события Google не загружены: \(String(describing: error))")
            isOffline = true
        }
    }

    private func loadCalendars() async throws -> [GoogleCalendarInfo] {
        var result: [GoogleCalendarInfo] = []
        var pageToken: String?
        repeat {
            var c = URLComponents(string: "\(apiBase)/users/me/calendarList")!
            c.queryItems = [.init(name: "maxResults", value: "250")] + (pageToken.map { [.init(name: "pageToken", value: $0)] } ?? [])
            let page = try GoogleAPI.calendars(from: try await get(c.url!))
            result += page.calendars
            pageToken = page.next
        } while pageToken != nil
        return result
    }

    private func loadEvents(of calendar: GoogleCalendarInfo, in day: DateInterval) async throws -> [GoogleEvent] {
        let id = calendar.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? calendar.id
        let f = ISO8601DateFormatter()
        var result: [GoogleEvent] = []
        var pageToken: String?
        repeat {
            var c = URLComponents(string: "\(apiBase)/calendars/\(id)/events")!
            c.queryItems = [
                .init(name: "timeMin", value: f.string(from: day.start)),
                .init(name: "timeMax", value: f.string(from: day.end)),
                .init(name: "singleEvents", value: "true"),
                .init(name: "orderBy", value: "startTime"),
                .init(name: "maxResults", value: "100"),
            ] + (pageToken.map { [.init(name: "pageToken", value: $0)] } ?? [])
            let page = try GoogleAPI.events(from: try await get(c.url!), colorHex: calendar.colorHex, untitled: L("Без названия"))
            result += page.events
            pageToken = page.next
        } while pageToken != nil
        return result
    }

    private func get(_ url: URL, retrying: Bool = true) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 && retrying {
            accessToken = nil
            return try await get(url, retrying: false)
        }
        guard (200..<300).contains(code) else { throw Failure.http(code) }
        return data
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, accessExpiry > Date().addingTimeInterval(60) { return accessToken }
        guard let config = GoogleOAuthConfig.current, let refresh = GoogleTokenStore.load() else { throw Failure.tokenRevoked }
        let reply = try await postToken([
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ])
        accept(reply)
        guard let token = accessToken else { throw Failure.badResponse }
        return token
    }

    private struct TokenReply: Decodable {
        let accessToken: String
        let expiresIn: Double
        let refreshToken: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

    private func accept(_ reply: TokenReply) {
        accessToken = reply.accessToken
        accessExpiry = Date().addingTimeInterval(reply.expiresIn)
    }

    private func postToken(_ fields: [String: String]) async throws -> TokenReply {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 400 || code == 401,
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           body["error"] as? String == "invalid_grant" {
            throw Failure.tokenRevoked
        }
        guard (200..<300).contains(code) else { throw Failure.http(code) }
        return try JSONDecoder().decode(TokenReply.self, from: data)
    }

    // MARK: Вспомогательное

    private static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
        let body = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
        return Data(body.joined(separator: "&").utf8)
    }

    private static func randomURLSafe(bytes: Int) -> String {
        var data = Data(count: bytes)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        precondition(status == errSecSuccess)
        return data.base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Вкладка в Notch

struct EventsSection: View {
    let controller: NotchController
    @EnvironmentObject var store: Store
    @ObservedObject private var google = GoogleCalendar.shared

    var body: some View {
        Group {
            if google.status == .connected {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    list(now: ctx.date)
                }
            } else {
                connectRow
            }
        }
        .onAppear { google.refreshIfStale() }
    }

    @ViewBuilder private func list(now: Date) -> some View {
        let left = google.events.filter { $0.end > now }
        VStack(alignment: .leading, spacing: 1) {
            if left.isEmpty {
                hint(google.isOffline ? "Нет связи с Google Календарём" : "На сегодня событий больше нет")
            }
            ForEach(left.prefix(4)) { event in
                EventRow(event: event, now: now) { begin(event, now: now) }
                    .contextMenu {
                        Button("Начать") { begin(event, now: now) }
                        if let url = event.meetingURL {
                            Button("Присоединиться") { NSWorkspace.shared.open(url) }
                        }
                        if let url = event.link {
                            Button("Открыть в Google Календаре") { NSWorkspace.shared.open(url) }
                        }
                    }
            }
        }
    }

    private func hint(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 12))
            .foregroundStyle(.notchInk.opacity(0.35))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }

    @ViewBuilder private var connectRow: some View {
        Button {
            if google.status == .connecting { google.cancelConnecting() } else { google.connect() }
        } label: {
            HStack(spacing: 9) {
                Image(icon: "calendar", size: 12)
                    .foregroundStyle(.notchInk.opacity(0.5))
                    .frame(width: 14)
                if google.status == .connecting {
                    Text("Ожидаем вход в браузере…").foregroundStyle(.notchInk.opacity(0.5))
                } else {
                    Text("Подключить Google Календарь").foregroundStyle(.notchInk.opacity(0.85))
                }
                Spacer(minLength: 8)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Запись с названием события; таймер — до его конца, если событие уже идёт или впереди.
    private func begin(_ event: GoogleEvent, now: Date) {
        let planned: TimeInterval? = event.isAllDay ? nil : event.end.timeIntervalSince(max(now, event.start))
        store.start(title: event.title, projectID: store.currentProjectID, planned: .some(planned))
        controller.didStart()
    }
}

struct EventRow: View {
    let event: GoogleEvent
    let now: Date
    let start: () -> Void
    @State private var hover = false

    private var timeText: String {
        event.isAllDay ? L("Весь день") : event.start.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        let current = !event.isAllDay && event.isCurrent(at: now)
        HStack(spacing: 9) {
            Circle()
                .fill(event.color)
                .frame(width: 7, height: 7)
                .frame(width: 14)
            Button(action: start) {
                HStack(spacing: 9) {
                    Text(timeText)
                        .monospacedDigit()
                        .foregroundStyle(.notchInk.opacity(current ? 0.85 : 0.4))
                        .lineLimit(1)
                    Text(event.title)
                        .fontWeight(current ? .semibold : .regular)
                        .foregroundStyle(.notchInk.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(icon: "play", size: 9)
                        .foregroundStyle(.notchInk.opacity(hover ? 0.9 : 0.3))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let url = event.meetingURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(icon: "video", size: 10)
                        .foregroundStyle(.notchInk.opacity(hover ? 0.9 : 0.4))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Присоединиться")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.notchInk.opacity(hover ? 0.07 : 0)))
        .onHover { hover = $0 }
    }
}

// MARK: - Настройки

struct GoogleCalendarSettings: View {
    @ObservedObject private var google = GoogleCalendar.shared

    var body: some View {
        Section {
            switch google.status {
            case .connected:
                LabeledContent {
                    Button("Отключить") { google.disconnect() }
                } label: {
                    settingLabel("Подключён", google.account ?? "", "calendar")
                }
                ForEach(google.calendars) { calendar in
                    Toggle(isOn: Binding(get: { google.isVisible(calendar) }, set: { google.setVisible($0, calendar) })) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(hex: calendar.colorHex) ?? .accentColor)
                                .frame(width: 8, height: 8)
                            Text(verbatim: calendar.name)
                        }
                    }
                }
            case .connecting:
                LabeledContent {
                    Button("Отмена") { google.cancelConnecting() }
                } label: {
                    settingLabel("Ожидаем вход в браузере…", "", "calendar")
                }
            case .disconnected:
                LabeledContent {
                    Button("Подключить") { google.connect() }
                } label: {
                    settingLabel("Google Календарь", "События на сегодня во вкладке Notch", "calendar")
                }
            }
        } header: {
            Text("Google Календарь")
        } footer: {
            if let error = google.errorMessage {
                Text(error).foregroundStyle(.red)
            } else {
                Text("Только чтение: Hourfox показывает события и ничего не меняет в календаре.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
