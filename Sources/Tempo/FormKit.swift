import SwiftUI

// MARK: - Переключатель

/// Единственный переключатель в окнах: настройки, журнал, отчёт, задачи, экспорт.
struct TempoSegments<Value: Hashable>: View {
    struct Item {
        let value: Value
        var title: String?
        var icon: String?
        var help: String?
    }

    enum Size { case compact, large }

    @Binding var selection: Value
    let items: [Item]
    var size: Size = .compact
    @Namespace private var pill

    private var height: CGFloat { size == .large ? 34 : 24 }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let isOn = item.value == selection
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = item.value }
                } label: {
                    Group {
                        if let icon = item.icon {
                            Image(icon: icon, size: 14)
                                .frame(width: 30)
                        } else {
                            Text(verbatim: item.title ?? "")
                                .font(.system(size: size == .large ? 13 : 12, weight: .medium))
                                .lineLimit(1)
                                .padding(.horizontal, size == .large ? 28 : 11)
                        }
                    }
                    .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.8))
                    .frame(height: height)
                    .background {
                        if isOn {
                            Capsule().fill(Color.accentColor).matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(item.help ?? item.title ?? "")
                .accessibilityLabel(item.help ?? item.title ?? "")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(size == .large ? 3 : 2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .fixedSize()
    }
}

/// Кнопка панели окна без системной подложки: у переключателя своя капсула, две подряд смотрятся плохо.
struct BareToolbarItem<Content: View>: ToolbarContent {
    @ViewBuilder let content: () -> Content

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .primaryAction) { content() }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { content() }
        }
    }
}

// MARK: - Каркас окна-листа

/// Лист с заголовком, карточками и кнопками: у всех окон одинаковые поля и размеры.
struct TempoSheet<Content: View, Buttons: View>: View {
    let title: String
    var width: CGFloat = 430
    @ViewBuilder let content: () -> Content
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: title)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 2)
            content()
            HStack(spacing: 8) { buttons() }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(20)
        .frame(width: width)
    }
}

/// Карточка с рядами: вместо системной формы, у которой свои отступы и прокрутка.
struct FormCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct FormRow<Control: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
    }
}

struct FormLine: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, 12)
    }
}

/// Кнопка-капсула внутри ряда: дата, проект, папка.
struct PillLabel<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) { content() }
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.12 : 0.08)))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

/// Стрелка вниз: капсула открывает список. Одна на все такие кнопки, чтобы они выглядели одинаково.
struct PillChevron: View {
    var body: some View {
        Image(icon: "chevron-right", size: 10)
            .rotationEffect(.degrees(90))
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Дата

/// Дата капсулой, календарь открывается под ней. Двойной системный календарь и стрелки здесь не нужны.
struct DatePill: View {
    @Binding var date: Date
    /// Заголовок с годом: для диапазонов экспорта, где «Сегодня» читается хуже.
    var showYear = false
    @State private var open = false

    private var text: String {
        showYear ? Fmt.dayLongYear.string(from: date).capitalizedFirst : Fmt.dayTitle(date)
    }

    var body: some View {
        Button { open.toggle() } label: {
            PillLabel {
                Image(icon: "calendar", size: 13).foregroundStyle(.secondary)
                Text(verbatim: text).monospacedDigit()
                PillChevron()
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Localized {
                MiniCalendar(selection: date) { picked in
                    date = EntryTimes.moveDay(of: date, to: picked)
                    open = false
                }
            }
        }
    }
}

/// Дата простой строкой карточки: вся строка открывает календарь.
struct DateLine: View {
    @Binding var date: Date
    @State private var open = false
    @State private var hover = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                Image(icon: "calendar", size: 13)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(verbatim: Fmt.dayTitle(date)).lineLimit(1)
                Spacer(minLength: 8)
                PillChevron()
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color.primary.opacity(hover ? 0.04 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .popover(isPresented: $open, attachmentAnchor: .point(UnitPoint(x: 0.25, y: 0.85)), arrowEdge: .bottom) {
            Localized {
                MiniCalendar(selection: date) { picked in
                    date = EntryTimes.moveDay(of: date, to: picked)
                    open = false
                }
            }
        }
    }
}

struct MiniCalendar: View {
    let selection: Date
    let onPick: (Date) -> Void
    @State private var month: Date

    init(selection: Date, onPick: @escaping (Date) -> Void) {
        self.selection = selection
        self.onPick = onPick
        _month = State(initialValue: Cal.ru.dateInterval(of: .month, for: selection)!.start)
    }

    private var weekdays: [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = AppLanguage.shared.locale
        let symbols = cal.shortStandaloneWeekdaySymbols
        return (0 ..< 7).map { String(symbols[($0 + 1) % 7].prefix(2)).capitalizedFirst }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                Text(verbatim: Fmt.monthYear.string(from: month).capitalizedFirst)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 6)
                Spacer(minLength: 8)
                arrow("chevron-left", -1)
                arrow("chevron-right", 1)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, name in
                    Text(verbatim: name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(height: 22)
                }
                ForEach(DuePicker.days(in: month), id: \.self) { day in
                    cell(day)
                }
            }
            Button("Сегодня") { onPick(Date()) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .disabled(Cal.ru.isDateInToday(selection))
        }
        .padding(12)
    }

    private func arrow(_ icon: String, _ step: Int) -> some View {
        Button {
            month = Cal.ru.date(byAdding: .month, value: step, to: month) ?? month
        } label: {
            Image(icon: icon, size: 12)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cell(_ day: Date) -> some View {
        let isSelected = Cal.ru.isDate(day, inSameDayAs: selection)
        let isToday = Cal.ru.isDateInToday(day)
        let inMonth = Cal.ru.isDate(day, equalTo: month, toGranularity: .month)
        return Button { onPick(day) } label: {
            Text(verbatim: "\(Cal.ru.component(.day, from: day))")
                .font(.system(size: 12, weight: isSelected || isToday ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.white : isToday ? Color.accentColor : Color.primary.opacity(inMonth ? 0.85 : 0.28))
                .frame(width: 28, height: 28)
                .background(Circle().fill(isSelected ? Color.accentColor : .clear))
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Время

/// Время с клавиатуры: 14:30, 1430, 9, 9.30. Стрелки вверх и вниз меняют на 5 минут.
struct TimeField: View {
    @Binding var minutes: Int
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 13, weight: .medium))
            .monospacedDigit()
            .frame(width: 44, height: 28)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08)))
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .focused($focused)
            .onAppear { text = EntryTimes.text(minutes) }
            .onChange(of: minutes) { if !focused { text = EntryTimes.text(minutes) } }
            .onChange(of: focused) {
                if focused {
                    DispatchQueue.main.async { NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil) }
                } else {
                    commit()
                }
            }
            .onSubmit(commit)
            .onKeyPress(.upArrow) { nudge(5) }
            .onKeyPress(.downArrow) { nudge(-5) }
    }

    private func commit() {
        if let value = EntryTimes.parse(text), value != minutes { minutes = value }
        text = EntryTimes.text(EntryTimes.parse(text) ?? minutes)
    }

    private func nudge(_ step: Int) -> KeyPress.Result {
        let base = EntryTimes.parse(text) ?? minutes
        let value = ((base + step) % 1440 + 1440) % 1440
        minutes = value
        text = EntryTimes.text(value)
        return .handled
    }
}

// MARK: - Время записи: расчёты

enum EntryTimes {
    static func text(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// «14:30», «14.30», «14 30», «1430», «930», «9». Что не похоже на время: nil.
    static func parse(_ raw: String) -> Int? {
        let s = raw.trimmed
        guard !s.isEmpty else { return nil }
        let parts = s.split(whereSeparator: { ":.,- ".contains($0) }).map(String.init)
        var hour: Int?, minute: Int?
        if parts.count == 2 {
            hour = Int(parts[0])
            minute = Int(parts[1])
        } else if parts.count == 1, parts[0].allSatisfy(\.isNumber) {
            let d = parts[0]
            switch d.count {
            case 1, 2: hour = Int(d); minute = 0
            case 3: hour = Int(d.prefix(1)); minute = Int(d.suffix(2))
            case 4: hour = Int(d.prefix(2)); minute = Int(d.suffix(2))
            default: return nil
            }
        }
        guard let hour, let minute, (0 ... 23).contains(hour), (0 ... 59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    static func minutes(of date: Date) -> Int {
        let c = Cal.ru.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private static func date(day: Date, offset: Int = 0, minutes: Int, second: Int = 0) -> Date {
        let start = Cal.ru.startOfDay(for: day)
        let target = Cal.ru.date(byAdding: .day, value: offset, to: start) ?? start
        return Cal.ru.date(bySettingHour: minutes / 60, minute: minutes % 60, second: second, of: target) ?? target
    }

    /// На сколько дней конец позже начала.
    static func dayOffset(_ e: Entry) -> Int {
        guard let end = e.end else { return 0 }
        return Cal.ru.dateComponents([.day], from: Cal.ru.startOfDay(for: e.start), to: Cal.ru.startOfDay(for: end)).day ?? 0
    }

    /// Тот же момент суток в другой день.
    static func moveDay(of date: Date, to day: Date) -> Date {
        let c = Cal.ru.dateComponents([.hour, .minute, .second], from: date)
        return Self.date(day: day, minutes: (c.hour ?? 0) * 60 + (c.minute ?? 0), second: c.second ?? 0)
    }

    /// Другой день: запись переезжает целиком, длина не меняется.
    static func settingDay(_ e: Entry, _ day: Date) -> Entry {
        var e = e
        let offset = dayOffset(e)
        let end = e.end
        e.start = moveDay(of: e.start, to: day)
        if let end {
            let next = Cal.ru.date(byAdding: .day, value: offset, to: Cal.ru.startOfDay(for: e.start)) ?? e.start
            e.end = moveDay(of: end, to: next)
        }
        return e
    }

    /// Новое начало. Конец раньше начала значит следующий день. Запись на несколько суток сохраняет свою длину в днях.
    static func settingStart(_ e: Entry, minutes: Int) -> Entry {
        var e = e
        let offset = dayOffset(e)
        let day = Cal.ru.startOfDay(for: e.start)
        e.start = date(day: day, minutes: minutes)
        if let end = e.end {
            let endMinutes = Self.minutes(of: end)
            let second = Cal.ru.component(.second, from: end)
            let newOffset = offset > 1 ? offset : (endMinutes >= minutes ? 0 : 1)
            e.end = date(day: day, offset: newOffset, minutes: endMinutes, second: second)
        }
        return e
    }

    /// Новый конец: тот же день или, если время меньше начала, следующий.
    static func settingEnd(_ e: Entry, minutes: Int) -> Entry {
        var e = e
        guard e.end != nil else { return e }
        let startMinutes = Self.minutes(of: e.start)
        e.end = date(day: e.start, offset: minutes >= startMinutes ? 0 : 1, minutes: minutes)
        return e
    }

    /// Минуты суток внутри записи: момент разделения. Время меньше начала значит следующий день записи.
    static func moment(in e: Entry, minutes: Int) -> Date {
        let startMinutes = Self.minutes(of: e.start)
        return date(day: e.start, offset: minutes >= startMinutes ? 0 : 1, minutes: minutes)
    }
}

// MARK: - Выбор проекта

/// Проект простой строкой карточки, как название и заметки: без подписи и капсулы.
/// Список сделан своим: системное меню не показывает цвета.
struct ProjectLine: View {
    @Binding var selection: UUID?
    @EnvironmentObject var store: Store
    @State private var open = false
    @State private var hover = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                ProjectDot(project: store.project(selection))
                    .frame(width: 14)
                if let p = store.project(selection) {
                    Text(verbatim: p.label).lineLimit(1)
                } else {
                    Text("Без проекта").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                PillChevron()
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color.primary.opacity(hover ? 0.04 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .popover(isPresented: $open, attachmentAnchor: .point(UnitPoint(x: 0.25, y: 0.85)), arrowEdge: .bottom) {
            Localized {
                ScrollView {
                    VStack(spacing: 2) {
                        row(nil)
                        ForEach(store.projects.filter { !$0.isArchived || $0.id == selection }) { row($0) }
                    }
                    .padding(6)
                }
                .frame(width: 240)
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ p: Project?) -> some View {
        ProjectPillRow(project: p, selected: selection == p?.id) {
            selection = p?.id
            open = false
        }
    }
}

/// Цвет проекта. Без проекта пустое кольцо: место то же, и ясно, что цвета нет.
private struct ProjectDot: View {
    let project: Project?

    var body: some View {
        Group {
            if let project {
                Circle().fill(project.color.color)
            } else {
                Circle().strokeBorder(Color.primary.opacity(0.4), lineWidth: 1.5)
            }
        }
        .frame(width: 9, height: 9)
    }
}

private struct ProjectPillRow: View {
    let project: Project?
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ProjectDot(project: project)
                if let project {
                    Text(verbatim: project.label).lineLimit(1)
                } else {
                    Text("Без проекта")
                }
                Spacer(minLength: 8)
                if selected { Image(icon: "check", size: 12).foregroundStyle(Color.accentColor) }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
