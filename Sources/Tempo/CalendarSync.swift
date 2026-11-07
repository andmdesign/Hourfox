import AppKit
import Combine
import EventKit

/// Завершённые записи → события в отдельном календаре «Tempo» приложения «Календарь».
/// Tempo — источник правды: при каждой синхронизации календарь приводится к журналу
/// (новые события создаются, изменённые обновляются, лишние удаляются).
final class CalendarSync {
    static let shared = CalendarSync()

    private let ek = EKEventStore()
    private let defaults = UserDefaults.standard
    private var store: Store?
    private var lastSignature: Int?
    private var cancellables = Set<AnyCancellable>()

    private let enabledKey = "calendarSync.enabled"
    private let calendarKey = "calendarSync.calendarID"
    private let fromKey = "calendarSync.from"
    private let calendarTitle = "Tempo"

    var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var isEnabled: Bool { defaults.bool(forKey: enabledKey) && isAuthorized }

    func start(store: Store) {
        self.store = store
        store.objectWillChange
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self] in self?.sync() }
            .store(in: &cancellables)
        sync()
    }

    /// completion сообщает, включилась ли синхронизация на самом деле (доступ могут не дать).
    func setEnabled(_ on: Bool, completion: ((Bool) -> Void)? = nil) {
        guard on else {
            defaults.set(false, forKey: enabledKey)
            completion?(false)
            return
        }
        ek.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted {
                    self.defaults.set(true, forKey: self.enabledKey)
                    self.ek.reset()
                    self.lastSignature = nil
                    self.sync()
                } else {
                    self.showAccessAlert()
                }
                completion?(granted)
            }
        }
    }

    func openCalendarApp() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Calendar.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Синхронизация

    func sync() {
        guard isEnabled, let store else { return }
        let finished = store.entries.filter { $0.end != nil }

        // Ничего не поменялось с прошлого раза — EventKit не трогаем.
        var hasher = Hasher()
        for e in finished {
            hasher.combine(e.id)
            hasher.combine(title(for: e, in: store))
            hasher.combine(e.note)
            hasher.combine(Int(e.start.timeIntervalSince1970))
            hasher.combine(Int(e.end!.timeIntervalSince1970))
        }
        let signature = hasher.finalize()
        guard signature != lastSignature, let calendar = tempoCalendar() else { return }

        // Диапазон поиска: от самой старой записи (в том числе уже удалённой) до завтра.
        let now = Date()
        var from = finished.map(\.start).min() ?? now.addingTimeInterval(-30 * 86400)
        if let saved = defaults.object(forKey: fromKey) as? Date { from = min(from, saved) }
        from = from.addingTimeInterval(-86400)
        defaults.set(from, forKey: fromKey)
        let to = now.addingTimeInterval(86400)

        // EventKit ищет не больше чем за 4 года за раз — идём кусками по году.
        var existing: [String: EKEvent] = [:]
        var extra: [EKEvent] = []
        var foreign: [EKEvent] = []
        var seen = Set<String>()
        var chunk = from
        while chunk < to {
            let end = min(chunk.addingTimeInterval(365 * 86400), to)
            for ev in ek.events(matching: ek.predicateForEvents(withStart: chunk, end: end, calendars: [calendar])) {
                guard seen.insert(ev.eventIdentifier ?? UUID().uuidString).inserted else { continue }
                // Событие без нашей метки — не наше: календарь могли назвать «Tempo» и без нас.
                guard ev.url?.scheme == "tempo", let id = ev.url?.lastPathComponent else {
                    foreign.append(ev)
                    continue
                }
                if existing[id] == nil {
                    existing[id] = ev
                } else {
                    extra.append(ev)
                }
            }
            chunk = end
        }

        var changed = false
        for e in finished {
            let t = title(for: e, in: store)
            // Некоторые серверы не хранят url. Такое же событие подхватываем, а не создаём второй раз.
            let twin = foreign.first {
                $0.title == t
                    && $0.startDate.map { abs($0.timeIntervalSince(e.start)) < 1 } == true
                    && $0.endDate.map { abs($0.timeIntervalSince(e.end!)) < 1 } == true
            }
            let ev = existing.removeValue(forKey: e.id.uuidString) ?? twin ?? {
                let ev = EKEvent(eventStore: ek)
                ev.calendar = calendar
                ev.url = URL(string: "tempo://entry/\(e.id.uuidString)")
                return ev
            }()
            let notes: String? = e.note.isEmpty ? nil : e.note
            let same = ev.title == t
                && (ev.notes ?? "") == e.note
                && ev.startDate.map { abs($0.timeIntervalSince(e.start)) < 1 } == true
                && ev.endDate.map { abs($0.timeIntervalSince(e.end!)) < 1 } == true
            guard !same else { continue }
            ev.title = t
            ev.notes = notes
            ev.startDate = e.start
            ev.endDate = e.end!
            ev.availability = .free
            do {
                try ek.save(ev, span: .thisEvent, commit: false)
                changed = true
            } catch {
                NSLog("Tempo: не удалось сохранить событие: \(error.localizedDescription)")
            }
        }
        // Записей больше нет — убираем их события.
        for ev in Array(existing.values) + extra {
            try? ek.remove(ev, span: .thisEvent, commit: false)
            changed = true
        }
        if changed {
            do { try ek.commit() } catch { NSLog("Tempo: календарь не сохранён: \(error.localizedDescription)") }
        }
        lastSignature = signature
    }

    private func title(for e: Entry, in store: Store) -> String {
        let project = store.project(e.projectID)?.name
        switch (project, e.title.isEmpty) {
        case let (p?, false): return "\(p) · \(e.title)"
        case let (p?, true): return p
        case (nil, false): return e.title
        case (nil, true): return calendarTitle
        }
    }

    /// Свой календарь «Tempo»: по возможности в «На моём Mac», иначе там же, где календарь по умолчанию.
    private func tempoCalendar() -> EKCalendar? {
        if let id = defaults.string(forKey: calendarKey), let c = ek.calendar(withIdentifier: id) { return c }
        if let c = ek.calendars(for: .event).first(where: { $0.title == calendarTitle && $0.allowsContentModifications }) {
            defaults.set(c.calendarIdentifier, forKey: calendarKey)
            return c
        }
        let sources = [ek.sources.first { $0.sourceType == .local }, ek.defaultCalendarForNewEvents?.source].compactMap { $0 }
        for source in sources {
            let c = EKCalendar(for: .event, eventStore: ek)
            c.title = calendarTitle
            c.color = .systemBlue
            c.source = source
            if (try? ek.saveCalendar(c, commit: true)) != nil {
                defaults.set(c.calendarIdentifier, forKey: calendarKey)
                return c
            }
        }
        NSLog("Tempo: не удалось создать календарь")
        return nil
    }

    private func showAccessAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Нет доступа к Календарю")
        alert.informativeText = L("Разрешите Tempo доступ: Системные настройки → Конфиденциальность и безопасность → Календари.")
        alert.addButton(withTitle: L("Открыть настройки"))
        alert.addButton(withTitle: L("Отмена"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}
