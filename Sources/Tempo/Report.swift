import Charts
import SwiftUI

// MARK: - Страница отчёта

struct ReportView: View {
    @EnvironmentObject var store: Store
    @AppStorage("reportPeriod") private var period: Period = .week
    @State private var anchor = Date()
    @State private var open: Set<String> = []
    @AppStorage("extra.clientReport") private var clientReportOn = false
    @AppStorage("extra.closeMonths") private var closeMonthsOn = false
    @AppStorage("extra.yearReview") private var yearOn = false
    @State private var exporting = false
    @State private var reviewing: YearStats?

    private var interval: DateInterval {
        Cal.ru.dateInterval(of: period.component, for: anchor)!
    }

    var body: some View {
        let iv = interval
        ScrollView {
            ReportContent(period: period, interval: iv, title: title(iv), open: $open, trailing: AnyView(navigation(iv)))
                .padding(24)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .onChange(of: yearOn) { if !yearOn && period == .year { period = .month } }
        .onAppear { if !yearOn && period == .year { period = .month } }
        .sheet(isPresented: Binding(get: { reviewing != nil }, set: { if !$0 { reviewing = nil } })) {
            if let reviewing { Localized { YearReviewSheet(stats: reviewing) } }
        }
        .navigationTitle(L("Отчёт"))
        .navigationSubtitle("")
        .sheet(isPresented: $exporting) {
            Localized { ExportSheet(interval: iv) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if clientReportOn {
                    Button { exporting = true } label: {
                        Label("Экспорт", icon: "upload")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Настроить и сохранить файл")
                }
            }
            BareToolbarItem {
                TempoSegments(selection: $period, items: Period.allCases.filter { $0 != .year || yearOn }.map {
                    .init(value: $0, title: L($0.rawValue))
                })
            }
        }
    }

    /// Навигация у заголовка, как в календаре журнала: в панели окна остаются только период и экспорт.
    @ViewBuilder private func navigation(_ iv: DateInterval) -> some View {
        HStack(spacing: 10) {
            if closeMonthsOn && period == .month {
                let closed = store.isMonthClosed(iv)
                Button { store.setMonthClosed(!closed, iv) } label: {
                    PillLabel {
                        Image(icon: closed ? "lock" : "lock-open", size: 13)
                        Text(verbatim: closed ? L("Открыть месяц") : L("Закрыть месяц"))
                    }
                }
                .buttonStyle(.plain)
                .help(closed ? "Записи этого и следующих месяцев снова можно менять" : "Записи этого и прошлых месяцев нельзя будет менять")
            }
            if period == .year {
                Button { reviewing = YearStats.make(store: store, year: Cal.ru.component(.year, from: iv.start)) } label: {
                    PillLabel {
                        Image(icon: "sparkles", size: 13)
                        Text("Итоги года")
                    }
                }
                .buttonStyle(.plain)
                .disabled(store.total(in: iv) == 0)
            }
            Button { shift(-1) } label: { navIcon("chevron-left") }
                .help("Назад")
            Button("Сегодня") { anchor = Date() }
                .disabled(iv.contains(Date()))
            Button { shift(1) } label: { navIcon("chevron-right") }
                .help("Вперёд")
        }
        .buttonStyle(.borderless)
    }

    private func navIcon(_ icon: String) -> some View {
        Image(icon: icon, size: 13)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }

    private func shift(_ n: Int) {
        anchor = Cal.ru.date(byAdding: period.component, value: n, to: anchor) ?? anchor
    }

    private func title(_ iv: DateInterval) -> String {
        switch period {
        case .day:
            return Fmt.dayTitle(iv.start)
        case .week:
            let last = iv.end.addingTimeInterval(-1)
            return "\(Fmt.dayMonth.string(from: iv.start)) – \(Fmt.dayMonth.string(from: last))"
        case .month:
            return Fmt.monthYear.string(from: iv.start).capitalizedFirst
        case .year:
            return "\(Cal.ru.component(.year, from: iv.start))"
        }
    }
}

// MARK: - Расчёты

/// Кусок столбика: один проект за один день.
struct ReportSegment: Identifiable {
    let day: Date
    let key: String
    let start: Double
    let end: Double
    /// Верхний кусок дня: над ним подпись с итогом.
    let isTop: Bool
    let dayTotal: Double
    var id: String { "\(day.timeIntervalSince1970)|\(key)" }
}

enum ReportMath {
    /// Столбики собираем сами: порядок проектов одинаков каждый день, а между кусками есть зазор.
    static func segments(_ points: [DayPoint], order: [String], gap: Double = 0) -> [ReportSegment] {
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        var result: [ReportSegment] = []
        for (day, items) in Dictionary(grouping: points, by: \.day) {
            let sorted = items.sorted { (rank[$0.key] ?? .max) < (rank[$1.key] ?? .max) }
            let total = sorted.reduce(0) { $0 + $1.hours }
            var y = 0.0
            for (i, p) in sorted.enumerated() {
                let top = y + p.hours
                result.append(ReportSegment(day: day, key: p.key, start: i == 0 || p.hours <= gap ? y : y + gap, end: top,
                                            isTop: i == sorted.count - 1, dayTotal: total))
                y = top
            }
        }
        return result.sorted { $0.day < $1.day }
    }

    /// Среднее считается по дням с записями: выходной без работы не занижает его.
    static func dailyAverage(_ points: [DayPoint]) -> (seconds: TimeInterval, days: Int) {
        let days = Set(points.map(\.day)).count
        guard days > 0 else { return (0, 0) }
        return (points.reduce(0) { $0 + $1.hours } * 3600 / Double(days), days)
    }
}

extension Fmt {
    /// «6:30» — подпись над столбиком, где «6 ч 30 мин» не помещается.
    static func hoursMinutes(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    /// «57 %». Малая, но ненулевая доля не притворяется нулём: «<1 %».
    static func percent(_ share: Double) -> String {
        share > 0 && share < 0.005 ? "<1\u{00A0}%" : "\(Int((share * 100).rounded()))\u{00A0}%"
    }
}

// MARK: - Содержимое

struct ReportContent: View {
    let period: Period
    let interval: DateInterval
    let title: String
    @Binding var open: Set<String>
    /// Для снимков: день, над которым будто бы стоит курсор.
    var hoveredDay: Date?
    /// Кнопки справа от заголовка.
    var trailing: AnyView?
    @EnvironmentObject var store: Store
    @AppStorage("extra.rates") private var ratesOn = false

    var body: some View {
        let totals = store.totals(in: interval)
        // Год считается одним проходом: по дням через сводки это было бы 365 проходов.
        let stats = period == .year ? YearStats.make(store: store, year: Cal.ru.component(.year, from: interval.start)) : nil
        let points = period == .year ? [] : store.dailyPoints(in: interval)
        let sum = totals.reduce(0) { $0 + $1.seconds }

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                if period == .month && store.isMonthClosed(interval) {
                    Image(icon: "lock", size: 14)
                        .foregroundStyle(.secondary)
                        .help("Месяц закрыт")
                }
                Spacer(minLength: 12)
                trailing
            }
            tiles(totals: totals, points: points, sum: sum, stats: stats)
            if sum == 0 {
                Text("За этот период записей нет.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .reportCard()
            } else if let stats {
                YearReportCharts(stats: stats, totals: totals, sum: sum)
                ReportTable(totals: totals, sum: sum, open: $open)
            } else {
                charts(totals: totals, points: points, sum: sum)
                ReportTable(totals: totals, sum: sum, open: $open)
            }
        }
    }

    private func tiles(totals: [ProjectTotal], points: [DayPoint], sum: TimeInterval, stats: YearStats?) -> some View {
        let amounts = totals.compactMap { store.amount(for: $0.projectID, seconds: $0.seconds) }
        let average = stats.map { (seconds: $0.average, days: $0.activeDays) } ?? ReportMath.dailyAverage(points)
        return HStack(spacing: 14) {
            ReportTile(title: L("Всего"), number: sum, format: Fmt.short)
            if period == .day {
                let count = store.entries.filter { $0.overlap(with: interval) > 0 }.count
                ReportTile(title: L("Записей"), number: Double(count), format: { "\(Int($0.rounded()))" })
            } else {
                ReportTile(title: L("В среднем за день"), number: average.seconds, format: Fmt.short,
                           hint: average.days > 0 ? L("Дней с записями: %@", "\(average.days)") : nil)
            }
            let costs = store.expenses(in: interval).reduce(0) { $0 + $1.amount }
            if ratesOn && (!amounts.isEmpty || costs > 0) {
                ReportTile(title: L("Сумма"), number: amounts.reduce(0, +), format: Fmt.money,
                           hint: costs > 0 ? L("Расходы: %@", Fmt.money(costs)) : nil)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func charts(totals: [ProjectTotal], points: [DayPoint], sum: TimeInterval) -> some View {
        if period == .day {
            ProjectDonut(totals: totals, sum: sum, wide: true)
                .reportCard(title: L("По проектам"))
        } else {
            let bars = DailyChart(points: points, interval: interval, period: period, totals: totals, hovered: hoveredDay)
                .frame(height: 290)
                .reportCard(title: L("По дням"))
            let donut = ProjectDonut(totals: totals, sum: sum, wide: false)
                .frame(height: 290)
                .reportCard(title: L("По проектам"))
            // В узком окне графики встают друг под друга.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    bars.frame(minWidth: 420)
                    donut.frame(width: 250)
                }
                VStack(spacing: 14) {
                    bars
                    donut
                }
            }
        }
    }
}

extension View {
    func reportCard(title: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            self
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

/// Число, которое SwiftUI пересчитывает на каждом кадре анимации.
private struct CountingText: View, Animatable {
    var value: Double
    let format: (Double) -> String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(verbatim: format(value))
    }
}

struct ReportTile: View {
    let title: String
    let number: Double
    let format: (Double) -> String
    var hint: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// При открытии цифра набегает от нуля, при смене периода идёт от прошлого значения.
    @State private var shown = 0.0

    init(title: String, number: Double, format: @escaping (Double) -> String, hint: String? = nil) {
        self.title = title
        self.number = number
        self.format = format
        self.hint = hint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            CountingText(value: shown, format: format)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(verbatim: hint ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .reportCard()
        .onAppear { reveal() }
        .onChange(of: number) { reveal() }
    }

    private func reveal() {
        if reduceMotion || ReportMotion.disabledForTests {
            shown = number
        } else {
            withAnimation(.easeOut(duration: 0.65)) { shown = number }
        }
    }
}

// MARK: - Столбики по дням

struct DailyChart: View {
    /// Дни с подписями: каждый день недели или 1, 6, 11… в месяце.
    private var axisDays: [Date] {
        let step = period == .month ? 5 : 1
        var days: [Date] = []
        var day = interval.start
        while day < interval.end {
            days.append(day.addingTimeInterval(12 * 3600))
            day = Cal.ru.date(byAdding: .day, value: step, to: day) ?? interval.end
        }
        return days
    }

    let points: [DayPoint]
    let interval: DateInterval
    let period: Period
    let totals: [ProjectTotal]
    @EnvironmentObject var store: Store
    @State private var hover: Date?
    /// Дни, столбики которых уже выросли: они поднимаются по очереди слева направо.
    @State private var grown: Set<Date> = []
    /// Каскад закончился: новые записи, появившиеся при открытом отчёте, сразу видны.
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(points: [DayPoint], interval: DateInterval, period: Period, totals: [ProjectTotal], hovered: Date? = nil) {
        self.points = points
        self.interval = interval
        self.period = period
        self.totals = totals
        _hover = State(initialValue: hovered)
    }

    var body: some View {
        let dayMax = Dictionary(grouping: points, by: \.day).values.map { $0.reduce(0) { $0 + $1.hours } }.max() ?? 1
        // Зазор в 2 точки при высоте графика около 260.
        let segments = ReportMath.segments(points, order: totals.map(\.id), gap: dayMax / 130)
        Chart(segments) { s in
            let height = settled || grown.contains(s.day) ? 1.0 : 0.0
            BarMark(x: .value("День", s.day, unit: .day), yStart: .value("С", s.start * height), yEnd: .value("По", s.end * height))
                .foregroundStyle(by: .value("Проект", s.key))
                .cornerRadius(3)
                .opacity(hover == nil || hover == s.day ? 1 : 0.4)
                .annotation(position: .top, spacing: 3) {
                    if s.isTop && period == .week && (settled || grown.contains(s.day)) {
                        Text(verbatim: Fmt.hoursMinutes(s.dayTotal * 3600))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
        }
        .chartForegroundStyleScale(domain: totals.map(\.id), range: totals.map { store.color(for: $0.projectID) })
        .chartLegend(.hidden)
        .chartXScale(domain: interval.start ... interval.end)
        .chartYScale(domain: 0 ... dayMax * 1.12)
        .chartXAxis {
            // Подпись стоит в середине своего дня, ровно под столбиком.
            AxisMarks(values: axisDays) { _ in
                AxisValueLabel(format: period == .week ? .dateTime.weekday(.abbreviated) : .dateTime.day(), anchor: .top)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let h = v.as(Double.self) { Text(verbatim: "\(h.formatted(.number.precision(.fractionLength(0...1))))\u{00A0}" + L("ч")) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            hover = day(at: phase, proxy: proxy, geo: geo)
                        }
                    if let hover, let x = proxy.position(forX: hover.addingTimeInterval(12 * 3600)), let frame = proxy.plotFrame {
                        let tip = DayTooltip(day: hover, points: points.filter { $0.day == hover }, totals: totals)
                        let left = geo[frame].minX + x
                        tip.frame(width: 190)
                            .offset(x: min(max(0, left - 95), geo.size.width - 190), y: 2)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .task(id: interval) { await grow() }
    }

    private func grow() async {
        settled = false
        grown = []
        if reduceMotion || ReportMotion.disabledForTests {
            settled = true
            return
        }
        let days = Set(points.map(\.day)).sorted()
        // Весь каскад укладывается в 0,4 секунды, сколько бы дней ни было.
        let step = min(0.035, 0.4 / Double(max(days.count, 1)))
        for day in days {
            withAnimation(.easeOut(duration: 0.35)) { _ = grown.insert(day) }
            try? await Task.sleep(for: .seconds(step))
            if Task.isCancelled { return }
        }
        settled = true
    }

    private func day(at phase: HoverPhase, proxy: ChartProxy, geo: GeometryProxy) -> Date? {
        guard case .active(let location) = phase, let frame = proxy.plotFrame,
              let date: Date = proxy.value(atX: location.x - geo[frame].minX) else { return nil }
        let start = Cal.ru.startOfDay(for: date)
        return points.contains { $0.day == start } ? start : nil
    }
}

/// Подсказка над столбиком: итог дня и проекты в нём.
private struct DayTooltip: View {
    let day: Date
    let points: [DayPoint]
    let totals: [ProjectTotal]
    @EnvironmentObject var store: Store

    var body: some View {
        let sum = points.reduce(0) { $0 + $1.hours } * 3600
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(verbatim: Fmt.dayShort.string(from: day)).fontWeight(.medium)
                Spacer()
                Text(verbatim: Fmt.short(sum)).fontWeight(.medium)
            }
            ForEach(totals.filter { t in points.contains { $0.key == t.id } }) { t in
                let hours = points.first { $0.key == t.id }?.hours ?? 0
                HStack(spacing: 6) {
                    Circle().fill(store.color(for: t.projectID)).frame(width: 7, height: 7)
                    Text(store.name(for: t.projectID)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(verbatim: Fmt.short(hours * 3600)).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .monospacedDigit()
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

// MARK: - Кольцо

/// Маска: сектор от 12 часов по часовой стрелке. Кольцо дорисовывается вместе с ней.
private struct PieReveal: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard progress < 1 else { return Path(rect) }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: max(rect.width, rect.height), startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * progress), clockwise: false)
        path.closeSubpath()
        return path
    }
}

struct ProjectDonut: View {
    let totals: [ProjectTotal]
    let sum: TimeInterval
    let wide: Bool
    @EnvironmentObject var store: Store
    @State private var hover: String?
    @State private var drawn = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let legendLimit = 4

    var body: some View {
        if wide {
            HStack(spacing: 24) {
                ring.frame(width: 170, height: 170)
                legend(limit: 8).frame(maxWidth: 280)
                Spacer(minLength: 0)
            }
        } else {
            VStack(spacing: 12) {
                ring.frame(maxWidth: .infinity, maxHeight: .infinity)
                legend(limit: legendLimit)
            }
        }
    }

    private var ring: some View {
        let picked = totals.first { $0.id == hover }
        return Chart(totals) { t in
            SectorMark(angle: .value("Время", t.seconds), innerRadius: .ratio(0.7), angularInset: totals.count > 1 ? 1.2 : 0)
                .foregroundStyle(store.color(for: t.projectID))
                .cornerRadius(3)
                .opacity(hover == nil || hover == t.id ? 1 : 0.35)
        }
        .chartLegend(.hidden)
        .chartBackground { _ in
            VStack(spacing: 1) {
                Text(verbatim: Fmt.short(picked?.seconds ?? sum))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 110)
                Text(verbatim: picked.map { store.name(for: $0.projectID) } ?? L("Всего"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 80)
            }
        }
        .mask(PieReveal(progress: drawn))
        .onAppear {
            if reduceMotion || ReportMotion.disabledForTests {
                drawn = 1
            } else {
                withAnimation(.easeInOut(duration: 0.7)) { drawn = 1 }
            }
        }
        .chartOverlay { _ in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let p) = phase else { hover = nil; return }
                        hover = sector(at: p, size: geo.size)
                    }
            }
        }
    }

    /// Какой проект под курсором: сектора идут от 12 часов по часовой стрелке.
    private func sector(at p: CGPoint, size: CGSize) -> String? {
        let dx = p.x - size.width / 2, dy = p.y - size.height / 2
        let radius = min(size.width, size.height) / 2
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance <= radius, distance >= radius * 0.7 else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        var walked = 0.0
        let target = angle / (2 * .pi) * sum
        for t in totals {
            walked += t.seconds
            if target <= walked { return t.id }
        }
        return totals.last?.id
    }

    private func legend(limit: Int) -> some View {
        let shown = totals.count > limit ? Array(totals.prefix(limit - 1)) : totals
        let rest = totals.dropFirst(shown.count)
        return VStack(spacing: 5) {
            ForEach(shown) { t in
                row(color: store.color(for: t.projectID), name: store.name(for: t.projectID), seconds: t.seconds)
                    .contentShape(Rectangle())
                    .onHover { hover = $0 ? t.id : nil }
            }
            if !rest.isEmpty {
                row(color: Color.primary.opacity(0.25), name: L("Ещё: %@", "\(rest.count)"), seconds: rest.reduce(0) { $0 + $1.seconds })
            }
        }
        .font(.caption)
    }

    private func row(color: Color, name: String, seconds: TimeInterval) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(verbatim: name).lineLimit(1)
            Spacer(minLength: 6)
            Text(verbatim: Fmt.percent(seconds / max(sum, 1)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Таблица

private enum ReportColumn {
    static let share: CGFloat = 44
    static let time: CGFloat = 92
    static let money: CGFloat = 88
}

struct ReportTable: View {
    let totals: [ProjectTotal]
    let sum: TimeInterval
    @Binding var open: Set<String>
    @EnvironmentObject var store: Store
    @AppStorage("extra.rates") private var ratesOn = false

    private var showMoney: Bool {
        ratesOn && totals.contains { store.amount(for: $0.projectID, seconds: $0.seconds) != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Проект").frame(maxWidth: .infinity, alignment: .leading)
                Text("Доля").frame(width: ReportColumn.share, alignment: .trailing)
                Text("Время").frame(width: ReportColumn.time, alignment: .trailing)
                if showMoney { Text("Сумма").frame(width: ReportColumn.money, alignment: .trailing) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)
            Divider()
            ForEach(Array(totals.enumerated()), id: \.element.id) { i, t in
                ProjectTotalRow(total: t, sum: sum, isOpen: open.contains(t.id), showMoney: showMoney) {
                    withAnimation(.snappy) {
                        if open.contains(t.id) { open.remove(t.id) } else { open.insert(t.id) }
                    }
                }
                if i < totals.count - 1 { Divider() }
            }
        }
        .reportCard()
    }
}

struct ProjectTotalRow: View {
    let total: ProjectTotal
    let sum: TimeInterval
    let isOpen: Bool
    let showMoney: Bool
    let toggle: () -> Void
    @EnvironmentObject var store: Store

    var body: some View {
        let share = total.seconds / max(sum, 1)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(icon: "chevron-right", size: 11)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 10)
                    Circle().fill(store.color(for: total.projectID)).frame(width: 9, height: 9)
                    Text(store.name(for: total.projectID))
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    percent(share)
                    Text(Fmt.short(total.seconds))
                        .frame(width: ReportColumn.time, alignment: .trailing)
                    if showMoney { money(total.seconds).foregroundStyle(.secondary) }
                }
                .monospacedDigit()
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(spacing: 0) {
                    ForEach(total.tasks) { t in
                        HStack(spacing: 10) {
                            Text(t.title).lineLimit(1)
                            Spacer(minLength: 8)
                            percent(t.seconds / max(sum, 1))
                            Text(Fmt.short(t.seconds))
                                .frame(width: ReportColumn.time, alignment: .trailing)
                            if showMoney { money(t.seconds) }
                        }
                        .monospacedDigit()
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 39)
                        .padding(.vertical, 5)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func percent(_ share: Double) -> some View {
        Text(verbatim: Fmt.percent(share))
            .foregroundStyle(.secondary)
            .frame(width: ReportColumn.share, alignment: .trailing)
    }

    @ViewBuilder private func money(_ seconds: TimeInterval) -> some View {
        Text(verbatim: store.project(total.projectID)?.fixedPrice != nil ? L("фикс") : store.amount(for: total.projectID, seconds: seconds).map(Fmt.money) ?? "—")
            .frame(width: ReportColumn.money, alignment: .trailing)
    }
}
