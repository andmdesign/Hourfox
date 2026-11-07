import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Настройки экспорта

enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case pdf, csv
    var id: String { rawValue }
    var title: String { self == .pdf ? "PDF" : "CSV" }
}

enum ExportPreset: String, Codable, CaseIterable, Identifiable {
    case today, week, month, lastMonth, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Сегодня"
        case .week: "Эта неделя"
        case .month: "Этот месяц"
        case .lastMonth: "Прошлый месяц"
        case .custom: "Выбрать даты"
        }
    }
}

enum ExportGrouping: String, Codable, CaseIterable, Identifiable {
    case entry, day, task, project
    var id: String { rawValue }

    var title: String {
        switch self {
        case .entry: "Каждая запись"
        case .day: "По дням"
        case .task: "По задачам"
        case .project: "По проектам"
        }
    }
}

enum ExportColumn: String, Codable, CaseIterable, Identifiable {
    case date, time, task, project, duration, amount, comment
    var id: String { rawValue }

    var title: String {
        switch self {
        case .date: "Дата"
        case .time: "Начало и конец"
        case .task: "Задача"
        case .project: "Проект"
        case .duration: "Время"
        case .amount: "Сумма"
        case .comment: "Комментарий"
        }
    }
}

enum ExportTimeStyle: String, Codable, CaseIterable, Identifiable {
    case text, decimal
    var id: String { rawValue }
}

struct ExportOptions: Codable, Equatable {
    var format = ExportFormat.pdf
    var preset = ExportPreset.month
    var customStart = Date()
    var customEnd = Date()
    /// Пусто: все проекты.
    var projectIDs: Set<UUID> = []
    var includeNoProject = true
    var grouping = ExportGrouping.day
    var columns: Set<ExportColumn> = [.date, .task, .project, .duration, .amount]
    var roundMinutes = 0
    var timeStyle = ExportTimeStyle.text
    var title = ""
    var client = ""
    var showLogo = true
    /// Расходы отдельными строками. nil в старых настройках значит «да».
    var includeExpenses: Bool?

    func interval(now: Date = Date()) -> DateInterval {
        let cal = Cal.ru
        switch preset {
        case .today: return cal.dateInterval(of: .day, for: now)!
        case .week: return cal.dateInterval(of: .weekOfYear, for: now)!
        case .month: return cal.dateInterval(of: .month, for: now)!
        case .lastMonth:
            let previous = cal.date(byAdding: .month, value: -1, to: now) ?? now
            return cal.dateInterval(of: .month, for: previous)!
        case .custom:
            let start = cal.startOfDay(for: min(customStart, customEnd))
            let last = cal.startOfDay(for: max(customStart, customEnd))
            return DateInterval(start: start, end: cal.date(byAdding: .day, value: 1, to: last) ?? last)
        }
    }

    /// Что реально попадёт в файл: группировка задаёт обязательные колонки и убирает лишние.
    func effectiveColumns(ratesOn: Bool) -> [ExportColumn] {
        var set = columns.union([.duration])
        switch grouping {
        case .entry: break
        case .day:
            set.insert(.date)
            set.remove(.time)
        case .task:
            set.insert(.task)
            set.subtract([.date, .time])
        case .project:
            set.insert(.project)
            set.subtract([.date, .time, .task])
        }
        if !ratesOn { set.remove(.amount) }
        return ExportColumn.allCases.filter(set.contains)
    }

    /// Округление каждой строки до ближайшего шага. Работа меньше шага не исчезает.
    func rounded(_ seconds: TimeInterval) -> TimeInterval {
        guard roundMinutes > 0, seconds > 0 else { return seconds }
        let step = TimeInterval(roundMinutes * 60)
        return max(step, (seconds / step).rounded() * step)
    }
}

struct ExportTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var options: ExportOptions
}

/// Последние настройки и шаблоны.
enum ExportStorage {
    private static let lastKey = "export.last"
    private static let templatesKey = "export.templates"

    private static func read<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func write(_ value: some Encodable, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    static var last: ExportOptions {
        get { read(ExportOptions.self, lastKey) ?? ExportOptions() }
        set { write(newValue, lastKey) }
    }

    static var templates: [ExportTemplate] {
        get { read([ExportTemplate].self, templatesKey) ?? [] }
        set { write(newValue, templatesKey) }
    }
}

/// Логотип лежит рядом с данными и в настройки не попадает.
enum ExportLogo {
    private static var url: URL {
        Store.shared.fileURL.deletingLastPathComponent().appendingPathComponent("export-logo.png")
    }

    static var image: NSImage? { NSImage(contentsOf: url) }

    static func set(from source: URL) -> Bool {
        guard let image = NSImage(contentsOf: source), image.isValid, image.size.width > 0 else { return false }
        // Высоты 240 точек хватает для чёткой печати при показе в 48.
        let scale = min(240 / image.size.height, 1)
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let copy = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        guard let tiff = copy.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url, options: .atomic)) != nil
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Данные

struct ExportRow: Identifiable {
    let id = UUID()
    var day: Date?
    var start: Date?
    var end: Date?
    var task: String
    var project: String
    var comment: String
    var seconds: TimeInterval
    var amount: Double?
    /// Строка расхода: времени у неё нет.
    var isExpense = false
}

struct ExportReport {
    let options: ExportOptions
    let period: String
    let projectsTitle: String
    let author: String
    let rows: [ExportRow]
    let columns: [ExportColumn]

    var totalSeconds: TimeInterval { rows.reduce(0) { $0 + $1.seconds } }
    var totalAmount: Double { rows.reduce(0) { $0 + ($1.amount ?? 0) } }
    var title: String { options.title.trimmed.isEmpty ? L("Отчёт о работе") : options.title.trimmed }

    func time(_ seconds: TimeInterval) -> String {
        options.timeStyle == .decimal ? Fmt.hours(seconds) : Fmt.short(seconds)
    }

    func cell(_ row: ExportRow, _ column: ExportColumn) -> String {
        switch column {
        case .date: row.day.map { Fmt.dayShort.string(from: $0) } ?? ""
        case .time:
            if let start = row.start {
                "\(Fmt.hhmm.string(from: start))–\(row.end.map { Fmt.hhmm.string(from: $0) } ?? L("сейчас"))"
            } else {
                ""
            }
        case .task: row.task
        case .project: row.project
        case .duration: row.isExpense ? "" : time(row.seconds)
        case .amount: row.amount.map { Fmt.money($0) } ?? "—"
        case .comment: row.comment
        }
    }

    static func periodTitle(_ iv: DateInterval, options: ExportOptions) -> String {
        let last = iv.end.addingTimeInterval(-1)
        if Cal.ru.isDate(iv.start, inSameDayAs: last) { return Fmt.dayLongYear.string(from: iv.start).capitalizedFirst }
        if options.preset == .month || options.preset == .lastMonth { return Fmt.monthYear.string(from: iv.start).capitalizedFirst }
        return "\(Fmt.dayMonth.string(from: iv.start)) – \(Fmt.dayMonth.string(from: last))"
    }

    static func build(store: Store, options: ExportOptions, now: Date = Date()) -> ExportReport {
        struct Key: Hashable {
            var entry: UUID?
            var day: Date?
            var task: String?
            var project: UUID??
        }
        struct Bucket {
            var seconds: TimeInterval = 0
            var byProject: [UUID?: TimeInterval] = [:]
            var comments: [String] = []
            var start: Date?
            var end: Date?
        }
        let ratesOn = Extra.rates.isOn
        let iv = options.interval(now: now)
        let columns = options.effectiveColumns(ratesOn: ratesOn)
        var buckets: [Key: Bucket] = [:]

        for e in store.entries {
            if let id = e.projectID {
                if !options.projectIDs.isEmpty, !options.projectIDs.contains(id) { continue }
            } else if !options.includeNoProject {
                continue
            }
            let seconds = e.overlap(with: iv, now: now)
            guard seconds > 0 else { continue }
            let title = e.title.isEmpty ? L("Без описания") : e.title
            var key = Key()
            if options.grouping == .entry {
                key.entry = e.id
            }
            if columns.contains(.date) || options.grouping == .entry {
                key.day = Cal.ru.startOfDay(for: max(e.start, iv.start))
            }
            if columns.contains(.task) || options.grouping == .entry { key.task = title }
            if columns.contains(.project) || options.grouping == .entry { key.project = .some(e.projectID) }
            var bucket = buckets[key] ?? Bucket()
            bucket.seconds += seconds
            bucket.byProject[e.projectID, default: 0] += seconds
            if !e.note.isEmpty, !bucket.comments.contains(e.note) { bucket.comments.append(e.note) }
            if options.grouping == .entry {
                bucket.start = e.start
                bucket.end = e.end
            }
            buckets[key] = bucket
        }

        var rows: [ExportRow] = buckets.map { key, bucket in
            let seconds = options.rounded(bucket.seconds)
            let scale = bucket.seconds > 0 ? seconds / bucket.seconds : 1
            let parts = bucket.byProject.compactMap { id, s in store.amount(for: id, seconds: s) }
            let projectName = key.project.map { store.project($0)?.name ?? L("Без проекта") } ?? ""
            return ExportRow(day: key.day, start: bucket.start, end: bucket.end, task: key.task ?? "", project: projectName,
                             comment: bucket.comments.joined(separator: "; "), seconds: seconds,
                             amount: ratesOn && !parts.isEmpty ? parts.reduce(0, +) * scale : nil)
        }
        .sorted { a, b in
            let dayA = a.start ?? a.day ?? .distantPast, dayB = b.start ?? b.day ?? .distantPast
            if dayA != dayB { return dayA < dayB }
            if a.project != b.project { return a.project.localizedCompare(b.project) == .orderedAscending }
            return a.task.localizedCompare(b.task) == .orderedAscending
        }

        // Расходы идут строками после работы и входят в итог. Без колонки суммы показывать их негде.
        if options.includeExpenses ?? true, columns.contains(.amount) {
            for expense in store.expenses(in: iv, projects: options.projectIDs) {
                let name = expense.title.isEmpty ? L("Расход") : L("Расход: %@", expense.title)
                let projectName = store.project(expense.projectID)?.name ?? L("Без проекта")
                rows.append(ExportRow(day: expense.date, task: columns.contains(.task) ? name : "",
                                      project: columns.contains(.task) ? projectName : name, comment: "", seconds: 0,
                                      amount: expense.amount, isExpense: true))
            }
        }

        let selected = options.projectIDs.compactMap { store.project($0)?.name }.sorted()
        let projectsTitle = switch selected.count {
        case 0: L("Все проекты")
        case 1...3: selected.joined(separator: ", ")
        default: L("Проектов: %@", "\(selected.count)")
        }
        return ExportReport(options: options, period: periodTitle(iv, options: options), projectsTitle: projectsTitle,
                            author: UserDefaults.standard.string(forKey: ExtraKey.reportName) ?? "",
                            rows: rows, columns: columns)
    }

    /// Точка с запятой и BOM: так файл открывается и в Excel, и в Таблицах.
    func csv() -> String {
        // Текст, начатый с =, +, - или @, Excel выполнил бы как формулу: файл уходит клиенту, поэтому обезвреживаем.
        func quote(_ s: String) -> String {
            let safe = s.first.map { "=+-@\t\r".contains($0) } == true ? "'" + s : s
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        func title(_ c: ExportColumn) -> String { L(c.title) }
        var header: [String] = []
        for c in columns {
            if c == .time {
                header += [L("Начало"), L("Конец")]
            } else {
                header.append(title(c))
            }
        }
        var lines = [header.joined(separator: ";")]
        for row in rows {
            var cells: [String] = []
            for c in columns {
                switch c {
                case .date: cells.append(row.day.map { Fmt.date.string(from: $0) } ?? "")
                case .time:
                    cells.append(row.start.map { Fmt.hhmm.string(from: $0) } ?? "")
                    cells.append(row.end.map { Fmt.hhmm.string(from: $0) } ?? "")
                case .task, .project, .comment: cells.append(quote(cell(row, c)))
                case .duration: cells.append(row.isExpense ? "" : quote(time(row.seconds)))
                case .amount: cells.append(row.amount.map { quote(Fmt.money($0)) } ?? "")
                }
            }
            lines.append(cells.joined(separator: ";"))
        }
        var totals = [String](repeating: "", count: header.count)
        if let first = header.indices.first { totals[first] = quote(L("Итого")) }
        var position = 0
        for c in columns {
            if c == .duration { totals[position] = quote(time(totalSeconds)) }
            if c == .amount, rows.contains(where: { $0.amount != nil }) { totals[position] = quote(Fmt.money(totalAmount)) }
            position += c == .time ? 2 : 1
        }
        lines.append(totals.joined(separator: ";"))
        return "\u{FEFF}" + lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Страница A4

private struct ExportPage: View {
    let report: ExportReport
    let rows: [ExportRow]
    let isFirst: Bool
    let isLast: Bool
    let number: Int
    let count: Int
    let logo: NSImage?

    private let ink = Color(white: 0.1)
    private let muted = Color(white: 0.45)
    private let line = Color(white: 0.87)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isFirst { header }
            columns
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    ForEach(report.columns) { column in
                        cell(Text(verbatim: report.cell(row, column)), column)
                            .foregroundStyle(column == .date || column == .time || column == .project || column == .comment ? muted : ink)
                    }
                }
                .lineLimit(1)
                .frame(height: ExportPDF.rowHeight)
                .overlay(alignment: .bottom) { line.frame(height: 0.5) }
            }
            if isLast { total }
            Spacer(minLength: 0)
            HStack {
                Text(verbatim: "Hourfox")
                Spacer()
                Text(verbatim: "\(number) / \(count)")
            }
            .font(.system(size: 9))
            .foregroundStyle(muted)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(ink)
        .padding(48)
        .frame(width: ExportPDF.pageSize.width, height: ExportPDF.pageSize.height, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    /// Ширина колонок постоянна, остаток делят задача и комментарий.
    @ViewBuilder private func cell(_ text: Text, _ column: ExportColumn) -> some View {
        switch column {
        case .date: text.frame(width: 58, alignment: .leading)
        case .time: text.frame(width: 76, alignment: .leading)
        case .project: text.frame(width: 96, alignment: .leading)
        case .duration: text.frame(width: 70, alignment: .trailing)
        case .amount: text.frame(width: 76, alignment: .trailing)
        case .task, .comment: text.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: report.title).font(.system(size: 24, weight: .semibold))
                Text(verbatim: "\(report.projectsTitle), \(report.period)").font(.system(size: 13)).foregroundStyle(muted)
                if !report.options.client.trimmed.isEmpty {
                    Text(verbatim: L("Клиент: %@", report.options.client.trimmed)).font(.system(size: 13)).foregroundStyle(muted)
                }
                if !report.author.isEmpty {
                    Text(verbatim: report.author).font(.system(size: 13)).foregroundStyle(muted)
                }
            }
            Spacer(minLength: 0)
            if let logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: 140, maxHeight: 48, alignment: .trailing)
            }
        }
        .padding(.bottom, 26)
    }

    private var columns: some View {
        HStack(spacing: 10) {
            ForEach(report.columns) { column in
                cell(Text(verbatim: L(column.title)), column)
            }
        }
        .lineLimit(1)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(muted)
        .frame(height: ExportPDF.rowHeight)
        .overlay(alignment: .bottom) { ink.frame(height: 0.75) }
    }

    private var total: some View {
        HStack(spacing: 10) {
            Text(verbatim: L("Итого")).frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: report.time(report.totalSeconds)).frame(width: 90, alignment: .trailing)
            if report.columns.contains(.amount), report.rows.contains(where: { $0.amount != nil }) {
                Text(verbatim: Fmt.money(report.totalAmount))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 76, alignment: .trailing)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.top, 14)
    }
}

// MARK: - Сборка PDF

enum ExportPDF {
    static let pageSize = CGSize(width: 595, height: 842)
    static let rowHeight: CGFloat = 22
    /// С запасом: на любой странице остаётся место под строку «Итого».
    private static let firstPageRows = 25
    private static let pageRows = 30

    static func pages(for rows: [ExportRow]) -> [[ExportRow]] {
        var pages: [[ExportRow]] = []
        var rest = rows[...]
        var capacity = firstPageRows
        repeat {
            pages.append(Array(rest.prefix(capacity)))
            rest = rest.dropFirst(capacity)
            capacity = pageRows
        } while !rest.isEmpty
        return pages
    }

    @MainActor static func pdf(_ report: ExportReport) -> Data? {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output) else { return nil }
        var box = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        let split = pages(for: report.rows)
        let logo = report.options.showLogo ? ExportLogo.image : nil
        for (i, rows) in split.enumerated() {
            let page = ExportPage(report: report, rows: rows, isFirst: i == 0, isLast: i == split.count - 1, number: i + 1, count: split.count, logo: logo)
            let renderer = ImageRenderer(content: page)
            renderer.proposedSize = ProposedViewSize(pageSize)
            context.beginPDFPage(nil)
            renderer.render { _, draw in draw(context) }
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    @MainActor static func firstPage(_ report: ExportReport) -> some View {
        let split = pages(for: report.rows)
        return ExportPage(report: report, rows: split[0], isFirst: true, isLast: split.count == 1, number: 1, count: split.count,
                          logo: report.options.showLogo ? ExportLogo.image : nil)
    }
}

// MARK: - Окно экспорта

struct ExportSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("extra.clientReport") private var pdfOn = false
    @AppStorage("extra.rates") private var ratesOn = false
    @AppStorage(ExtraKey.reportName) private var author = ""
    @State private var options: ExportOptions
    @State private var templates = ExportStorage.templates
    @State private var savingTemplate = false
    @State private var templateName = ""
    @State private var pickingProjects = false
    @State private var logoVersion = 0

    /// projectID и interval приходят с той страницы, откуда открыли окно. Остальное — как в прошлый раз.
    init(projectID: UUID? = nil, interval: DateInterval? = nil) {
        var o = ExportStorage.last
        if let projectID { o.projectIDs = [projectID]; o.includeNoProject = false }
        if let interval {
            o.preset = .custom
            o.customStart = interval.start
            o.customEnd = interval.end.addingTimeInterval(-1)
        }
        _options = State(initialValue: o)
    }

    /// PDF доступен, только если он включён в дополнительных настройках.
    private var effective: ExportOptions {
        var o = options
        if !pdfOn { o.format = .csv }
        return o
    }

    private var isPDF: Bool { effective.format == .pdf }

    var body: some View {
        let report = ExportReport.build(store: store, options: effective)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                form(report)
                    .frame(width: 430)
                Divider()
                preview(report)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.03))
            }
            Divider()
            footer(report)
        }
        .frame(width: 860, height: 640)
        .onChange(of: options) { ExportStorage.last = options }
        .alert("Сохранить как шаблон", isPresented: $savingTemplate) {
            TextField(L("Название"), text: $templateName)
            Button("Отмена", role: .cancel) {}
            Button("Сохранить", action: saveTemplate)
        }
    }

    // MARK: Настройки

    private func form(_ report: ExportReport) -> some View {
        Form {
            Section("Что выгружать") {
                if pdfOn {
                    LabeledContent("Формат") {
                        HourfoxSegments(selection: $options.format, items: ExportFormat.allCases.map { .init(value: $0, title: $0.title) })
                    }
                }
                Picker("Период", selection: $options.preset) {
                    ForEach(ExportPreset.allCases) { Text(L($0.title)).tag($0) }
                }
                if options.preset == .custom {
                    LabeledContent("С") { DatePill(date: $options.customStart, showYear: true) }
                    LabeledContent("По") { DatePill(date: $options.customEnd, showYear: true) }
                }
                LabeledContent("Проекты") {
                    Button(projectsSummary) { pickingProjects = true }
                        .popover(isPresented: $pickingProjects, arrowEdge: .trailing) { projectsPopover }
                }
                Toggle("Записи без проекта", isOn: $options.includeNoProject)
                if ratesOn, !store.expenses(in: effective.interval(), projects: options.projectIDs).isEmpty {
                    Toggle("Расходы", isOn: Binding(get: { options.includeExpenses ?? true }, set: { options.includeExpenses = $0 }))
                }
            }
            Section("Как выглядит") {
                Picker("Группировка", selection: $options.grouping) {
                    ForEach(ExportGrouping.allCases) { Text(L($0.title)).tag($0) }
                }
                Picker("Округление времени", selection: $options.roundMinutes) {
                    Text("Без округления").tag(0)
                    ForEach([5, 15, 30], id: \.self) { Text(verbatim: L("До %@", Fmt.minutes($0))).tag($0) }
                }
                LabeledContent("Формат времени") {
                    HourfoxSegments(selection: $options.timeStyle, items: [
                        .init(value: .text, title: Fmt.short(5400)),
                        .init(value: .decimal, title: Fmt.hours(5400)),
                    ])
                }
            }
            Section("Колонки") {
                ForEach(ExportColumn.allCases) { column in
                    columnToggle(column, shown: report.columns.contains(column))
                }
            }
            if isPDF {
                Section("Шапка PDF") {
                    TextField(L("Заголовок"), text: $options.title, prompt: Text("Отчёт о работе"))
                    TextField(L("Ваше имя или компания"), text: $author, prompt: Text("Не указано"))
                    TextField(L("Клиент"), text: $options.client, prompt: Text("Не указан"))
                    logoRow
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    /// Колонка, которую диктует группировка, выключить нельзя; лишнюю для неё включить тоже.
    private func columnToggle(_ column: ExportColumn, shown: Bool) -> some View {
        let locked: Bool = {
            if column == .duration { return true }
            if column == .amount && !ratesOn { return true }
            var on = effective
            on.columns.insert(column)
            var off = effective
            off.columns.remove(column)
            return on.effectiveColumns(ratesOn: ratesOn) == off.effectiveColumns(ratesOn: ratesOn)
        }()
        return Toggle(L(column.title), isOn: Binding(
            get: { shown },
            set: { on in
                if on { options.columns.insert(column) } else { options.columns.remove(column) }
            }
        ))
        .disabled(locked)
    }

    private var logoRow: some View {
        LabeledContent("Логотип") {
            HStack(spacing: 8) {
                let _ = logoVersion
                if let logo = ExportLogo.image {
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 64, maxHeight: 22)
                    Button("Убрать") {
                        ExportLogo.remove()
                        logoVersion += 1
                    }
                }
                Button("Выбрать…", action: pickLogo)
            }
        }
    }

    private var projectsSummary: String {
        let names = options.projectIDs.compactMap { store.project($0)?.name }.sorted()
        switch names.count {
        case 0: return L("Все проекты")
        case 1: return names[0]
        default: return L("Проектов: %@", "\(names.count)")
        }
    }

    private var projectsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Все проекты") { options.projectIDs = [] }
                .disabled(options.projectIDs.isEmpty)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.projects) { p in
                        Toggle(isOn: Binding(
                            get: { options.projectIDs.contains(p.id) },
                            set: { on in
                                if on { options.projectIDs.insert(p.id) } else { options.projectIDs.remove(p.id) }
                            }
                        )) {
                            HStack(spacing: 6) {
                                Circle().fill(p.color.color).frame(width: 8, height: 8)
                                Text(verbatim: p.name)
                                if p.isArchived {
                                    Text("в архиве").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
        }
        .padding(14)
        .frame(width: 280)
    }

    // MARK: Предпросмотр

    @ViewBuilder private func preview(_ report: ExportReport) -> some View {
        if report.rows.isEmpty {
            ContentUnavailableView {
                Label("За этот период записей нет", icon: "clock")
            } description: {
                Text("Выберите другой период или проекты.")
            }
        } else if isPDF {
            let _ = logoVersion
            GeometryReader { g in
                let scale = min((g.size.width - 40) / ExportPDF.pageSize.width, (g.size.height - 40) / ExportPDF.pageSize.height)
                ExportPDF.firstPage(report)
                    .scaleEffect(scale)
                    .frame(width: ExportPDF.pageSize.width * scale, height: ExportPDF.pageSize.height * scale)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            GeometryReader { g in
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: report.csv().replacingOccurrences(of: "\u{FEFF}", with: ""))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(16)
                        // Короткий файл стоит в левом верхнем углу, а не по центру.
                        .frame(minWidth: g.size.width, minHeight: g.size.height, alignment: .topLeading)
                }
            }
        }
    }

    // MARK: Низ окна

    private func footer(_ report: ExportReport) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(templates) { template in
                    Button(template.name) { options = template.options }
                }
                if !templates.isEmpty { Divider() }
                Button("Сохранить как шаблон…") {
                    templateName = ""
                    savingTemplate = true
                }
                if !templates.isEmpty {
                    Menu("Удалить шаблон") {
                        ForEach(templates) { template in
                            Button(template.name, role: .destructive) {
                                templates.removeAll { $0.id == template.id }
                                ExportStorage.templates = templates
                            }
                        }
                    }
                }
            } label: {
                Text("Шаблоны")
            }
            .fixedSize()
            Text(verbatim: report.rows.isEmpty ? "" : L("Итого: %@", report.time(report.totalSeconds)))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Отмена") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Экспорт…") { export(report) }
                .keyboardShortcut(.defaultAction)
                .disabled(report.rows.isEmpty)
        }
        .padding(14)
    }

    private func saveTemplate() {
        let name = templateName.trimmed
        guard !name.isEmpty else { return }
        templates.removeAll { $0.name == name }
        templates.append(ExportTemplate(name: name, options: options))
        ExportStorage.templates = templates
    }

    private func pickLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if ExportLogo.set(from: url) {
            logoVersion += 1
        } else {
            let alert = NSAlert()
            alert.messageText = L("Не удалось добавить картинку")
            alert.runModal()
        }
    }

    private func export(_ report: ExportReport) {
        let panel = NSSavePanel()
        let pdf = isPDF
        panel.allowedContentTypes = [pdf ? .pdf : .commaSeparatedText]
        panel.nameFieldStringValue = "\(report.title) \(report.period).\(pdf ? "pdf" : "csv")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if pdf {
                guard let data = ExportPDF.pdf(report) else { return }
                try data.write(to: url, options: .atomic)
                NSWorkspace.shared.open(url)
            } else {
                try report.csv().write(to: url, atomically: true, encoding: .utf8)
            }
            dismiss()
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Не удалось сохранить файл")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
