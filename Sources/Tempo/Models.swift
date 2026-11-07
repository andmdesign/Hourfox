import AppKit
import SwiftUI

// MARK: - Цвета проектов (системная палитра Apple)

/// Системный цвет по имени или любой свой: «#RRGGBB». В файле это обычная строка, поэтому старые данные читаются как есть.
struct ProjectColor: Codable, Hashable, Identifiable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    static let blue = ProjectColor(rawValue: "blue")
    static let indigo = ProjectColor(rawValue: "indigo")
    static let purple = ProjectColor(rawValue: "purple")
    static let pink = ProjectColor(rawValue: "pink")
    static let red = ProjectColor(rawValue: "red")
    static let orange = ProjectColor(rawValue: "orange")
    static let yellow = ProjectColor(rawValue: "yellow")
    static let green = ProjectColor(rawValue: "green")
    static let mint = ProjectColor(rawValue: "mint")
    static let teal = ProjectColor(rawValue: "teal")
    static let brown = ProjectColor(rawValue: "brown")
    static let gray = ProjectColor(rawValue: "gray")

    static let allCases: [ProjectColor] = [.blue, .indigo, .purple, .pink, .red, .orange, .yellow, .green, .mint, .teal, .brown, .gray]

    var id: String { rawValue }
    var isCustom: Bool { rawValue.hasPrefix("#") }

    static func custom(_ color: NSColor) -> ProjectColor {
        let c = color.usingColorSpace(.sRGB) ?? .systemBlue
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return ProjectColor(rawValue: String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent)))
    }

    var nsColor: NSColor {
        switch rawValue {
        case "blue": return .systemBlue
        case "indigo": return .systemIndigo
        case "purple": return .systemPurple
        case "pink": return .systemPink
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "yellow": return .systemYellow
        case "green": return .systemGreen
        case "mint": return .systemMint
        case "teal": return .systemTeal
        case "brown": return .systemBrown
        case "gray": return .systemGray
        default:
            guard isCustom, rawValue.count == 7, let v = Int(rawValue.dropFirst(), radix: 16) else { return .systemGray }
            return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// Короткий набор для автоматического выбора нового цвета.
    static let quick: [ProjectColor] = [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink]
}

// MARK: - Модель

struct Project: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var color: ProjectColor
    var emoji: String?
    /// Ставка в час: только если включены «Ставки и суммы».
    var rate: Double?
    /// Цена за весь проект. Если есть, ставка не считается.
    var fixedPrice: Double?
    /// Когда убран в архив: проекта нет в выборе, а история и отчёты остаются.
    var archivedAt: Date?

    var isArchived: Bool { archivedAt != nil }

    /// «1500», «12,5». Пустое и не число: ставки нет.
    static func parseRate(_ text: String) -> Double? {
        guard let value = Double(text.trimmed.replacingOccurrences(of: ",", with: ".")), value >= 0 else { return nil }
        return value
    }

    /// Название с эмодзи впереди — для меню и подписей. В CSV и календарь идёт чистое название.
    var label: String { emoji.map { "\($0) \(name)" } ?? name }
}

/// Эмодзи для задач и проектов: короткий рабочий набор, рисуется системным Apple Color Emoji.
enum WorkEmoji {
    static let all = [
        "✅", "❌", "⚠️", "❗", "❓", "🔥", "⭐", "📌",
        "📞", "💬", "✉️", "📅", "⏰", "📝", "📄", "📎",
        "📊", "💡", "🎯", "🚀", "🐞", "🔧", "💻", "💰",
    ]
}

struct Entry: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var projectID: UUID?
    var start: Date
    var end: Date?
    var note = ""
    /// Таймер обратного отсчёта: сколько всего секунд должна длиться запись. nil — секундомер.
    var planned: TimeInterval?
    var emoji: String?
    /// Пауза: с какого момента запись стоит и сколько всего секунд она простояла раньше.
    var pausedAt: Date?
    var pausedTotal: TimeInterval = 0

    init(title: String, projectID: UUID?, start: Date, end: Date? = nil, note: String = "", planned: TimeInterval? = nil, emoji: String? = nil) {
        self.emoji = emoji
        self.title = title
        self.projectID = projectID
        self.start = start
        self.end = end
        self.note = note
        self.planned = planned
    }

    // Старые файлы без поля note тоже читаются.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decodeIfPresent(Date.self, forKey: .end)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        planned = try c.decodeIfPresent(TimeInterval.self, forKey: .planned)
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
        pausedAt = try c.decodeIfPresent(Date.self, forKey: .pausedAt)
        pausedTotal = try c.decodeIfPresent(TimeInterval.self, forKey: .pausedTotal) ?? 0
    }

    var isPaused: Bool { end == nil && pausedAt != nil }

    /// Сколько секунд простояло на паузе к моменту now, включая идущую паузу.
    func paused(at now: Date = Date()) -> TimeInterval {
        pausedTotal + (pausedAt.map { max(0, (end ?? now).timeIntervalSince($0)) } ?? 0)
    }

    func remaining(at now: Date = Date()) -> TimeInterval? {
        planned.map { max(0, $0 - duration(at: now)) }
    }

    var isRunning: Bool { end == nil }

    /// Чистое время работы — без пауз.
    func duration(at now: Date = Date()) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start) - paused(at: now))
    }

    /// Сколько секунд записи попадает в интервал. Паузы вычитаются пропорционально —
    /// их точных отрезков мы не храним, а запись через полночь с паузой — редкость.
    func overlap(with interval: DateInterval, now: Date = Date()) -> TimeInterval {
        let s = max(start, interval.start)
        let e = min(end ?? now, interval.end)
        let span = (end ?? now).timeIntervalSince(start)
        guard span > 0 else { return 0 }
        return max(0, e.timeIntervalSince(s)) * duration(at: now) / span
    }
}

/// Простая задача из списка дел.
struct TodoTask: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var projectID: UUID?
    var done = false
    var created = Date()
    /// 0 — без приоритета, 1 — низкий (!), 2 — средний (!!), 3 — высокий (!!!).
    var priority = 0
    var emoji: String?
    /// Срок: начало дня. Показывается, только если включены «Сроки у задач».
    var due: Date?
    /// Время срока: минуты от начала дня. nil — срок на весь день.
    var dueMinutes: Int?
    /// На какой момент уже напомнили: новое время напомнит снова, перезапуск — нет.
    var dueReminded: Date?
    /// Место в списке после перетаскивания. nil: порядок задаёт приоритет.
    var rank: Double?
    /// Колонка «В работе» на канбане.
    var inProgress = false

    /// Заголовок с эмодзи впереди — для меню и подписей.
    var label: String { emoji.map { "\($0) \(title)" } ?? title }

    init(title: String, projectID: UUID?, priority: Int = 0) {
        self.title = title
        self.projectID = projectID
        self.priority = priority
    }

    // Задачи, сохранённые до появления приоритета, тоже читаются.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
        due = try c.decodeIfPresent(Date.self, forKey: .due)
        rank = try c.decodeIfPresent(Double.self, forKey: .rank)
        dueMinutes = try c.decodeIfPresent(Int.self, forKey: .dueMinutes)
        dueReminded = try c.decodeIfPresent(Date.self, forKey: .dueReminded)
        inProgress = try c.decodeIfPresent(Bool.self, forKey: .inProgress) ?? false
    }
}

/// Быстрая заметка: первая строка — заголовок.
struct Note: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String
    var created = Date()
    var updated = Date()

    init(text: String) {
        self.text = text
    }

    private var lines: [Substring] {
        text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var title: String { lines.first.map { String($0).trimmed } ?? L("Новая заметка") }
    var preview: String { lines.dropFirst().first.map { String($0).trimmed } ?? "" }
}

/// Части Notch, которые можно выключить в настройках. По умолчанию всё включено.
enum Feature: String, CaseIterable, Identifiable {
    case recent, tasks, notes, events, today, comments, countdown

    var id: String { rawValue }
    var key: String { "feature.\(rawValue)" }
    var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    /// Без ключей Google вкладки событий нет совсем.
    var isAvailable: Bool { self != .events || GoogleOAuthConfig.current != nil }

    var title: String {
        switch self {
        case .recent: "Недавние"
        case .tasks: "Задачи"
        case .notes: "Заметки"
        case .events: "События"
        case .today: "Итог за сегодня"
        case .comments: "Комментарии"
        case .countdown: "Таймер обратного отсчёта"
        }
    }

    var subtitle: String {
        switch self {
        case .recent: "Последние задачи для запуска в один клик"
        case .tasks: "Список дел с приоритетами"
        case .notes: "Быстрые заметки"
        case .events: "Встречи на сегодня из Google Календаря"
        case .today: "Полоска дня с временем по проектам"
        case .comments: "Поле для заметки к идущей записи"
        case .countdown: "Кнопка с часами рядом с проектом"
        }
    }

    var symbol: String {
        switch self {
        case .recent: "history"
        case .tasks: "list-checks"
        case .notes: "sticky-note"
        case .events: "calendar"
        case .today: "chart-column"
        case .comments: "message-square-text"
        case .countdown: "timer"
        }
    }
}

enum Priority {
    static let titles = [3: "Высокий", 2: "Средний", 1: "Низкий", 0: "Без приоритета"]

    static func nsColor(_ p: Int) -> NSColor {
        switch p {
        case 3: .systemRed
        case 2: .systemOrange
        default: .systemYellow
        }
    }

    static func color(_ p: Int) -> Color { Color(nsColor: nsColor(p)) }

    /// Цветной кружок для пунктов меню (не шаблон — иначе macOS перекрасит его в цвет текста).
    static func menuImage(_ p: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2))
            ring.lineWidth = 1.5
            if p > 0 {
                nsColor(p).withAlphaComponent(0.18).setFill()
                ring.fill()
                nsColor(p).setStroke()
            } else {
                NSColor.secondaryLabelColor.setStroke()
            }
            ring.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct DayGroup: Identifiable {
    let day: Date
    var entries: [Entry]
    var id: Date { day }
}

struct TaskTotal: Identifiable {
    var title: String
    var seconds: TimeInterval
    var id: String { title }
}

struct ProjectTotal: Identifiable {
    var projectID: UUID?
    var seconds: TimeInterval
    var tasks: [TaskTotal]
    var id: String { projectID?.uuidString ?? "none" }
}

/// Последняя запись по паре «задача + проект».
struct Recent: Identifiable {
    var entryID: UUID
    var title: String
    var projectID: UUID?
    var note: String
    var emoji: String?
    var id: String { (projectID?.uuidString ?? "none") + "|" + title }
}

/// Постоянная задача: всегда сверху в «Недавних» и запускается одним кликом.
struct PinnedTask: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var projectID: UUID?
    var emoji: String?

    var key: String { (projectID?.uuidString ?? "none") + "|" + title }
}

/// Удалённое лежит в архиве, пока его не удалят оттуда.
struct ArchiveItem<T: Codable & Identifiable>: Codable, Identifiable where T.ID == UUID {
    var item: T
    var deletedAt = Date()
    var id: UUID { item.id }
}

struct DeletedProject: Codable, Identifiable {
    var project: Project
    var deletedAt = Date()
    /// Что было в проекте: вернётся вместе с ним.
    var entryIDs: Set<UUID>
    var taskIDs: Set<UUID>
    var pinIDs: Set<UUID>
    var id: UUID { project.id }
}

struct ArchiveBox: Codable {
    var entries: [ArchiveItem<Entry>] = []
    var tasks: [ArchiveItem<TodoTask>] = []
    var notes: [ArchiveItem<Note>] = []
    var projects: [DeletedProject] = []
    var expenses: [ArchiveItem<Expense>] = []

    init() {}

    // Файл старой версии, где расходов ещё нет, тоже читается.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([ArchiveItem<Entry>].self, forKey: .entries) ?? []
        tasks = try c.decodeIfPresent([ArchiveItem<TodoTask>].self, forKey: .tasks) ?? []
        notes = try c.decodeIfPresent([ArchiveItem<Note>].self, forKey: .notes) ?? []
        projects = try c.decodeIfPresent([DeletedProject].self, forKey: .projects) ?? []
        expenses = try c.decodeIfPresent([ArchiveItem<Expense>].self, forKey: .expenses) ?? []
    }
}

/// Расход по проекту: такси, подписка, подрядчик.
struct Expense: Identifiable, Codable, Hashable {
    var id = UUID()
    var projectID: UUID
    var title: String
    var amount: Double
    var date: Date
}

struct DayPoint: Identifiable {
    var day: Date
    var key: String
    var hours: Double
    var id: String { "\(day.timeIntervalSince1970)|\(key)" }
}

// MARK: - Календарь и форматирование

enum Cal {
    static let ru: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "ru_RU")
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }()

    static func day(_ d: Date) -> DateInterval {
        ru.dateInterval(of: .day, for: d)!
    }
}

enum Fmt {
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    /// Для «крыла» Notch: 4:05 до часа, 1:04:05 после.
    static func compact(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return clock(t)
    }

    static func short(_ t: TimeInterval) -> String {
        let m = max(0, Int(t)) / 60
        let h = m / 60, mm = m % 60
        let min = L("мин"), hr = L("ч")
        if h == 0 { return "\(mm)\u{00A0}\(min)" }
        return mm == 0 ? "\(h)\u{00A0}\(hr)" : "\(h)\u{00A0}\(hr) \(mm)\u{00A0}\(min)"
    }

    /// «25 мин», «1 ч», «1 ч 30 мин» — для кнопки таймера.
    static func minutes(_ m: Int) -> String {
        short(TimeInterval(m * 60))
    }

    static func hours(_ t: TimeInterval) -> String {
        (t / 3600).formatted(.number.precision(.fractionLength(2)).grouping(.never).locale(AppLanguage.shared.locale))
    }

    /// Форматтеры под текущий язык интерфейса (кэшируются по языку).
    private static var cache: [String: DateFormatter] = [:]

    private static func formatter(format: String? = nil, template: String? = nil) -> DateFormatter {
        let language = AppLanguage.shared
        let key = "\(language.code)|\(format ?? "")|\(template ?? "")"
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.locale = language.locale
        if let format { f.dateFormat = format } else if let template { f.setLocalizedDateFormatFromTemplate(template) }
        cache[key] = f
        return f
    }

    static var hhmm: DateFormatter { formatter(format: "HH:mm") }
    static var date: DateFormatter { formatter(format: "dd.MM.yyyy") }
    static var dayLong: DateFormatter { formatter(template: "EEEEdMMMM") }
    static var dayLongYear: DateFormatter { formatter(template: "EEEEdMMMMy") }
    static var dayMonth: DateFormatter { formatter(template: "dMMMM") }
    static var dayShort: DateFormatter { formatter(template: "dMMM") }
    static var monthYear: DateFormatter { formatter(template: "LLLLy") }
    static var monthShort: DateFormatter { formatter(template: "LLL") }

    /// «2 ноября 2026 г. в 21:39» — дата над заметкой, как в Apple Notes.
    static func noteFull(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = AppLanguage.shared.locale
        f.dateStyle = .long
        f.timeStyle = .short
        f.doesRelativeDateFormatting = false
        return f.string(from: d)
    }

    /// Время для сегодняшних заметок, дата для остальных.
    static func noteDate(_ d: Date) -> String {
        Cal.ru.isDateInToday(d) ? hhmm.string(from: d) : dayShort.string(from: d)
    }

    static func dayTitle(_ d: Date) -> String {
        if Cal.ru.isDateInToday(d) { return L("Сегодня") }
        if Cal.ru.isDateInYesterday(d) { return L("Вчера") }
        let sameYear = Cal.ru.isDate(d, equalTo: Date(), toGranularity: .year)
        return (sameYear ? dayLong : dayLongYear).string(from: d).capitalizedFirst
    }

    static func range(_ e: Entry) -> String {
        "\(hhmm.string(from: e.start))–\(e.end.map { hhmm.string(from: $0) } ?? L("сейчас"))"
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
