import AppKit
import SwiftUI

// MARK: - Журнал: список или календарь

enum JournalMode: String, CaseIterable, Identifiable {
    case list = "Список", calendar = "Календарь"
    var id: String { rawValue }
}

struct JournalPage: View {
    @AppStorage("journal.mode") private var mode: JournalMode = .list

    var body: some View {
        Group {
            switch mode {
            case .list: EntriesList(projectID: nil, title: L("Журнал"))
            case .calendar: DayCalendarView()
            }
        }
        .toolbar {
            BareToolbarItem {
                TempoSegments(selection: $mode, items: JournalMode.allCases.map { .init(value: $0, title: L($0.rawValue)) })
            }
        }
    }
}

// MARK: - Расчёты

/// Что делает мышь с записью: двигает целиком или тянет за край.
struct CalendarDrag: Equatable {
    enum Kind { case move, top, bottom }
    let id: UUID
    let kind: Kind
    var offsetMinutes: Double
}

/// Запись на сетке дня: время обрезано границами дня, колонка нужна при наложении записей.
struct CalendarPlacement: Identifiable {
    let entry: Entry
    let start: Date
    let end: Date
    var column = 0
    var columns = 1
    var id: UUID { entry.id }
}

enum CalendarMath {
    static let snap = 5.0
    static let minimumMinutes = 5.0

    /// Запись можно таскать, только если она завершена и целиком лежит в этом дне.
    static func canDrag(_ entry: Entry, day: DateInterval) -> Bool {
        guard let end = entry.end else { return false }
        return entry.start >= day.start && end <= day.end
    }

    static func snapped(_ date: Date, day: DateInterval) -> Date {
        let minutes = date.timeIntervalSince(day.start) / 60
        return day.start.addingTimeInterval((minutes / snap).rounded() * snap * 60)
    }

    /// Высота зоны у края записи, за которую её можно растянуть.
    static let edge: CGFloat = 7

    /// Низкая запись: верхний край убирается первым, чтобы её всё ещё можно было схватить.
    static func grab(y: CGFloat, height: CGFloat) -> CalendarDrag.Kind {
        if height >= 12, y >= height - edge { return .bottom }
        if height >= 24, y <= edge { return .top }
        return .move
    }

    /// Записи дня и колонки: то, что пересекается по времени, встаёт рядом.
    static func place(_ entries: [Entry], day: DateInterval, now: Date) -> [CalendarPlacement] {
        var items = entries.compactMap { e -> CalendarPlacement? in
            let start = max(e.start, day.start)
            let end = min(e.end ?? now, day.end)
            guard end > start else { return nil }
            return CalendarPlacement(entry: e, start: start, end: end)
        }
        .sorted { $0.start == $1.start ? $0.end > $1.end : $0.start < $1.start }

        var i = 0
        while i < items.count {
            // Кластер: все записи, связанные пересечениями.
            var clusterEnd = items[i].end
            var j = i + 1
            while j < items.count, items[j].start < clusterEnd {
                clusterEnd = max(clusterEnd, items[j].end)
                j += 1
            }
            var columnEnds: [Date] = []
            for k in i ..< j {
                if let free = columnEnds.firstIndex(where: { $0 <= items[k].start }) {
                    items[k].column = free
                    columnEnds[free] = items[k].end
                } else {
                    items[k].column = columnEnds.count
                    columnEnds.append(items[k].end)
                }
            }
            for k in i ..< j { items[k].columns = columnEnds.count }
            i = j
        }
        return items
    }

    /// Запись после перетаскивания: время кратно пяти минутам и не выходит за границы дня.
    static func apply(_ drag: CalendarDrag, to entry: Entry, day: DateInterval) -> Entry {
        guard let end = entry.end else { return entry }
        var result = entry
        let delta = drag.offsetMinutes * 60
        let minSpan = minimumMinutes * 60 + entry.pausedTotal
        switch drag.kind {
        case .move:
            let span = end.timeIntervalSince(entry.start)
            var start = snapped(entry.start.addingTimeInterval(delta), day: day)
            if start < day.start { start = day.start }
            if start.addingTimeInterval(span) > day.end { start = day.end.addingTimeInterval(-span) }
            result.start = start
            result.end = start.addingTimeInterval(span)
        case .top:
            let start = snapped(entry.start.addingTimeInterval(delta), day: day)
            result.start = min(max(start, day.start), end.addingTimeInterval(-minSpan))
        case .bottom:
            let newEnd = snapped(end.addingTimeInterval(delta), day: day)
            result.end = max(min(newEnd, day.end), entry.start.addingTimeInterval(minSpan))
        }
        return result
    }
}

// MARK: - День

struct DayCalendarView: View {
    @EnvironmentObject var store: Store
    @State private var day: Date
    @AppStorage("journal.calendarZoom") private var zoom = 1
    @State private var editing: Entry?
    @State private var focusNote = false
    @State private var splitting: Entry?
    @State private var exporting = false

    private static let zoomLevels: [CGFloat] = [36, 54, 80, 120]

    /// Для снимков: запись, над которой будто бы стоит курсор.
    private let previewHover: UUID?

    init(day: Date = Date(), previewHover: UUID? = nil) {
        _day = State(initialValue: day)
        self.previewHover = previewHover
    }

    private var hourHeight: CGFloat {
        Self.zoomLevels[min(max(zoom, 0), Self.zoomLevels.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DayGrid(day: Cal.day(day), hourHeight: hourHeight, editing: $editing, focusNote: $focusNote, splitting: $splitting, hovered: previewHover)
        }
        .navigationTitle(L("Журнал"))
        .navigationSubtitle("")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { focusNote = false; editing = newEntry() } label: {
                    Label("Добавить запись", icon: "plus")
                }
                .help("Добавить запись вручную")
                Button { exporting = true } label: {
                    Label("Экспорт", icon: "upload")
                        .labelStyle(.titleAndIcon)
                }
                .help("Настроить и сохранить файл")
                .disabled(store.entries.isEmpty)
            }
        }
        .sheet(item: $editing) { e in
            Localized { EntryEditor(entry: e, isNew: !store.contains(e.id), focusNote: focusNote) }
        }
        .sheet(isPresented: $exporting) { Localized { ExportSheet(projectID: nil) } }
        .sheet(item: $splitting) { entry in Localized { SplitEntrySheet(entry: entry) } }
    }

    private var header: some View {
        let iv = Cal.day(day)
        let total = store.total(in: iv)
        return HStack(spacing: 10) {
            Text(verbatim: Fmt.dayTitle(day))
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .layoutPriority(1)
            // Подсказка уходит, если окно узкое: лучше без неё, чем с обрезанной.
            ViewThatFits(in: .horizontal) {
                Text(verbatim: total > 0 ? Fmt.short(total) : L("Протяните по сетке, чтобы добавить запись"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                Color.clear.frame(width: 0, height: 0)
            }
            Spacer(minLength: 8)
            iconButton("chevron-left", help: L("Предыдущий день")) { shift(-1) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Сегодня") { day = Date() }
                .disabled(iv.contains(Date()))
            iconButton("chevron-right", help: L("Следующий день")) { shift(1) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Divider().frame(height: 16)
            iconButton("minus", help: L("Мельче")) { zoom -= 1 }
                .disabled(zoom <= 0)
            iconButton("plus", help: L("Крупнее")) { zoom += 1 }
                .disabled(zoom >= Self.zoomLevels.count - 1)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(icon: icon, size: 13)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .help(help)
    }

    private func shift(_ n: Int) {
        day = Cal.ru.date(byAdding: .day, value: n, to: day) ?? day
    }

    /// Сегодня: последний час. В другой день: с девяти до десяти утра.
    private func newEntry() -> Entry {
        let iv = Cal.day(day)
        let now = Date()
        let end = iv.contains(now) ? now : iv.start.addingTimeInterval(10 * 3600)
        return Entry(title: "", projectID: store.draftProjectID, start: end.addingTimeInterval(-3600), end: end)
    }
}

// MARK: - Сетка

private struct DayGrid: View {
    let day: DateInterval
    let hourHeight: CGFloat
    @Binding var editing: Entry?
    @Binding var focusNote: Bool
    @Binding var splitting: Entry?
    @EnvironmentObject var store: Store
    @State private var drag: CalendarDrag?
    @State private var creating: (from: Double, to: Double)?
    @State var hovered: UUID?
    @State private var hoverWork: DispatchWorkItem?

    private let labelWidth: CGFloat = 52
    private let space = "calendarGrid"
    private var totalHeight: CGFloat { hourHeight * 24 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                TimelineView(.periodic(from: Date(), by: 30)) { context in
                    canvas(now: context.date)
                }
                .padding(.vertical, 12)
                .background(alignment: .top) { anchors.padding(.vertical, 12) }
            }
            .onAppear { scrollToStart(proxy) }
            .onChange(of: day) { scrollToStart(proxy) }
            .onChange(of: hourHeight) { scrollToStart(proxy) }
        }
    }

    /// Точки для прокрутки к нужному часу.
    private var anchors: some View {
        VStack(spacing: 0) {
            ForEach(0 ..< 24, id: \.self) { hour in
                Color.clear.frame(height: hourHeight).id(hour)
            }
        }
    }

    private func scrollToStart(_ proxy: ScrollViewProxy) {
        let inDay = store.entries.filter { $0.overlap(with: day) > 0 }
        let first: Int
        if day.contains(Date()) {
            first = max(Cal.ru.component(.hour, from: Date()) - 3, 0)
        } else if let earliest = inDay.map({ max($0.start, day.start) }).min() {
            first = max(Cal.ru.component(.hour, from: earliest) - 1, 0)
        } else {
            first = 8
        }
        DispatchQueue.main.async { proxy.scrollTo(first, anchor: .top) }
    }

    private func canvas(now: Date) -> some View {
        GeometryReader { geo in
            let placed = placements(now: now)
            let width = max(geo.size.width - labelWidth - 12, 40)

            ZStack(alignment: .topLeading) {
                hourLines
                background
                ForEach(placed) { p in
                    block(p, areaWidth: width)
                        .zIndex(drag?.id == p.id ? 1 : 0)
                }
                if let creating { ghost(creating, width: width) }
                if day.contains(now) { nowLine(now, width: width).zIndex(2) }
                if drag == nil, creating == nil, let p = placed.first(where: { $0.id == hovered }) {
                    let frame = blockFrame(p, areaWidth: width)
                    EntryHoverCard(entry: p.entry, now: now)
                        .frame(width: 230)
                        .offset(x: max(labelWidth, frame.maxX - 238), y: min(frame.minY + 6, totalHeight - 130))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(3)
                }
                if let drag, let p = placed.first(where: { $0.id == drag.id }) {
                    let frame = blockFrame(p, areaWidth: width)
                    timePill(p.start, p.end)
                        .offset(x: frame.minX + 6, y: max(frame.minY - 24, 0))
                        .allowsHitTesting(false)
                        .zIndex(3)
                }
            }
            .coordinateSpace(name: space)
        }
        .frame(height: totalHeight)
    }

    /// Колонки считаются по сохранённому времени: пока запись тащат, ширина не прыгает.
    private func placements(now: Date) -> [CalendarPlacement] {
        CalendarMath.place(store.entries, day: day, now: now).map { p in
            guard let drag, drag.id == p.id else { return p }
            let moved = CalendarMath.apply(drag, to: p.entry, day: day)
            return CalendarPlacement(entry: moved, start: moved.start, end: moved.end ?? p.end, column: p.column, columns: p.columns)
        }
    }

    private var hourLines: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0 ..< 25, id: \.self) { hour in
                let y = CGFloat(hour) * hourHeight
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                    .padding(.leading, labelWidth)
                    .offset(y: y)
                if hour < 24 {
                    Text(verbatim: String(format: "%02d:00", hour))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth - 8, alignment: .trailing)
                        .offset(y: y - 7)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Пустое место: протянуть, чтобы создать запись, или дважды щёлкнуть, чтобы создать на полчаса.
    private var background: some View {
        Color.clear
            .contentShape(Rectangle())
            .padding(.leading, labelWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(space))
                    .onChanged { value in
                        creating = (minutes(value.startLocation.y), minutes(value.location.y))
                    }
                    .onEnded { _ in finishCreating() }
            )
            .onTapGesture(count: 2, coordinateSpace: .named(space)) { location in
                let from = min(minutes(location.y), 23.5 * 60)
                creating = (from, from + 30)
                finishCreating()
            }
    }

    private func minutes(_ y: CGFloat) -> Double {
        let raw = Double(y / hourHeight) * 60
        return min(max((raw / CalendarMath.snap).rounded() * CalendarMath.snap, 0), 24 * 60)
    }

    private func finishCreating() {
        defer { creating = nil }
        guard let creating else { return }
        let from = min(creating.from, creating.to), to = max(creating.from, creating.to)
        guard to - from >= CalendarMath.minimumMinutes else { return }
        focusNote = false
        editing = Entry(title: "", projectID: store.draftProjectID,
                        start: day.start.addingTimeInterval(from * 60), end: day.start.addingTimeInterval(to * 60))
    }

    private func ghost(_ range: (from: Double, to: Double), width: CGFloat) -> some View {
        let from = min(range.from, range.to), to = max(range.from, range.to)
        let y = CGFloat(from / 60) * hourHeight, height = max(CGFloat((to - from) / 60) * hourHeight, 2)
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.accentColor.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .overlay(alignment: .topLeading) {
                if height >= 22 {
                    Text(verbatim: timeRange(day.start.addingTimeInterval(from * 60), day.start.addingTimeInterval(to * 60)))
                        .font(.caption)
                        .monospacedDigit()
                        .padding(5)
                }
            }
            .frame(width: width, height: height)
            .offset(x: labelWidth, y: y)
            .allowsHitTesting(false)
    }

    private func nowLine(_ now: Date, width: CGFloat) -> some View {
        let y = CGFloat(now.timeIntervalSince(day.start) / 3600) * hourHeight
        return ZStack(alignment: .leading) {
            Rectangle().fill(Color.red).frame(width: width + 4, height: 1.5)
            Circle().fill(Color.red).frame(width: 7, height: 7).offset(x: -3.5)
        }
        .offset(x: labelWidth - 2, y: y - 3)
        .frame(height: 7)
        .allowsHitTesting(false)
    }

    private func timeRange(_ a: Date, _ b: Date) -> String {
        "\(Fmt.hhmm.string(from: a)) – \(Fmt.hhmm.string(from: b))"
    }

    private func timePill(_ a: Date, _ b: Date) -> some View {
        Text(verbatim: timeRange(a, b))
            .font(.caption)
            .fontWeight(.medium)
            .monospacedDigit()
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
    }

    // MARK: Блок записи

    private func blockFrame(_ p: CalendarPlacement, areaWidth: CGFloat) -> CGRect {
        let y = CGFloat(p.start.timeIntervalSince(day.start) / 3600) * hourHeight
        let height = max(CGFloat(p.end.timeIntervalSince(p.start) / 3600) * hourHeight - 1, 5)
        let columnWidth = areaWidth / CGFloat(p.columns)
        return CGRect(x: labelWidth + CGFloat(p.column) * columnWidth, y: y, width: columnWidth - 2, height: height)
    }

    private func block(_ p: CalendarPlacement, areaWidth: CGFloat) -> some View {
        let frame = blockFrame(p, areaWidth: areaWidth)
        let original = store.entry(p.id) ?? p.entry
        let draggable = CalendarMath.canDrag(original, day: day) && !store.isClosed(original)
        return EntryBlock(placement: p, height: frame.height, width: frame.width, active: drag?.id == p.id || hovered == p.id)
            .contentShape(Rectangle())
            .onTapGesture {
                focusNote = false
                editing = original
            }
            .gesture(draggable ? dragGesture(original, frame: frame) : nil)
            .modifier(EdgeCursor(height: frame.height, enabled: draggable))
            .onHover { inside in setHover(inside ? p.id : nil, leaving: p.id) }
            .contextMenu {
                EntryContextMenu(entry: original, store: store,
                                 edit: { focusNote = false; editing = original },
                                 editNote: { focusNote = true; editing = original },
                                 split: { splitting = original })
            }
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
    }

    /// За что схватили, решается один раз: у края тянем край, в середине двигаем запись.
    private func dragGesture(_ entry: Entry, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(space))
            .onChanged { value in
                let kind = drag?.kind ?? CalendarMath.grab(y: value.startLocation.y - frame.minY, height: frame.height)
                drag = CalendarDrag(id: entry.id, kind: kind, offsetMinutes: Double(value.translation.height / hourHeight) * 60)
            }
            .onEnded { _ in commit(entry) }
    }

    private func commit(_ entry: Entry) {
        guard let current = drag else { return }
        drag = nil
        let moved = CalendarMath.apply(current, to: entry, day: day)
        guard moved != entry else { return }
        store.upsert(moved)
        store.offerUndo(L("Время записи изменено")) { [weak store] in store?.upsert(entry) }
    }

    /// Подсказка появляется с задержкой, чтобы не мигать, пока курсор идёт мимо.
    private func setHover(_ id: UUID?, leaving: UUID) {
        hoverWork?.cancel()
        guard let id else {
            if hovered == leaving { withAnimation(.easeOut(duration: 0.1)) { hovered = nil } }
            return
        }
        let work = DispatchWorkItem { withAnimation(.easeOut(duration: 0.12)) { hovered = id } }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

private struct EntryBlock: View {
    let placement: CalendarPlacement
    let height: CGFloat
    let width: CGFloat
    let active: Bool
    @EnvironmentObject var store: Store

    var body: some View {
        let entry = placement.entry
        let color = store.color(for: entry.projectID)
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(color).frame(width: 3)
            if height >= 16 {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        EmojiText(emoji: entry.emoji, text: entry.title.isEmpty ? store.name(for: entry.projectID) : entry.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if width > 170 {
                            Text(verbatim: Fmt.short(entry.duration(at: placement.end)))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    if height >= 50, !entry.title.isEmpty {
                        Text(store.name(for: entry.projectID))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if height >= 34 {
                        Text(verbatim: "\(Fmt.hhmm.string(from: placement.start)) – \(entry.isRunning ? L("сейчас") : Fmt.hhmm.string(from: placement.end))")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, height >= 26 ? 4 : 1)
            }
            Spacer(minLength: 0)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        // Сначала непрозрачная подложка: линии часов не должны идти поперёк текста.
        .background(color.opacity(active ? 0.36 : 0.24))
        .background(.notchPaper)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            if entry.isRunning {
                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(color.opacity(0.7))
            }
        }
    }
}

/// Карточка при наведении: начало, конец, длительность, сумма и комментарий.
private struct EntryHoverCard: View {
    let entry: Entry
    let now: Date
    @EnvironmentObject var store: Store
    @AppStorage("extra.rates") private var ratesOn = false

    var body: some View {
        let seconds = entry.duration(at: now)
        VStack(alignment: .leading, spacing: 6) {
            EmojiText(emoji: entry.emoji, text: entry.title.isEmpty ? L("Без описания") : entry.title)
                .fontWeight(.medium)
                .lineLimit(2)
            HStack(spacing: 6) {
                Circle().fill(store.color(for: entry.projectID)).frame(width: 7, height: 7)
                Text(store.name(for: entry.projectID)).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            row(L("Начало"), Fmt.hhmm.string(from: entry.start))
            row(L("Конец"), entry.end.map { Fmt.hhmm.string(from: $0) } ?? L("сейчас"))
            row(L("Длительность"), Fmt.short(seconds))
            if ratesOn, let amount = store.amount(for: entry.projectID, seconds: seconds) {
                row(L("Сумма"), Fmt.money(amount))
            }
            if !entry.note.isEmpty {
                Text(entry.note)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .font(.callout)
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(verbatim: title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(verbatim: value).monospacedDigit()
        }
    }
}

/// Курсор «вверх-вниз» над краем записи.
private struct EdgeCursor: ViewModifier {
    let height: CGFloat
    let enabled: Bool
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    set(enabled && CalendarMath.grab(y: location.y, height: height) != .move)
                case .ended:
                    set(false)
                }
            }
            .onDisappear { set(false) }
    }

    private func set(_ on: Bool) {
        guard on != pushed else { return }
        if on { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        pushed = on
    }
}
