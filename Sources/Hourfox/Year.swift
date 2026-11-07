import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Анимации отчёта. В автотестах окна стоят в фоне и не успевают договорить, поэтому снимаем сразу итог.
enum ReportMotion {
    static let disabledForTests = ["HOURFOX_EXTRASTEST", "HOURFOX_CALTEST"].contains { ProcessInfo.processInfo.environment[$0] != nil }
}

// MARK: - Расчёты года

/// Всё, что показывают карта, часы и карточка итогов. Считается одним проходом по записям.
struct YearStats {
    enum Rhythm: Equatable {
        case morning, day, evening, night

        var title: String {
            switch self {
            case .morning: L("Жаворонок")
            case .day: L("Дневной ритм")
            case .evening: L("Вечерний ритм")
            case .night: L("Сова")
            }
        }
    }

    var year: Int
    var interval: DateInterval
    var total: TimeInterval = 0
    var byDay: [Date: TimeInterval] = [:]
    var hourly = [TimeInterval](repeating: 0, count: 24)
    var topProject: (name: String, color: Color, seconds: TimeInterval)?
    /// Заработано по ставкам. Цена за проект идёт долей времени этого года, чтобы не считаться дважды.
    var income: Double?

    var activeDays: Int { byDay.count }
    var average: TimeInterval { byDay.isEmpty ? 0 : total / Double(byDay.count) }

    var longestDay: (day: Date, seconds: TimeInterval)? {
        byDay.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    var longestStreak: Int {
        var best = 0, current = 0
        var previous: Date?
        for day in byDay.keys.sorted() {
            let next = previous.flatMap { Cal.ru.date(byAdding: .day, value: 1, to: $0) }
            current = next == day ? current + 1 : 1
            best = max(best, current)
            previous = day
        }
        return best
    }

    var peakHour: Int? {
        guard total > 0 else { return nil }
        return hourly.indices.max { hourly[$0] < hourly[$1] }
    }

    var rhythm: Rhythm {
        func sum(_ hours: [Int]) -> TimeInterval { hours.reduce(0) { $0 + hourly[$1] } }
        let parts: [(Rhythm, TimeInterval)] = [
            (.morning, sum(Array(5 ..< 11))), (.day, sum(Array(11 ..< 17))),
            (.evening, sum(Array(17 ..< 22))), (.night, sum([22, 23, 0, 1, 2, 3, 4])),
        ]
        return parts.max { $0.1 < $1.1 }?.0 ?? .day
    }

    static func make(store: Store, year: Int, now: Date = Date()) -> YearStats {
        let start = Cal.ru.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now
        let end = Cal.ru.date(byAdding: .year, value: 1, to: start) ?? now
        let interval = DateInterval(start: start, end: end)
        var stats = YearStats(year: year, interval: interval)
        var byProject: [UUID: TimeInterval] = [:]

        for e in store.entries {
            let from = max(e.start, start), to = min(e.end ?? now, end)
            guard to > from else { continue }
            // Паузы вычитаются пропорционально, как и в остальных сводках.
            let span = (e.end ?? now).timeIntervalSince(e.start)
            let scale = span > 0 ? e.duration(at: now) / span : 0
            var cursor = from
            while cursor < to {
                let hour = Cal.ru.component(.hour, from: cursor)
                let nextHour = Cal.ru.nextDate(after: cursor, matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime) ?? to
                let piece = min(nextHour, to).timeIntervalSince(cursor) * scale
                stats.hourly[hour] += piece
                stats.byDay[Cal.ru.startOfDay(for: cursor), default: 0] += piece
                stats.total += piece
                if let id = e.projectID { byProject[id, default: 0] += piece }
                cursor = nextHour
            }
        }

        if let (id, seconds) = byProject.max(by: { $0.value < $1.value }), let p = store.project(id) {
            stats.topProject = (p.name, p.color.color, seconds)
        }
        if Extra.rates.isOn {
            var sum = 0.0
            for (id, seconds) in byProject {
                guard let p = store.project(id) else { continue }
                if let fixed = p.fixedPrice {
                    let all = store.entries.filter { $0.projectID == id }.reduce(0) { $0 + $1.duration(at: now) }
                    if all > 0 { sum += fixed * min(seconds / all, 1) }
                } else if let rate = p.rate {
                    sum += rate * seconds / 3600
                }
            }
            if sum > 0 { stats.income = sum }
        }
        return stats
    }
}

// MARK: - Карта года

/// Сетка дней, как у GitHub: столбец это неделя. Рисуется одним Canvas, поэтому год не тяжелее одного графика.
struct YearHeatmap: View {
    let stats: YearStats
    let side: CGFloat
    var gap: CGFloat = 2
    var hovered: Date?

    private static let labelHeight: CGFloat = 16

    static func level(_ seconds: TimeInterval) -> Int {
        switch seconds {
        case ..<1: 0
        case ..<(2 * 3600): 1
        case ..<(4 * 3600): 2
        case ..<(6 * 3600): 3
        default: 4
        }
    }

    static func color(_ level: Int) -> Color {
        switch level {
        case 0: Color.primary.opacity(0.1)
        case 1: Color.accentColor.opacity(0.32)
        case 2: Color.accentColor.opacity(0.52)
        case 3: Color.accentColor.opacity(0.75)
        default: Color.accentColor
        }
    }

    /// Понедельник недели, с которой начинается сетка.
    static func gridStart(_ interval: DateInterval) -> Date {
        Cal.ru.dateInterval(of: .weekOfYear, for: interval.start)?.start ?? interval.start
    }

    static func columns(_ interval: DateInterval) -> Int {
        let days = Cal.ru.dateComponents([.day], from: gridStart(interval), to: interval.end).day ?? 371
        return (days + 6) / 7
    }

    static func height(side: CGFloat, gap: CGFloat) -> CGFloat {
        labelHeight + side * 7 + gap * 6
    }

    var body: some View {
        let start = Self.gridStart(stats.interval)
        Canvas { context, _ in
            let step = side + gap
            let cal = Cal.ru
            var index = cal.dateComponents([.day], from: start, to: stats.interval.start).day ?? 0
            var day = stats.interval.start
            let shape = RoundedRectangle(cornerRadius: min(2, side / 3), style: .continuous)
            var labelled = Set<Int>()
            while day < stats.interval.end {
                let column = index / 7, row = index % 7
                let rect = CGRect(x: CGFloat(column) * step, y: Self.labelHeight + CGFloat(row) * step, width: side, height: side)
                context.fill(shape.path(in: rect), with: .color(Self.color(Self.level(stats.byDay[day] ?? 0))))
                if hovered == day {
                    context.stroke(shape.path(in: rect.insetBy(dx: -1, dy: -1)), with: .color(.primary.opacity(0.7)), lineWidth: 1)
                }
                let c = cal.dateComponents([.month, .day], from: day)
                // Подпись месяца над столбцом с его первым числом.
                if c.day == 1, let month = c.month, labelled.insert(month).inserted {
                    let text = Text(verbatim: Fmt.monthShort.string(from: day).capitalizedFirst)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    context.draw(text, at: CGPoint(x: CGFloat(column) * step, y: 0), anchor: .topLeading)
                }
                index += 1
                day = cal.date(byAdding: .day, value: 1, to: day) ?? stats.interval.end
            }
        }
        .frame(width: CGFloat(Self.columns(stats.interval)) * (side + gap) - gap, height: Self.height(side: side, gap: gap), alignment: .leading)
    }
}

/// Карта в отчёте: подстраивается под ширину окна и показывает день при наведении.
struct YearHeatmapCard: View {
    let stats: YearStats
    @State private var width: CGFloat = 0
    @State private var hover: Date?

    private let gap: CGFloat = 3

    private var side: CGFloat {
        let columns = CGFloat(YearHeatmap.columns(stats.interval))
        return max(5, min(18, (width - gap * (columns - 1) - 4) / columns))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Ширину меряем отдельно: сама карта не должна её раздвигать.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            YearHeatmap(stats: stats, side: side, gap: gap, hovered: hover)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard case .active(let p) = phase else { hover = nil; return }
                    hover = day(at: p)
                }
            HStack(spacing: 4) {
                Group {
                    if let hover {
                        Text(verbatim: "\(Fmt.dayLong.string(from: hover).capitalizedFirst): \(Fmt.short(stats.byDay[hover] ?? 0))")
                    } else {
                        Text(verbatim: L("Дней с записями: %@", "\(stats.activeDays)"))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                Spacer(minLength: 8)
                Text("Меньше").font(.caption).foregroundStyle(.secondary)
                ForEach(0 ..< 5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(YearHeatmap.color(level))
                        .frame(width: 10, height: 10)
                }
                Text("Больше").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func day(at p: CGPoint) -> Date? {
        let step = side + gap
        let y = p.y - 16
        guard y >= 0, p.x >= 0 else { return nil }
        let column = Int(p.x / step), row = Int(y / step)
        guard row < 7 else { return nil }
        let start = YearHeatmap.gridStart(stats.interval)
        guard let day = Cal.ru.date(byAdding: .day, value: column * 7 + row, to: start), stats.interval.contains(day), day < stats.interval.end else { return nil }
        return day
    }
}

// MARK: - Часы работы

/// Сутки по кругу: полночь сверху, длина луча это время, отработанное в этот час за год.
struct WorkClock: View {
    let stats: YearStats
    var size: CGFloat = 190
    /// В карточке итогов подпись стоит рядом с часами, там ей просторнее.
    var showsCaption = true

    var body: some View {
        ZStack {
            Canvas { context, canvas in
                let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                let outer = min(canvas.width, canvas.height) / 2 - 12
                let inner = outer * 0.48
                let peak = stats.hourly.max() ?? 0
                for hour in 0 ..< 24 {
                    let angle = Double(hour) / 24 * 2 * .pi - .pi / 2 + .pi / 24
                    let share = peak > 0 ? stats.hourly[hour] / peak : 0
                    let end = inner + (outer - inner) * max(share, 0.03)
                    var path = Path()
                    path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                    path.addLine(to: CGPoint(x: center.x + cos(angle) * end, y: center.y + sin(angle) * end))
                    let color = share > 0 ? Color.accentColor.opacity(0.35 + 0.65 * share) : Color.primary.opacity(0.1)
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: size / 38, lineCap: .round))
                }
                for hour in [0, 6, 12, 18] {
                    let angle = Double(hour) / 24 * 2 * .pi - .pi / 2
                    let text = Text(verbatim: "\(hour)").font(.system(size: 9)).foregroundStyle(.secondary)
                    context.draw(text, at: CGPoint(x: center.x + cos(angle) * (outer + 7), y: center.y + sin(angle) * (outer + 7)))
                }
            }
            if showsCaption {
            VStack(spacing: 1) {
                Text(verbatim: stats.rhythm.title)
                    .font(.system(size: size / 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                if let peak = stats.peakHour {
                    Text(verbatim: L("Пик в %@", String(format: "%02d:00", peak)))
                        .font(.system(size: max(9, size / 21)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(width: size * 0.5)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Год в отчёте

struct YearReportCharts: View {
    let stats: YearStats
    let totals: [ProjectTotal]
    let sum: TimeInterval

    var body: some View {
        VStack(spacing: 14) {
            YearHeatmapCard(stats: stats)
                .reportCard(title: L("Карта года"))
            HStack(alignment: .top, spacing: 14) {
                WorkClock(stats: stats, size: 250)
                    .frame(maxWidth: .infinity)
                    .reportCard(title: L("Часы работы"))
                ProjectDonut(totals: totals, sum: sum, wide: false)
                    .frame(height: 250)
                    .reportCard(title: L("По проектам"))
            }
        }
    }
}

// MARK: - Итоги года

/// Карточка для сохранения: 1080 × 1350, размер поста. Всегда тёмная, чтобы картинка не зависела от темы.
struct YearCard: View {
    let stats: YearStats
    static let size = CGSize(width: 540, height: 675)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: "Hourfox").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(verbatim: "\(stats.year)").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 14)
            Text(verbatim: Fmt.short(stats.total))
                .font(.system(size: 68, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text("в работе за год")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Spacer(minLength: 14)
            Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 14) {
                GridRow {
                    fact(L("Дней в работе"), "\(stats.activeDays)", nil)
                    fact(L("Дней подряд"), "\(stats.longestStreak)", nil)
                }
                GridRow {
                    if let day = stats.longestDay {
                        fact(L("Самый длинный день"), Fmt.short(day.seconds), Fmt.dayShort.string(from: day.day))
                    }
                    if let top = stats.topProject {
                        fact(L("Главный проект"), top.name, Fmt.short(top.seconds), dot: top.color)
                    }
                }
                if let income = stats.income {
                    GridRow { fact(L("Заработано"), Fmt.money(income), nil) }
                }
            }
            Spacer(minLength: 14)
            YearHeatmap(stats: stats, side: 6.8, gap: 2)
            Spacer(minLength: 12)
            HStack(spacing: 18) {
                WorkClock(stats: stats, size: 118, showsCaption: false)
                fact(L("Когда идёт работа"), stats.rhythm.title, stats.peakHour.map { L("Пик в %@", String(format: "%02d:00", $0)) })
            }
        }
        .padding(34)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background {
            ZStack {
                Color(white: 0.055)
                RadialGradient(colors: [Color.white.opacity(0.09), .clear], center: .topTrailing, startRadius: 10, endRadius: 460)
            }
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }

    private func fact(_ title: String, _ value: String, _ note: String?, dot: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack(spacing: 7) {
                if let dot { Circle().fill(dot).frame(width: 10, height: 10) }
                Text(verbatim: value)
                    .font(.system(size: 21, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if let note {
                Text(verbatim: note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum YearCardExport {
    @MainActor static func image(_ stats: YearStats) -> NSImage? {
        let renderer = ImageRenderer(content: Localized { YearCard(stats: stats) })
        renderer.scale = 2
        return renderer.nsImage
    }

    @MainActor static func png(_ stats: YearStats) -> Data? {
        guard let tiff = image(stats)?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

struct YearReviewSheet: View {
    let stats: YearStats
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private let scale: CGFloat = 0.86

    var body: some View {
        VStack(spacing: 14) {
            YearCard(stats: stats)
                .scaleEffect(scale)
                .frame(width: YearCard.size.width * scale, height: YearCard.size.height * scale)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 8) {
                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(copied ? L("Скопировано") : L("Скопировать"), action: copy)
                Button("Сохранить картинкой…", action: save)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: YearCard.size.width * scale + 40)
    }

    private func copy() {
        guard let image = YearCardExport.image(stats) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        copied = true
    }

    private func save() {
        guard let data = YearCardExport.png(stats) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Hourfox \(stats.year).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            dismiss()
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Не удалось сохранить файл")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

// MARK: - Звуки

/// Тихий щелчок механических часов. Звук синтезируется при первом запуске: файлов в приложении нет.
enum Sounds {
    static let key = "sounds.enabled"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
    /// Старт сам останавливает прошлую запись: двух щелчков подряд быть не должно.
    static var hush = false

    enum Kind { case start, stop }

    private static let startSound = NSSound(data: wav(.start))
    private static let stopSound = NSSound(data: wav(.stop))

    static func play(_ kind: Kind) {
        guard isOn, !hush else { return }
        guard let sound = kind == .start ? startSound : stopSound else { return }
        sound.stop()
        sound.volume = 0.22
        sound.play()
    }

    /// Звук: затухающие частоты корпуса и короткий удар в начале. Старт выше, стоп ниже.
    static func samples(_ kind: Kind, rate: Double = 44100) -> [Int16] {
        let tones: [(hz: Double, gain: Double, decay: Double)] = kind == .start
            ? [(3400, 0.55, 0.004), (5200, 0.3, 0.0025), (1500, 0.2, 0.007)]
            : [(2100, 0.55, 0.006), (3300, 0.28, 0.003), (950, 0.25, 0.01)]
        let count = Int(rate * 0.05)
        var generator = SystemRandomNumberGenerator()
        return (0 ..< count).map { i in
            let t = Double(i) / rate
            var v = tones.reduce(0.0) { $0 + $1.gain * sin(2 * .pi * $1.hz * t) * exp(-t / $1.decay) }
            if t < 0.001 { v += Double.random(in: -0.35 ... 0.35, using: &generator) * (1 - t / 0.001) }
            return Int16(max(-1, min(1, v * 0.8)) * 32000)
        }
    }

    static func wav(_ kind: Kind) -> Data {
        let pcm = samples(kind)
        var data = Data()
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let bytes = UInt32(pcm.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16).littleEndian)
        put(UInt16(1).littleEndian); put(UInt16(1).littleEndian)
        put(UInt32(44100).littleEndian); put(UInt32(88200).littleEndian)
        put(UInt16(2).littleEndian); put(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); put(bytes.littleEndian)
        for s in pcm { put(s.littleEndian) }
        return data
    }
}

struct SoundsToggle: View {
    @AppStorage(Sounds.key) private var on = false

    var body: some View {
        Toggle(isOn: Binding(get: { on }, set: { value in
            on = value
            if value { Sounds.play(.start) }
        })) {
            settingLabel("Звуки", "Тихий щелчок на старт и стоп таймера", "bell")
        }
    }
}
