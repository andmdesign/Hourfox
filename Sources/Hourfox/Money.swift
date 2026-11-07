import AppKit
import SwiftUI

// MARK: - Деньги проекта

/// Сколько проект принёс и во что обошёлся за всё время.
struct ProjectEconomy: Equatable {
    var seconds: TimeInterval
    /// Сумма по ставке или фиксированная цена.
    var income: Double?
    var isFixed: Bool
    var costs: Double

    /// Сколько реально вышло в час за вычетом расходов.
    var perHour: Double? {
        guard let income, seconds >= 60 else { return nil }
        return (income - costs) / (seconds / 3600)
    }

    var net: Double? { income.map { $0 - costs } }
}

extension Store {
    var expensesOn: Bool { Extra.rates.isOn && UserDefaults.standard.bool(forKey: ExtraKey.expenses) }

    func expenses(of projectID: UUID) -> [Expense] {
        expenses.filter { $0.projectID == projectID }.sorted { $0.date > $1.date }
    }

    func addExpense(_ title: String, amount: Double, date: Date, projectID: UUID) {
        expenses.append(Expense(projectID: projectID, title: title.trimmed, amount: amount, date: date))
    }

    func deleteExpense(_ id: UUID) {
        guard let removed = expenses.first(where: { $0.id == id }) else { return }
        expenses.removeAll { $0.id == id }
        archive.expenses.insert(ArchiveItem(item: removed), at: 0)
        offerUndo(L("Расход удалён")) { [weak self] in self?.restoreExpense(id) }
    }

    func restoreExpense(_ id: UUID) {
        guard let item = archive.expenses.first(where: { $0.id == id }) else { return }
        archive.expenses.removeAll { $0.id == id }
        expenses.append(item.item)
    }

    func eraseExpense(_ id: UUID) {
        archive.expenses.removeAll { $0.id == id }
    }

    /// Расходы за период; пустой список проектов значит все проекты.
    func expenses(in interval: DateInterval, projects: Set<UUID> = []) -> [Expense] {
        guard expensesOn else { return [] }
        return expenses
            .filter { interval.contains($0.date) && interval.end != $0.date && (projects.isEmpty || projects.contains($0.projectID)) }
            .sorted { $0.date < $1.date }
    }

    func economy(of projectID: UUID, now: Date = Date()) -> ProjectEconomy {
        let seconds = entries.filter { $0.projectID == projectID }.reduce(0) { $0 + $1.duration(at: now) }
        let project = project(projectID)
        let fixed = project?.fixedPrice
        let hourly = project?.rate.map { $0 * seconds / 3600 }
        let costs = expensesOn ? expenses(of: projectID).reduce(0) { $0 + $1.amount } : 0
        return ProjectEconomy(seconds: seconds, income: fixed ?? hourly, isFixed: fixed != nil, costs: costs)
    }
}

/// Сводка над записями проекта. Появляется, только когда есть что считать.
struct ProjectEconomyStrip: View {
    let projectID: UUID
    @EnvironmentObject var store: Store

    var body: some View {
        let e = store.economy(of: projectID)
        if e.income != nil || e.costs > 0 {
            HStack(spacing: 22) {
                item(L("Время"), Fmt.short(e.seconds))
                if let income = e.income {
                    item(e.isFixed ? L("За проект") : L("Сумма"), Fmt.money(income))
                }
                if e.costs > 0 { item(L("Расходы"), Fmt.money(e.costs)) }
                if let perHour = e.perHour { item(L("Выходит в час"), Fmt.money(perHour)) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 2)
        }
    }

    private func item(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(verbatim: value)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

// MARK: - Окно расходов

struct ExpensesSheet: View {
    let projectID: UUID
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var amount = ""
    @State private var date = Date()

    private var parsed: Double? {
        Project.parseRate(amount).flatMap { $0 > 0 ? $0 : nil }
    }

    var body: some View {
        let list = store.expenses(of: projectID)
        HourfoxSheet(title: L("Расходы: %@", store.name(for: projectID))) {
            FormCard {
                HStack(spacing: 8) {
                    TextField("", text: $title, prompt: Text("Такси, подписка, подрядчик"))
                        .textFieldStyle(.plain)
                        .onSubmit(add)
                    TextField("", text: $amount, prompt: Text("Сумма"))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 70)
                        .onSubmit(add)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                FormLine()
                HStack {
                    DatePill(date: $date)
                    Spacer()
                    Button("Добавить", action: add)
                        .disabled(parsed == nil)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
            }
            if !list.isEmpty {
                FormCard {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, expense in
                                if i > 0 { FormLine() }
                                row(expense)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } buttons: {
            Text(verbatim: list.isEmpty ? "" : L("Итого: %@", Fmt.money(list.reduce(0) { $0 + $1.amount })))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Готово") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func row(_ expense: Expense) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: expense.title.isEmpty ? L("Без описания") : expense.title)
                .foregroundStyle(expense.title.isEmpty ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: Fmt.dayShort.string(from: expense.date))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(verbatim: Fmt.money(expense.amount))
                .monospacedDigit()
            Button { store.deleteExpense(expense.id) } label: {
                Image(icon: "trash-2", size: 13)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Удалить")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private func add() {
        guard let parsed else { return }
        store.addExpense(title, amount: parsed, date: date, projectID: projectID)
        title = ""
        amount = ""
    }
}

// MARK: - Закрытые месяцы

extension Store {
    /// Закрытие работает, пока включена его настройка: выключил, и всё снова можно менять.
    var closedBefore: Date? { Extra.closeMonths.isOn ? lockedBefore : nil }

    func isClosed(_ date: Date) -> Bool {
        closedBefore.map { date < $0 } ?? false
    }

    /// Идущая запись закрытой не бывает: её ещё надо остановить.
    func isClosed(_ e: Entry) -> Bool {
        !e.isRunning && isClosed(e.start)
    }

    func isClosed(id: UUID) -> Bool {
        entry(id).map(isClosed) ?? false
    }

    func isMonthClosed(_ month: DateInterval) -> Bool {
        closedBefore.map { $0 >= month.end } ?? false
    }

    /// Закрыть месяц: вместе с ним и всё, что было раньше. Открыть: этот и более поздние.
    func setMonthClosed(_ closed: Bool, _ month: DateInterval) {
        lockedBefore = closed ? month.end : month.start
    }
}

// MARK: - Отчёт по расписанию

enum AutoReportPeriod: String, CaseIterable, Identifiable {
    case week, month
    var id: String { rawValue }
    var title: String { self == .week ? "Каждую неделю" : "Каждый месяц" }
}

/// Сохраняет отчёт за прошедший период. Проверка идёт при запуске и раз в час вместе с автобэкапом, отдельного таймера нет.
enum AutoReport {
    static var period: AutoReportPeriod {
        AutoReportPeriod(rawValue: UserDefaults.standard.string(forKey: ExtraKey.autoReportPeriod) ?? "") ?? .month
    }

    static var folder: URL? {
        UserDefaults.standard.string(forKey: ExtraKey.autoReportFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Прошедший период и его метка: по метке видно, сохраняли его уже или нет.
    static func due(_ period: AutoReportPeriod, now: Date = Date()) -> (key: String, interval: DateInterval) {
        let unit: Calendar.Component = period == .week ? .weekOfYear : .month
        let current = Cal.ru.dateInterval(of: unit, for: now)!
        let previous = Cal.ru.dateInterval(of: unit, for: current.start.addingTimeInterval(-1))!
        let c = Cal.ru.dateComponents([.year, .month, .day], from: previous.start)
        let key = String(format: "%@-%04d-%02d-%02d", period.rawValue, c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return (key, previous)
    }

    /// nil: сохранять нечего или уже сохранено.
    @MainActor @discardableResult
    static func run(store: Store, now: Date = Date()) -> URL? {
        guard Extra.autoReport.isOn, let folder else { return nil }
        let (key, interval) = due(period, now: now)
        guard UserDefaults.standard.string(forKey: ExtraKey.autoReportLast) != key else { return nil }

        var options = ExportStorage.last
        options.projectIDs = []
        options.includeNoProject = true
        options.preset = .custom
        options.customStart = interval.start
        options.customEnd = interval.end.addingTimeInterval(-1)
        options.format = Extra.clientReport.isOn ? .pdf : .csv
        let report = ExportReport.build(store: store, options: options, now: now)
        // Пустой период отмечаем сразу: завтра он останется таким же пустым.
        guard !report.rows.isEmpty else {
            UserDefaults.standard.set(key, forKey: ExtraKey.autoReportLast)
            return nil
        }

        let ext = options.format == .pdf ? "pdf" : "csv"
        let safe = "\(report.title) \(report.period)".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("\(safe).\(ext)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if options.format == .pdf {
                guard let data = ExportPDF.pdf(report) else { return nil }
                try data.write(to: url, options: .atomic)
            } else {
                try report.csv().write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            NSLog("Hourfox: не удалось сохранить отчёт: \(error.localizedDescription)")
            return nil
        }
        UserDefaults.standard.set(key, forKey: ExtraKey.autoReportLast)
        UserDefaults.standard.set(url.lastPathComponent, forKey: ExtraKey.autoReportLastFile)
        return url
    }
}

/// Настройка отчёта по расписанию: как часто и куда.
struct AutoReportOptions: View {
    @AppStorage(ExtraKey.autoReportPeriod) private var period = AutoReportPeriod.month.rawValue
    @AppStorage(ExtraKey.autoReportFolder) private var folder = ""
    @AppStorage(ExtraKey.autoReportLastFile) private var lastFile = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Как часто")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Picker("Как часто", selection: $period) {
                    ForEach(AutoReportPeriod.allCases) { Text(L($0.title)).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
            }
            HStack {
                Text("Папка")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if !folder.isEmpty {
                    Text(verbatim: URL(fileURLWithPath: folder).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button(folder.isEmpty ? L("Выбрать…") : L("Изменить…"), action: pick)
            }
            if !lastFile.isEmpty {
                Text(verbatim: L("Последний: %@", lastFile))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if folder.isEmpty {
                Text("Пока папка не выбрана, отчёты не сохраняются.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.path
    }
}
