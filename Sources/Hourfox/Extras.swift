import AppKit
import SwiftUI

// MARK: - Дополнительные возможности

/// Необязательные функции. Каждый настраивает Hourfox под себя, поэтому по умолчанию всё выключено.
enum Extra: String, CaseIterable, Identifiable {
    case smartInput, goal, dueDates, rates, clientReport, autoReport, closeMonths, yearReview

    var id: String { rawValue }
    var key: String { "extra.\(rawValue)" }
    var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    var title: String {
        switch self {
        case .smartInput: "Умный ввод"
        case .goal: "Цель на день"
        case .dueDates: "Сроки у задач"
        case .rates: "Ставки и суммы"
        case .clientReport: "PDF-отчёт для клиента"
        case .autoReport: "Отчёт по расписанию"
        case .closeMonths: "Закрытие месяцев"
        case .yearReview: "Год в отчёте"
        }
    }

    var subtitle: String {
        switch self {
        case .smartInput: "Всё одной строкой: созвон @клиент 30м"
        case .goal: "Прогресс рядом со временем за сегодня"
        case .dueDates: "Сегодня, завтра, просрочено. Просроченные наверху"
        case .rates: "Ставка задаётся в проекте, сумма видна в отчёте"
        case .clientReport: "Экспорт в PDF: кнопка в отчёте и формат в окне экспорта"
        case .autoReport: "Сам сохраняет отчёт за прошедший период в папку"
        case .yearReview: "Карта года, часы работы и итоги, которые можно сохранить картинкой"
        case .closeMonths: "Оплаченный месяц нельзя случайно изменить. Закрывается в отчёте"
        }
    }

    var symbol: String {
        switch self {
        case .smartInput: "text-cursor-input"
        case .goal: "target"
        case .dueDates: "calendar-clock"
        case .rates: "banknote"
        case .clientReport: "file-text"
        case .autoReport: "calendar-clock"
        case .closeMonths: "lock"
        case .yearReview: "chart-column"
        }
    }

    /// На экране знакомства только то, что нужно сразу. Остальное ждёт в настройках.
    var inOnboarding: Bool { self != .autoReport && self != .closeMonths && self != .yearReview }
}

enum ExtraKey {
    static let goalHours = "extra.goal.hours"
    static let currency = "extra.rates.currency"
    static let reportName = "extra.clientReport.name"
    static let expenses = "extra.rates.expenses"
    static let autoReportPeriod = "extra.autoReport.period"
    static let autoReportFolder = "extra.autoReport.folder"
    static let autoReportLast = "extra.autoReport.last"
    static let autoReportLastFile = "extra.autoReport.lastFile"

    static func value(_ key: String, default fallback: Int) -> Int {
        let v = UserDefaults.standard.integer(forKey: key)
        return v > 0 ? v : fallback
    }
}

/// Группы в настройках и на экране знакомства: функции собраны по смыслу.
enum ExtraGroup: String, CaseIterable, Identifiable {
    case time, clients

    var id: String { rawValue }

    var title: String {
        switch self {
        case .time: "Учёт времени"
        case .clients: "Клиенты"
        }
    }

    var extras: [Extra] {
        switch self {
        case .time: [.smartInput, .goal, .dueDates, .yearReview]
        case .clients: [.rates, .clientReport, .autoReport, .closeMonths]
        }
    }
}

struct ExtraSections: View {
    var top: AnyView?

    var body: some View {
        ForEach(ExtraGroup.allCases) { group in
            Section {
                ForEach(group.extras) { ExtraToggle(extra: $0) }
            } header: {
                SectionHeaderWithTop(top: group == ExtraGroup.allCases.first ? top : nil, title: L(group.title))
            }
        }
    }
}

/// Настройка функции живёт в одной строке с её выключателем: так видно, к чему она относится.
struct ExtraToggle: View {
    let extra: Extra
    @AppStorage private var isOn: Bool

    init(extra: Extra) {
        self.extra = extra
        _isOn = AppStorage(wrappedValue: false, extra.key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isOn.animation(.snappy)) {
                settingLabel(extra.title, extra.subtitle, extra.symbol)
            }
            if isOn {
                // Отступ совпадает с началом текста в подписи выключателя.
                ExtraOptions(extra: extra)
                    .padding(.leading, 34)
                    .transition(.opacity)
            }
        }
    }
}

struct ExtraOptions: View {
    let extra: Extra
    @AppStorage(ExtraKey.goalHours) private var goalHours = 6
    @AppStorage(ExtraKey.currency) private var currency = "USD"
    @AppStorage(ExtraKey.expenses) private var expensesOn = false

    var body: some View {
        switch extra {
        case .goal:
            option("Часов в день") {
                Slider(value: Binding(get: { Double(goalHours) }, set: { goalHours = Int($0.rounded()) }), in: 1 ... 12, step: 1)
                    .labelsHidden()
                    .frame(width: 180)
                Text(verbatim: Fmt.minutes(goalHours * 60))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
        case .rates:
            VStack(spacing: 8) {
                option("Валюта") {
                    Picker("Валюта", selection: $currency) {
                        ForEach(["USD", "EUR", "GBP", "RUB", "CNY", "BRL", "CZK"], id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                option("Расходы в проектах") {
                    Toggle("Расходы в проектах", isOn: $expensesOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }
        case .autoReport:
            AutoReportOptions()
        case .smartInput, .dueDates, .clientReport, .closeMonths, .yearReview:
            EmptyView()
        }
    }

    private func option(_ title: LocalizedStringKey, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            control()
        }
    }
}

// MARK: - Цель на день

struct GoalRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.notchInk.opacity(0.18), lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(progress >= 1 ? Color(nsColor: .systemGreen) : Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
        .animation(.snappy, value: progress)
    }
}

// MARK: - Сроки

enum DueDate {
    /// Точный момент срока. Без времени срок длится до конца дня.
    static func moment(_ due: Date, minutes: Int?) -> Date {
        let day = Cal.ru.startOfDay(for: due)
        guard let minutes else { return Cal.ru.date(byAdding: .day, value: 1, to: day) ?? day }
        return Cal.ru.date(byAdding: .minute, value: minutes, to: day) ?? day
    }

    static func isOverdue(_ due: Date, minutes: Int? = nil, now: Date = Date()) -> Bool {
        moment(due, minutes: minutes) <= now
    }

    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    static func text(_ due: Date, minutes: Int? = nil, now: Date = Date()) -> String {
        let calendar = Cal.ru
        let day: String
        if calendar.isDate(due, inSameDayAs: now) {
            day = L("Сегодня")
        } else if let next = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(due, inSameDayAs: next) {
            day = L("Завтра")
        } else {
            day = Fmt.dayShort.string(from: due)
        }
        return minutes.map { "\(day) \(clock($0))" } ?? day
    }

    static func color(_ due: Date, minutes: Int? = nil, now: Date = Date()) -> Color {
        if isOverdue(due, minutes: minutes, now: now) { return Color(nsColor: .systemRed) }
        return Cal.ru.isDate(due, inSameDayAs: now) ? .accentColor : .secondary
    }
}

/// Срок выбирается сразу в календаре. Щелчок по дню закрывает выбор.
/// Календарь свой: системный нельзя привести к виду остального приложения.
struct DuePicker: View {
    let date: Date?
    let minutes: Int?
    let onChange: (Date?, Int?) -> Void
    let onDone: () -> Void
    @State private var month: Date

    init(date: Date?, minutes: Int?, onChange: @escaping (Date?, Int?) -> Void, onDone: @escaping () -> Void) {
        self.date = date
        self.minutes = minutes
        self.onChange = onChange
        self.onDone = onDone
        _month = State(initialValue: Self.monthStart(date ?? Date()))
    }

    private static func monthStart(_ d: Date) -> Date {
        Cal.ru.dateInterval(of: .month, for: d)!.start
    }

    /// Дни месяца целыми неделями с понедельника, как и в отчёте.
    static func days(in month: Date) -> [Date] {
        let cal = Cal.ru
        let interval = cal.dateInterval(of: .month, for: month)!
        var day = cal.dateInterval(of: .weekOfYear, for: interval.start)!.start
        var result: [Date] = []
        repeat {
            for _ in 0 ..< 7 {
                result.append(day)
                day = cal.date(byAdding: .day, value: 1, to: day)!
            }
        } while day < interval.end
        return result
    }

    private var weekdays: [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = AppLanguage.shared.locale
        let symbols = cal.shortStandaloneWeekdaySymbols
        return (0 ..< 7).map { String(symbols[($0 + 1) % 7].prefix(2)).capitalizedFirst }
    }

    /// Высота задана явно: окно Notch намного выше содержимого, и без неё панель растянулась бы на всё окно.
    private static let columnHeight: CGFloat = 268

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                calendar.frame(width: 266, alignment: .top)
                VStack(alignment: .leading, spacing: 6) {
                    quickButtons
                    Spacer(minLength: 0)
                    doneButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
            .frame(height: Self.columnHeight, alignment: .top)
            DueTimeSlider(minutes: minutes, onChange: setTime)
        }
    }

    private var calendar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                Text(verbatim: Fmt.monthYear.string(from: month).capitalizedFirst)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.notchInk)
                    .lineLimit(1)
                Spacer(minLength: 8)
                arrow("chevron-left", -1)
                arrow("chevron-right", 1)
            }
            .padding(.leading, 8)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 0), count: 7), spacing: 0) {
                ForEach(weekdays, id: \.self) { name in
                    Text(verbatim: name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.notchInk.opacity(0.4))
                        .frame(height: 24)
                }
                ForEach(Self.days(in: month), id: \.self) { day in
                    DueDayCell(
                        day: day,
                        inMonth: Cal.ru.isDate(day, equalTo: month, toGranularity: .month),
                        selected: date.map { Cal.ru.isDate($0, inSameDayAs: day) } ?? false
                    ) { pick(day) }
                }
            }
        }
    }

    private func arrow(_ icon: String, _ step: Int) -> some View {
        DueRoundButton(icon: icon) {
            month = Cal.ru.date(byAdding: .month, value: step, to: month) ?? month
        }
    }

    @ViewBuilder private var quickButtons: some View {
        DuePill(title: L("Сегодня")) { pick(Date()) }
        DuePill(title: L("Завтра")) { pick(Cal.ru.date(byAdding: .day, value: 1, to: Date())) }
        if date != nil {
            DuePill(title: L("Без срока")) {
                onChange(nil, nil)
                onDone()
            }
        }
    }

    private var doneButton: some View {
        Button(action: onDone) {
            Text("Готово")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Capsule().fill(Color.accentColor))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }

    /// День меняется, а время остаётся: окно не закрывается, чтобы можно было выбрать и его.
    private func pick(_ day: Date?) {
        if let day { month = Self.monthStart(day) }
        onChange(day, minutes)
    }

    /// Время без дня: сегодня, а если этот час уже прошёл, то завтра.
    static func dayForTime(_ minutes: Int, now: Date = Date()) -> Date {
        let today = Cal.ru.startOfDay(for: now)
        let moment = Cal.ru.date(byAdding: .minute, value: minutes, to: today) ?? today
        return moment > now ? today : (Cal.ru.date(byAdding: .day, value: 1, to: today) ?? today)
    }

    private func setTime(_ value: Int?) {
        guard let value else { return onChange(date, nil) }
        let day = date ?? Self.dayForTime(value)
        month = Self.monthStart(day)
        onChange(day, value)
    }
}

/// Время срока: ползунок через весь день с шагом 15 минут. Щелчок сразу ставит время, дальше можно тянуть.
struct DueTimeSlider: View {
    let minutes: Int?
    let onChange: (Int?) -> Void

    private static let step = 15
    private static let thumb: CGFloat = 20
    private static let resting = 12 * 60

    /// Положение на дорожке в минуты: к ближайшим 15, последнее значение 23:45.
    static func value(x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        let share = min(max(x / width, 0), 1)
        let steps = (share * CGFloat(24 * 60 / step)).rounded()
        return min(Int(steps) * step, 24 * 60 - step)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(spacing: 4) {
                GeometryReader { g in
                    track(width: g.size.width)
                }
                .frame(height: 44)
                HStack {
                    ForEach(["00", "06", "12", "18", "24"], id: \.self) { mark in
                        Text(verbatim: mark)
                        if mark != "24" { Spacer(minLength: 0) }
                    }
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.notchInk.opacity(0.4))
            }
            if minutes != nil {
                Button { onChange(nil) } label: {
                    Image(icon: "x", size: 10)
                        .foregroundStyle(.notchInk.opacity(0.5))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.notchInk.opacity(0.09)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Без времени")
            }
        }
    }

    private func track(width: CGFloat) -> some View {
        let usable = max(width - Self.thumb, 1)
        // Пока время не выбрано, ползунок ждёт на полудне: в задачу оно попадёт только после касания.
        let shown = minutes ?? Self.resting
        let x = CGFloat(shown) / CGFloat(24 * 60) * usable + Self.thumb / 2
        let railY: CGFloat = 32
        return ZStack(alignment: .topLeading) {
            Capsule()
                .fill(.notchInk.opacity(0.14))
                .frame(width: width, height: 6)
                .offset(y: railY - 3)
            Capsule()
                .fill(minutes == nil ? AnyShapeStyle(.notchInk.opacity(0.22)) : AnyShapeStyle(Color.accentColor))
                .frame(width: x, height: 6)
                .offset(y: railY - 3)
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(.black.opacity(0.12)))
                .frame(width: Self.thumb, height: Self.thumb)
                .offset(x: x - Self.thumb / 2, y: railY - Self.thumb / 2)
            Text(verbatim: DueDate.clock(shown))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.notchInk.opacity(minutes == nil ? 0.4 : 1))
                .fixedSize()
                .frame(width: 48)
                .offset(x: min(max(x - 24, 0), width - 48), y: 0)
        }
        .frame(width: width, height: 44, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let value = Self.value(x: drag.location.x - Self.thumb / 2, width: usable)
                    guard value != minutes else { return }
                    if value % 60 == 0 {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                    onChange(value)
                }
        )
    }
}

private struct DueDayCell: View {
    let day: Date
    let inMonth: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    private var isToday: Bool { Cal.ru.isDateInToday(day) }

    var body: some View {
        Button(action: action) {
            Text(verbatim: "\(Cal.ru.component(.day, from: day))")
                .font(.system(size: 13, weight: selected || isToday ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(foreground)
                .frame(width: 32, height: 32)
                .background(Circle().fill(background))
                .frame(width: 38, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var foreground: AnyShapeStyle {
        if selected { return AnyShapeStyle(Color.white) }
        if isToday { return AnyShapeStyle(Color.accentColor) }
        return AnyShapeStyle(.notchInk.opacity(inMonth ? 0.9 : 0.25))
    }

    private var background: AnyShapeStyle {
        if selected { return AnyShapeStyle(Color.accentColor) }
        return AnyShapeStyle(.notchInk.opacity(hover ? 0.1 : 0))
    }
}

private struct DueRoundButton: View {
    let icon: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(icon: icon, size: 11)
                .foregroundStyle(.notchInk.opacity(hover ? 0.95 : 0.6))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.notchInk.opacity(hover ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct DuePill: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.notchInk.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(.notchInk.opacity(hover ? 0.16 : 0.09)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Проект задачи для меню по правому щелчку.
struct TaskProjectMenu: View {
    let task: TodoTask
    @EnvironmentObject var store: Store

    var body: some View {
        Menu("Проект") {
            Picker("Проект", selection: Binding(get: { task.projectID }, set: { store.setProject($0, for: task.id) })) {
                Text("Без проекта").tag(UUID?.none)
                ForEach(store.projects.filter { !$0.isArchived || $0.id == task.projectID }) { p in
                    Text(p.label).tag(UUID?.some(p.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

// MARK: - Суммы

extension Fmt {
    static func money(_ amount: Double) -> String {
        let code = UserDefaults.standard.string(forKey: ExtraKey.currency) ?? "USD"
        return amount.formatted(.currency(code: code).locale(AppLanguage.shared.locale))
    }
}

// MARK: - Хранилище: новые поля

extension Store {
    func setDue(_ date: Date?, minutes: Int? = nil, for id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].due = date.map { Cal.ru.startOfDay(for: $0) }
        tasks[i].dueMinutes = date == nil ? nil : minutes
    }

    /// Задача, время которой только что наступило. Если Mac спал или Hourfox был закрыт дольше
    /// пяти минут, напоминать поздно: задача и так красная и стоит наверху.
    func taskDueNow(now: Date = Date()) -> TodoTask? {
        guard Extra.dueDates.isOn else { return nil }
        return tasks.first { task in
            guard !task.done, let due = task.due, task.dueMinutes != nil else { return false }
            let moment = DueDate.moment(due, minutes: task.dueMinutes)
            return moment <= now && now.timeIntervalSince(moment) < 5 * 60 && task.dueReminded != moment
        }
    }

    func markDueReminded(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }), let due = tasks[i].due else { return }
        tasks[i].dueReminded = DueDate.moment(due, minutes: tasks[i].dueMinutes)
    }

    /// Отложить срок: минуты считаются от текущего момента.
    func snoozeDue(_ id: UUID, minutes: Int, now: Date = Date()) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let moment = now.addingTimeInterval(TimeInterval(minutes * 60))
        let day = Cal.ru.startOfDay(for: moment)
        tasks[i].due = day
        tasks[i].dueMinutes = Int(moment.timeIntervalSince(day) / 60)
    }

    func amount(for projectID: UUID?, seconds: TimeInterval) -> Double? {
        project(projectID)?.rate.map { $0 * seconds / 3600 }
    }
}
