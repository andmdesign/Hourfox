import Pow
import SwiftUI
import Vortex

private let spring = Animation.spring(response: 0.36, dampingFraction: 0.86)
/// Чуть «живее» — для появления крыльев при старте, как у Dynamic Island.
private let wobble = Animation.spring(response: 0.48, dampingFraction: 0.62)
/// Встраиваемая строка не едет через соседние: место раздвигает пружина, а сама строка только проявляется.
private let inlineRow = AnyTransition.asymmetric(
    insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.08)),
    removal: .opacity.animation(.easeOut(duration: 0.1))
)

// MARK: - Форма Notch

/// Чёрная форма с «вывернутыми» верхними углами, как у настоящего выреза.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// Панель под значком в строке меню: обычная скруглённая форма, без «вывернутых» углов.
    var isPanel = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        if isPanel { return Path(roundedRect: rect, cornerRadius: bottomRadius, style: .continuous) }
        let t = topRadius, b = min(bottomRadius, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Корень

struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    @EnvironmentObject var store: Store
    let controller: NotchController

    @Namespace private var dot
    @AppStorage(Aurora.key) private var aurora = false
    @AppStorage(GlassStyle.key) private var glass = false

    private var isRunning: Bool { store.running != nil }

    var body: some View {
        let shape = NotchShape(topRadius: model.expanded ? 12 : 6, bottomRadius: model.expanded ? 26 : 10, isPanel: model.menuBarMode)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if model.expanded {
                    ExpandedView(model: model, controller: controller, dot: dot)
                        .transition(BlurReplaceTransition(configuration: .downUp).combined(with: ScaleTransition(0.94, anchor: .top)))
                } else {
                    // Свёрнутый остров продолжает чёрный вырез экрана: он тёмный в любой теме.
                    CollapsedView(model: model, controller: controller, dot: dot)
                        .environment(\.colorScheme, .dark)
                        .transition(.blurReplace)
                }
            }
            .background { NotchBackground(shape: shape, glass: glass, expanded: model.expanded) }
            .overlay {
                if aurora && (model.expanded || isRunning) {
                    IntelligenceGlow(shape: shape, strength: model.expanded ? 1 : 0.85,
                                     scale: model.expanded ? 1 : 0.3, animated: model.expanded)
                        .id(model.expanded)
                        .transition(.opacity)
                }
            }
            .changeEffect(.shine(angle: .degrees(20), duration: 0.9), value: model.startPulse)
            .clipShape(shape)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { controller.shapeSizeChanged($0) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(spring, value: model.expanded)
        .animation(wobble, value: isRunning)
        .animation(spring, value: model.creatingProject)
        .animation(spring, value: model.commentingEntryID)
        .animation(spring, value: model.timeUp?.id)
        .animation(spring, value: model.dueTask?.id)
        .animation(spring, value: model.editingNoteID)
        .animation(spring, value: model.customTimer)
        .animation(spring, value: model.pickingEmoji)
        .animation(spring, value: model.dueFor)
        .animation(spring, value: model.pickingNewDue)
        .animation(spring, value: model.pickingNewEmoji)
        .animation(spring, value: store.undoOffer?.id)
    }
}

// MARK: - Свёрнутое состояние

struct CollapsedView: View {
    @ObservedObject var model: NotchModel
    @EnvironmentObject var store: Store
    let controller: NotchController
    let dot: Namespace.ID
    @AppStorage(Aurora.key) private var aurora = false

    var body: some View {
        HStack(spacing: 0) {
            if let r = store.running {
                HStack(spacing: 0) {
                    Group {
                        if r.isPaused {
                            Image(icon: "pause", size: 9)
                                .foregroundStyle(.notchInk.opacity(0.6))
                                .frame(width: 14)
                        } else if let e = r.emoji {
                            EmojiGlyph(e, size: 14)
                        } else if r.planned != nil {
                            CountdownRing(entry: r, color: store.color(for: r.projectID))
                        } else {
                            PulseDot(color: store.color(for: r.projectID))
                        }
                    }
                    .matchedGeometryEffect(id: "projectDot", in: dot)
                    // Едва заметный замок: закрыт — Notch не вылезает при наведении, только по щелчку.
                    Button {
                        withAnimation(.snappy) { model.locked.toggle() }
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    } label: {
                        Image(icon: model.locked ? "lock" : "lock-open", size: 10)
                            .foregroundStyle(.notchInk.opacity(model.locked ? 0.55 : 0.22))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.lockFrame = $0 }
                    .onDisappear { model.lockFrame = nil }
                    .padding(.leading, 6)
                    .help(model.locked ? L("Раскрывать при наведении") : L("Не раскрывать при наведении"))
                    Spacer(minLength: 0)
                }
                .padding(.leading, 18)
                .frame(width: model.wingWidth)
                .transition(.opacity)
            }
            Color.clear.frame(width: model.notchSize.width)
            if let r = store.running {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    // С таймером показываем, сколько осталось; без него — сколько прошло.
                    let value = r.remaining(at: ctx.date) ?? r.duration(at: ctx.date)
                    Text(Fmt.compact(value.rounded(.up)))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.notchInk.opacity(r.isPaused ? 0.4 : 1))
                        .lineLimit(1)
                        .fixedSize()
                        .contentTransition(.numericText(countsDown: r.planned != nil))
                        .animation(.snappy(duration: 0.35), value: Int(value))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 16)
                .frame(width: model.wingWidth)
                .transition(.opacity)
            }
        }
        .frame(height: model.notchSize.height)
        // С сиянием — на несколько точек ниже выреза, иначе нижняя кромка уходит под вырез.
        .padding(.bottom, aurora && model.hasNotch && store.running != nil ? NotchModel.glowLip : 0)
        .contentShape(Rectangle())
        .onTapGesture { controller.expand() }
    }
}

/// Кольцо, которое «убывает» по мере обратного отсчёта.
struct CountdownRing: View {
    let entry: Entry
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let planned = max(entry.planned ?? 1, 1)
            let left = (entry.remaining(at: ctx.date) ?? 0) / planned
            ZStack {
                Circle().stroke(color.opacity(0.25), lineWidth: 2.2)
                Circle()
                    .trim(from: 0, to: left)
                    .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: left)
            }
            .frame(width: 11, height: 11)
        }
    }
}

struct PulseDot: View {
    let color: Color
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

// MARK: - Раскрытая панель

struct ExpandedView: View {
    @ObservedObject var model: NotchModel
    @EnvironmentObject var store: Store
    let controller: NotchController
    let dot: Namespace.ID

    @State private var burst: StopBurst.Spec?
    @State private var projectShake = 0

    @FocusState private var titleFocused: Bool
    @FocusState private var projectFocused: Bool
    @FocusState private var noteFocused: Bool
    @FocusState private var commentFocused: Bool
    @State private var comment = ""
    @State private var newName = ""
    @State private var newColor: ProjectColor = .blue
    @State private var newRate = ""
    @AppStorage("extra.rates") private var ratesOn = false
    @AppStorage("notchTab") private var tab = "recent"
    @AppStorage("feature.recent") private var recentOn = true
    @AppStorage("feature.tasks") private var tasksOn = true
    @AppStorage("feature.notes") private var notesOn = true
    @AppStorage("feature.events") private var eventsOn = true
    @AppStorage("feature.today") private var todayOn = true
    @AppStorage("feature.comments") private var commentsOn = true
    @AppStorage("feature.countdown") private var countdownOn = true
    @AppStorage("extra.goal") private var goalOn = false
    @AppStorage("extra.smartInput") private var smartInputOn = false
    @AppStorage(ExtraKey.goalHours) private var goalHours = 6

    @AppStorage("notchTabOrder") private var tabOrder = "recent,tasks,notes"
    @State private var hoveredTab: String?
    @State private var draggingTab: String?
    @State private var dragGrab: CGFloat = 0      // где внутри вкладки схватили
    @State private var dragX: CGFloat = 0         // курсор в координатах ряда вкладок
    @State private var tabFrames: [String: CGRect] = [:]
    @State private var customMinutes = ""
    @FocusState private var customFocused: Bool

    /// Порядок вкладок, который пользователь задал перетаскиванием.
    private var orderedTabs: [String] {
        let all = ["recent", "tasks", "notes", "events"]
        let saved = tabOrder.split(separator: ",").map(String.init).filter { all.contains($0) }
        return saved + all.filter { !saved.contains($0) }
    }

    private var enabledTabs: [String] {
        orderedTabs.filter { ["recent": recentOn, "tasks": tasksOn, "notes": notesOn, "events": eventsOn && Feature.events.isAvailable][$0] ?? false }
    }

    private func tabTitle(_ id: String) -> String {
        switch id {
        case "tasks": store.openTasks.isEmpty ? L("Задачи") : "\(L("Задачи")) \(store.openTasks.count)"
        case "notes": L("Заметки")
        case "events": L("События")
        default: L("Недавние")
        }
    }

    /// Тянем вкладку: как только её центр проходит середину соседней, они меняются местами.
    private func dragTab(_ id: String, _ value: DragGesture.Value) {
        if draggingTab == nil {
            draggingTab = id
            dragGrab = value.startLocation.x - (tabFrames[id]?.minX ?? 0)
        }
        guard dragX != value.location.x else { return }
        dragX = value.location.x
        guard let width = tabFrames[id]?.width else { return }
        let center = dragX - dragGrab + width / 2
        var order = enabledTabs
        order.removeAll { $0 == id }
        let index = order.filter { (tabFrames[$0]?.midX ?? 0) < center }.count
        order.insert(id, at: index)
        guard order != enabledTabs else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        withAnimation(.snappy(duration: 0.22)) {
            tabOrder = (order + orderedTabs.filter { !order.contains($0) }).joined(separator: ",")
        }
    }

    /// Выбранная вкладка, а если её выключили — первая включённая.
    private var currentTab: String? {
        enabledTabs.contains(tab) ? tab : enabledTabs.first
    }

    private var titleBinding: Binding<String> {
        Binding(get: { store.currentTitle }, set: { store.currentTitle = $0 })
    }

    private var noteBinding: Binding<String> {
        Binding(get: { store.currentNote }, set: { store.currentNote = $0 })
    }

    var body: some View {
        fullBody
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let entry = model.timeUp {
                timeUpBanner(entry)
                    .transition(inlineRow)
            }
            if let task = model.dueTask {
                dueBanner(task)
                    .transition(inlineRow)
            }
            inputRow
            if smartInputOn {
                SmartInputBar { titleFocused = true }
            }
            if store.running != nil && commentsOn {
                runningNoteRow
                    .transition(inlineRow)
            }
            if let id = model.commentingEntryID, let entry = store.entry(id) {
                commentRow(entry)
                    .transition(inlineRow)
            }
            if model.customTimer {
                customTimerRow
                    .transition(inlineRow)
            }
            if model.pickingEmoji {
                emojiRow
                    .transition(inlineRow)
            }
            if model.creatingProject {
                newProjectRow
                    .transition(inlineRow)
            }
            if todayOn {
                TodayStrip()
            }
            if enabledTabs.count > 1 {
                tabs
            }
            switch currentTab {
            case "tasks": TasksSection(model: model, controller: controller)
            case "notes": NotesSection(model: model, controller: controller)
            case "events": EventsSection(controller: controller)
            case "recent": recents
            default: EmptyView()
            }
            if store.undoOffer != nil {
                UndoBar(style: .notch)
                    .transition(inlineRow)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .frame(width: model.expandedWidth, alignment: .leading)
    }

    // Строка на уровне выреза: слева «Сегодня», справа кнопки.
    private var header: some View {
        let side = (model.expandedWidth - 48 - model.notchSize.width) / 2
        return HStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: 6) {
                    let total = store.total(in: Cal.day(ctx.date), now: ctx.date)
                    let goal = TimeInterval(goalHours * 3600)
                    // С целью «Сегодня» не помещается рядом с вырезом: кольцо и «2 ч / 6 ч» и так понятны.
                    if goalOn {
                        GoalRing(progress: total / goal)
                    } else {
                        Text("Сегодня").foregroundStyle(.notchInk.opacity(0.45))
                    }
                    Text(Fmt.short(total))
                        .foregroundStyle(.notchInk.opacity(0.9))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: Int(total / 60))
                    if goalOn {
                        Text(verbatim: "/ \(Fmt.short(goal))").foregroundStyle(.notchInk.opacity(0.45))
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            }
            .frame(width: side, alignment: .leading)
            Color.clear.frame(width: model.notchSize.width)
            HStack(spacing: 4) {
                IconButton(symbol: "maximize-2", help: "Открыть окно") { controller.openJournal(.journal) }
                IconButton(symbol: "ellipsis", help: "Ещё") { controller.showMoreMenu() }
            }
            .frame(width: side, alignment: .trailing)
        }
        .frame(height: model.notchSize.height)
        // В панели под значком нет выреза: верхний отступ такой же, как боковые.
        .padding(.top, model.menuBarMode ? 10 : 0)
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            Button { withAnimation(.snappy) { model.pickingEmoji.toggle() } } label: {
                Group {
                    if let e = store.currentEmoji {
                        EmojiGlyph(e, size: 17)
                    } else {
                        Image(icon: "smile", size: 15)
                            .foregroundStyle(.notchInk.opacity(model.pickingEmoji ? 0.8 : 0.35))
                    }
                }
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .help("Эмодзи")
            .padding(.leading, -4)
            TextField("", text: titleBinding, prompt: Text("Чем вы заняты?").foregroundStyle(.notchInk.opacity(0.35)))
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(.notchInk)
                .focused($titleFocused)
                .onSubmit {
                    if store.running == nil {
                        start()
                    } else {
                        if smartInputOn { store.applySmartInputToRunning() }
                        titleFocused = false
                    }
                }
                // Tab выбирает первую подсказку.
                .onKeyPress(.tab) {
                    guard smartInputOn, let first = SmartInput.suggestions(for: store.currentTitle, projects: store.projects).first else { return .ignored }
                    store.accept(first)
                    return .handled
                }
            ProjectChip(project: store.project(store.currentProjectID), dot: dot) { controller.showProjectMenu() }
            if countdownOn {
                TimerChip(minutes: store.running == nil ? store.draftDuration.map { Int($0 / 60) } : nil,
                          active: store.running?.planned != nil || (store.running == nil && store.draftDuration != nil)) {
                    controller.showTimerMenu()
                }
            }
            if let r = store.running {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let value = r.remaining(at: ctx.date) ?? r.duration(at: ctx.date)
                    Text(Fmt.clock(value.rounded(.up)))
                        .font(.system(size: 14, weight: .medium).monospacedDigit())
                        .foregroundStyle(.notchInk.opacity(r.isPaused ? 0.35 : 0.85))
                        .fixedSize()
                        .contentTransition(.numericText(countsDown: r.planned != nil))
                        .animation(.snappy(duration: 0.35), value: Int(value))
                }
                .transition(.blurReplace)
            }
            if let r = store.running {
                PauseButton(paused: r.isPaused) { withAnimation(.snappy) { store.togglePause() } }
                    .transition(.scale(0.6).combined(with: .opacity))
            }
            StartStopButton(running: store.running != nil) {
                if store.running == nil { start() } else { stop() }
            }
            .overlay {
                if let burst {
                    StopBurst(spec: burst)
                        .id(burst.id)
                        .frame(width: 280, height: 260)
                        .allowsHitTesting(false)
                }
            }
        }
        .zIndex(1)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.notchInk.opacity(0.09)))
        .contextMenu {
            if store.running != nil && commentsOn {
                Button("Комментарий") {
                    controller.focusPanel()
                    DispatchQueue.main.async { noteFocused = true }
                }
                Divider()
            }
            if store.running != nil {
                Button("Удалить текущую запись", role: .destructive) { store.discardRunning() }
            }
        }
    }

    /// Комментарий к идущей записи — пишется прямо по ходу работы.
    private var runningNoteRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(icon: "message-square-text", size: 11)
                .foregroundStyle(.notchInk.opacity(0.35))
            TextField("", text: noteBinding, prompt: Text("Комментарий").foregroundStyle(.notchInk.opacity(0.3)), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.notchInk.opacity(0.8))
                .lineLimit(1 ... 3)
                .focused($noteFocused)
                .onSubmit { noteFocused = false }
        }
        .padding(.horizontal, 15)
        .padding(.top, -4)
    }

    /// Комментарий к уже завершённой записи (из меню по правому клику).
    private func commentRow(_ entry: Entry) -> some View {
        HStack(spacing: 10) {
            TextField("", text: $comment,
                      prompt: Text("Комментарий к «\(entry.title.isEmpty ? store.name(for: entry.projectID) : entry.title)»")
                          .foregroundStyle(.notchInk.opacity(0.35)),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.notchInk)
                .lineLimit(1 ... 4)
                .focused($commentFocused)
                .onSubmit { saveComment(entry.id) }
                .onExitCommand { model.commentingEntryID = nil }
            Button { saveComment(entry.id) } label: {
                Image(icon: "check", size: 11)
                    .foregroundStyle(.notchPaper)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.notchInk))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.notchInk.opacity(0.06)))
        .onAppear {
            comment = entry.note
            controller.focusPanel()
            DispatchQueue.main.async { commentFocused = true }
        }
    }

    private func saveComment(_ id: UUID) {
        store.setNote(comment, for: id)
        model.commentingEntryID = nil
    }

    private var newProjectRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                TextField("", text: $newName, prompt: Text("Название проекта").foregroundStyle(.notchInk.opacity(0.35)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.notchInk)
                    .focused($projectFocused)
                    .onSubmit(createProject)
                    .changeEffect(.shake(rate: .fast), value: projectShake)
                    .onExitCommand { model.creatingProject = false }
                if ratesOn {
                    TextField("", text: $newRate, prompt: Text("Ставка в час").foregroundStyle(.notchInk.opacity(0.35)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.notchInk)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 96)
                        .onSubmit(createProject)
                        .onExitCommand { model.creatingProject = false }
                }
                Button(action: createProject) {
                    Image(icon: "check", size: 11)
                        .foregroundStyle(.notchPaper)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.notchInk.opacity(newName.trimmed.isEmpty ? 0.3 : 1)))
                }
                .buttonStyle(.plain)
            }
            ProjectColorRow(selection: $newColor, side: 14, ring: AnyShapeStyle(.notchInk))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, -4)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.notchInk.opacity(0.06)))
        .onAppear {
            newName = ""
            newRate = ""
            newColor = store.nextColor()
            controller.focusPanel()
            DispatchQueue.main.async { projectFocused = true }
        }
        .onDisappear { ColorPanelBridge.close() }
    }

    @ViewBuilder private var recents: some View {
        let pins = store.visiblePins
        let items = store.recents(limit: 3)
        if items.isEmpty && pins.isEmpty {
            Text("Здесь появятся последние задачи")
                .font(.system(size: 12))
                .foregroundStyle(.notchInk.opacity(0.35))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(pins) { pin in
                    let recent = Recent(entryID: pin.id, title: pin.title, projectID: pin.projectID, note: "", emoji: pin.emoji)
                    RecentRow(recent: recent, pinned: true) {
                        store.start(title: pin.title, projectID: pin.projectID, emoji: pin.emoji)
                        controller.didStart()
                    }
                    .contextMenu {
                        Button("Начать") {
                            store.start(title: pin.title, projectID: pin.projectID, emoji: pin.emoji)
                            controller.didStart()
                        }
                        Button("Открепить") { withAnimation(.snappy) { store.unpin(title: pin.title, projectID: pin.projectID) } }
                    }
                }
                ForEach(items) { r in
                    RecentRow(recent: r) {
                        store.start(title: r.title, projectID: r.projectID, emoji: r.emoji)
                        controller.didStart()
                    }
                    .contextMenu {
                        Button("Продолжить") {
                            store.start(title: r.title, projectID: r.projectID, emoji: r.emoji)
                            controller.didStart()
                        }
                        if store.canPin {
                            Button("Закрепить") { withAnimation(.snappy) { store.pin(title: r.title, projectID: r.projectID, emoji: r.emoji) } }
                        }
                        if commentsOn {
                            Button(r.note.isEmpty ? L("Добавить комментарий") : L("Изменить комментарий")) {
                                model.commentingEntryID = r.entryID
                            }
                        }
                        Divider()
                        Button("Удалить запись", role: .destructive) { store.deleteEntry(r.entryID) }
                    }
                }
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 12) {
            ForEach(enabledTabs, id: \.self) { id in
                tabButton(tabTitle(id), id: id)
            }
            Spacer()
        }
        .coordinateSpace(name: "tabs")
        .padding(.leading, 8)
        .padding(.bottom, -6)
    }

    private func tabButton(_ title: String, id: String) -> some View {
        let dragging = draggingTab == id
        // Двигается только надпись внутри кнопки, а жест висит на неподвижной кнопке:
        // иначе сдвиг вкладки снова запускает жест и всё зацикливается.
        return Button { withAnimation(.snappy) { tab = id } } label: {
            // Вкладки меняются местами перетаскиванием: ручка на виду выглядела как меню.
            Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.notchInk.opacity(dragging || currentTab == id ? 0.85 : hoveredTab == id ? 0.6 : 0.35))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(.notchInk.opacity(dragging ? 0.14 : 0)))
            .padding(.horizontal, -6)
            .scaleEffect(dragging ? 1.06 : 1)
            .offset(x: dragging ? dragX - dragGrab - (tabFrames[id]?.minX ?? 0) : 0)
            .animation(.snappy(duration: 0.18), value: dragging)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("tabs")) } action: { frame in
            if tabFrames[id] != frame { tabFrames[id] = frame }
        }
        .zIndex(dragging ? 1 : 0)
        .simultaneousGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("tabs"))
                .onChanged { dragTab(id, $0) }
                .onEnded { _ in
                    withAnimation(.snappy(duration: 0.22)) { draggingTab = nil }
                }
        )
        .onHover { hoveredTab = $0 ? id : (hoveredTab == id ? nil : hoveredTab) }
        .help(L("Перетащите, чтобы поменять порядок"))
    }

    /// Выбор эмодзи для записи прямо в Notch: два ряда по 12 и «без эмодзи».
    private var emojiRow: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 2), count: 13), spacing: 2) {
            ForEach(WorkEmoji.all, id: \.self) { e in emojiCell(e) }
            emojiCell(nil)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.notchInk.opacity(0.07)))
        .onExitCommand { model.pickingEmoji = false }
    }

    private func emojiCell(_ e: String?) -> some View {
        let selected = store.currentEmoji == e && e != nil
        return Button {
            store.currentEmoji = e
            withAnimation(.snappy) { model.pickingEmoji = false }
        } label: {
            Group {
                if let e {
                    EmojiGlyph(e, size: 18)
                } else {
                    Image(icon: "ban", size: 13)
                        .foregroundStyle(.notchInk.opacity(0.45))
                }
            }
            .frame(width: 32, height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.notchInk.opacity(selected ? 0.18 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .help(e == nil ? L("Без эмодзи") : "")
    }

    /// Своё время таймера: «30», «90» или «1:30».
    private var customTimerRow: some View {
        HStack(spacing: 10) {
            Image(icon: "timer", size: 12)
                .foregroundStyle(.notchInk.opacity(0.45))
            TextField("", text: $customMinutes, prompt: Text("Минуты, например 30 или 1:30").foregroundStyle(.notchInk.opacity(0.35)))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.notchInk)
                .focused($customFocused)
                .onSubmit(applyCustomTimer)
                .onExitCommand { model.customTimer = false }
            Button(action: applyCustomTimer) {
                Image(icon: "check", size: 11)
                    .foregroundStyle(.notchPaper)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.notchInk.opacity(Self.parseMinutes(customMinutes) == nil ? 0.3 : 1)))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.notchInk.opacity(0.06)))
        .changeEffect(.shake(rate: .fast), value: projectShake)
        .onAppear {
            customMinutes = ""
            controller.focusPanel()
            DispatchQueue.main.async { customFocused = true }
        }
    }

    /// «45» → 45 минут, «1:30» → 90, «1.5» не принимаем. От 1 минуты до 12 часов.
    static func parseMinutes(_ s: String) -> Int? {
        let t = s.trimmed
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        let minutes: Int?
        if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0 ..< 60).contains(m) {
            minutes = h * 60 + m
        } else {
            minutes = Int(t)
        }
        guard let minutes, (1 ... 720).contains(minutes) else { return nil }
        return minutes
    }

    private func applyCustomTimer() {
        guard let m = Self.parseMinutes(customMinutes) else {
            projectShake += 1
            return
        }
        store.setTimer(m)
        model.customTimer = false
    }

    /// «Время вышло»: запись уже закрыта по таймеру, можно добавить ещё 5 минут.
    private func timeUpBanner(_ entry: Entry) -> some View {
        HStack(spacing: 12) {
            Image(icon: "bell", size: 14)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Время вышло")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.notchInk)
                Text(entry.title.isEmpty ? store.name(for: entry.projectID) : entry.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.notchInk.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                model.timeUp = nil
                store.start(title: entry.title, projectID: entry.projectID, planned: 5 * 60, emoji: entry.emoji)
                controller.didStart()
            } label: {
                Text("+5\u{00A0}мин")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.notchInk)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(.notchInk.opacity(0.12)))
            }
            .buttonStyle(PressScaleStyle())
            Button { controller.dismissTimeUp() } label: {
                Text("Готово")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.notchPaper)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(.notchInk))
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(.leading, 14)
        .padding(.trailing, 9)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.accentColor.opacity(0.16)))
    }

    /// Наступило время задачи: начать её или отложить.
    private func dueBanner(_ task: TodoTask) -> some View {
        HStack(spacing: 12) {
            Image(icon: "bell", size: 14)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Время задачи")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.notchInk)
                Text(verbatim: task.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.notchInk.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            IconButton(symbol: "x", help: "Закрыть") { controller.dismissDueTask() }
            Button {
                store.snoozeDue(task.id, minutes: 15)
                controller.dismissDueTask()
            } label: {
                Text("+15\u{00A0}мин")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.notchInk)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(.notchInk.opacity(0.12)))
            }
            .buttonStyle(PressScaleStyle())
            Button {
                model.dueTask = nil
                store.start(title: task.title, projectID: task.projectID, emoji: task.emoji)
                controller.didStart()
            } label: {
                Text("Начать")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.notchPaper)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(.notchInk))
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(.leading, 14)
        .padding(.trailing, 9)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.accentColor.opacity(0.16)))
    }

    private func start() {
        titleFocused = false
        store.start()
        controller.didStart()
    }

    /// Остановка: искры цвета проекта из кнопки.
    private func stop() {
        let color = store.nsColor(for: store.running?.projectID)
        store.stop()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        let spec = StopBurst.Spec(color: color)
        burst = spec
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            if burst?.id == spec.id { burst = nil }
        }
    }

    private func createProject() {
        let name = newName.trimmed
        guard !name.isEmpty else {
            projectShake += 1
            return
        }
        var p = store.addProject(name: name, color: newColor)
        if ratesOn, let rate = Project.parseRate(newRate) {
            p.rate = rate
            store.updateProject(p)
        }
        store.currentProjectID = p.id
        model.creatingProject = false
        titleFocused = true
    }
}

// MARK: - Элементы панели

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(icon: symbol, size: 12)
                .foregroundStyle(.notchInk.opacity(hover ? 0.95 : 0.6))
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.notchInk.opacity(hover ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L(help))
        .onHover { hover = $0 }
    }
}

struct ProjectChip: View {
    let project: Project?
    let dot: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let project {
                    Circle().fill(project.color.color).frame(width: 7, height: 7)
                        .matchedGeometryEffect(id: "projectDot", in: dot)
                } else {
                    Circle().strokeBorder(.notchInk.opacity(0.45), lineWidth: 1).frame(width: 7, height: 7)
                }
                EmojiText(emoji: project?.emoji, text: project?.name ?? L("Проект"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(icon: "chevron-right", size: 8)
                    .rotationEffect(.degrees(90))
                    .opacity(0.5)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.notchInk.opacity(project == nil ? 0.55 : 0.9))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .frame(maxWidth: 130)
            .background(Capsule().fill(.notchInk.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct StartStopButton: View {
    let running: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(icon: running ? "square" : "play", size: 12)
                .foregroundStyle(running ? AnyShapeStyle(Color.white) : AnyShapeStyle(.notchPaper))
                .frame(width: 32, height: 32)
                .background(Circle().fill(running ? AnyShapeStyle(Color(nsColor: .systemRed)) : AnyShapeStyle(.notchInk)))
                .contentShape(Circle())
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: running)
        }
        .buttonStyle(PressScaleStyle())
        .help(running ? L("Остановить") : L("Запустить"))
    }
}

/// Пауза: время замирает, запись та же — «Продолжить» считает дальше.
struct PauseButton: View {
    let paused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(icon: paused ? "play" : "pause", size: 12)
                .foregroundStyle(.notchInk)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.notchInk.opacity(paused ? 0.22 : 0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .help(paused ? L("Продолжить") : L("Пауза"))
    }
}

struct RecentRow: View {
    let recent: Recent
    var pinned = false
    let action: () -> Void
    @EnvironmentObject var store: Store
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle().fill(store.color(for: recent.projectID)).frame(width: 7, height: 7)
                EmojiText(emoji: recent.emoji, text: recent.title.isEmpty ? store.name(for: recent.projectID) : recent.title)
                    .foregroundStyle(.notchInk.opacity(0.85))
                    .lineLimit(1)
                if !recent.title.isEmpty, let p = store.project(recent.projectID) {
                    EmojiText(emoji: p.emoji, text: p.name)
                        .foregroundStyle(.notchInk.opacity(0.4))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if pinned {
                    Image(icon: "bookmark", size: 11)
                        .foregroundStyle(.notchInk.opacity(0.45))
                        .help("Закреплено")
                }
                if !recent.note.isEmpty {
                    Image(icon: "message-square-text", size: 10)
                        .foregroundStyle(.notchInk.opacity(0.35))
                        .help(recent.note)
                }
                Image(icon: "play", size: 9)
                    .foregroundStyle(.notchInk.opacity(hover ? 0.9 : 0.3))
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.notchInk.opacity(hover ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Полоска распределения времени за сегодня.
struct TodayStrip: View {
    @EnvironmentObject var store: Store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let totals = store.totals(in: Cal.day(ctx.date), now: ctx.date)
            if !totals.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    StackedBar(totals: totals, spacing: 2)
                        .frame(height: 5)
                    HStack(spacing: 14) {
                        ForEach(totals.prefix(3)) { t in
                            HStack(spacing: 5) {
                                Circle().fill(store.color(for: t.projectID)).frame(width: 6, height: 6)
                                Text(store.name(for: t.projectID))
                                    .foregroundStyle(.notchInk.opacity(0.7))
                                    .lineLimit(1)
                                Text(Fmt.short(t.seconds))
                                    .foregroundStyle(.notchInk.opacity(0.4))
                                    .fixedSize()
                            }
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

struct StackedBar: View {
    let totals: [ProjectTotal]
    var spacing: CGFloat = 2
    @EnvironmentObject var store: Store

    var body: some View {
        GeometryReader { g in
            let sum = max(1, totals.reduce(0) { $0 + $1.seconds })
            let usable = g.size.width - spacing * CGFloat(max(0, totals.count - 1))
            HStack(spacing: spacing) {
                ForEach(totals) { t in
                    Capsule()
                        .fill(store.color(for: t.projectID))
                        .frame(width: max(g.size.height, usable * t.seconds / sum))
                }
            }
        }
    }
}

/// Кнопка чуть «проседает» под пальцем.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Короткий залп конфетти цвета проекта. Живёт ~3 секунды, потом убирается,
/// чтобы Vortex не крутил кадры впустую.
struct StopBurst: View {
    struct Spec: Equatable {
        let id = UUID()
        let color: NSColor
    }

    let spec: Spec

    var body: some View {
        VortexViewReader { proxy in
            VortexView(system) {
                RoundedRectangle(cornerRadius: 1.5).fill(.white).frame(width: 9, height: 5).tag("confetti")
                Circle().fill(.white).frame(width: 6, height: 6).tag("confetti")
            }
            .onAppear {
                DispatchQueue.main.async { proxy.burst() }
            }
        }
    }

    private var system: VortexSystem {
        func vc(_ c: NSColor, _ a: Double = 1) -> VortexSystem.Color {
            let c = c.usingColorSpace(.sRGB) ?? c
            return VortexSystem.Color(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, opacity: a)
        }
        let s = VortexSystem(
            tags: ["confetti"],
            position: [0.5, 0.5],
            birthRate: 0,
            burstCount: 46,
            burstCountVariation: 10,
            lifespan: 2.2,
            speed: 0.55,
            speedVariation: 0.35,
            angleRange: .degrees(110),
            acceleration: [0, 0.9],
            angularSpeedVariation: [3, 3, 3],
            colors: .random(vc(spec.color), vc(spec.color, 0.75), vc(.white, 0.9)),
            size: 0.6,
            sizeVariation: 0.4
        )
        return s
    }
}

/// Кнопка таймера рядом с проектом: иконка и выбранная длительность.
struct TimerChip: View {
    let minutes: Int?
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(icon: "timer", size: 11)
                if let minutes {
                    Text(Fmt.minutes(minutes)).lineLimit(1)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.notchInk.opacity(active ? 0.9 : 0.45))
            .padding(.horizontal, minutes == nil ? 7 : 9)
            .frame(height: 26)
            .background(Capsule().fill(.notchInk.opacity(active ? 0.14 : 0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Таймер")
    }
}

// MARK: - Задачи в Notch

struct TasksSection: View {
    @ObservedObject var model: NotchModel
    let controller: NotchController
    @EnvironmentObject var store: Store
    @AppStorage("extra.dueDates") private var dueOn = false
    @State private var newTask = ""
    @State private var newDue: Date?
    @State private var newDueMinutes: Int?
    @State private var newPriority = 0
    @State private var newRowHover = false
    @State private var newEmoji: String?
    /// Проект новой задачи; пока его не выбрали сами, берётся текущий.
    @State private var newProject: UUID??
    @FocusState private var adding: Bool

    private var newProjectID: UUID? { newProject ?? store.currentProjectID }

    var body: some View {
        let open = store.openTasks
        VStack(alignment: .leading, spacing: 1) {
            // Все задачи на месте: больше пяти строк список прокручивается, а не прячет хвост в журнал.
            NotchScrollList(count: open.count, visible: model.dueFor == nil ? 5 : 2) {
            ForEach(open) { t in
                TaskRow(task: t, pickingDue: model.dueFor == t.id) {
                    store.start(title: t.title, projectID: t.projectID, emoji: t.emoji)
                    controller.didStart()
                } pickProject: {
                    controller.showProjectMenu(for: t)
                } pickDue: {
                    toggleDue(t.id)
                }
                .contextMenu {
                    Button("Начать") {
                        store.start(title: t.title, projectID: t.projectID, emoji: t.emoji)
                        controller.didStart()
                    }
                    TaskProjectMenu(task: t)
                    PriorityPicker(task: t)
                    if dueOn { Button("Срок") { toggleDue(t.id) } }
                    EmojiMenu(task: t)
                    Divider()
                    Button("Удалить", role: .destructive) { store.deleteTask(t.id) }
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            }
            // Календарь срока под списком, а не внутри: у прокручиваемого списка постоянная высота.
            if dueOn, let id = model.dueFor, let t = open.first(where: { $0.id == id }) {
                calendar(t.due, t.dueMinutes) { date, minutes in
                    store.setDue(date, minutes: minutes, for: t.id)
                } onDone: {
                    withAnimation(.snappy) { model.dueFor = nil }
                }
            }
            HStack(spacing: 9) {
                Image(icon: "plus", size: 10)
                    .foregroundStyle(.notchInk.opacity(0.35))
                    .frame(width: 14)
                TextField("", text: $newTask, prompt: Text("Новая задача").foregroundStyle(.notchInk.opacity(0.3)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.notchInk)
                    .focused($adding)
                    .onSubmit {
                        withAnimation(.snappy) {
                            store.addTask(newTask, projectID: newProjectID, due: newDue, dueMinutes: newDueMinutes, priority: newPriority, emoji: newEmoji)
                        }
                        if !newTask.trimmed.isEmpty {
                            newDue = nil
                            newDueMinutes = nil
                            newPriority = 0
                            newEmoji = nil
                        }
                        newTask = ""
                        adding = true
                    }
                if newRowHover || adding || !newTask.isEmpty || newPriority > 0 || newEmoji != nil || newDue != nil
                    || newProject != nil || model.pickingNewEmoji || model.pickingNewDue {
                Button {
                    controller.showPriorityMenu(current: newPriority) { newPriority = $0 }
                } label: {
                    TaskCheckmark(priority: newPriority, done: false, side: 13, ink: AnyShapeStyle(.notchInk.opacity(0.35)), doneColor: .clear)
                        .frame(width: 20, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Приоритет")
                Button {
                    withAnimation(.snappy) {
                        model.pickingNewEmoji.toggle()
                        model.pickingNewDue = false
                        model.dueFor = nil
                    }
                } label: {
                    Group {
                        if let newEmoji {
                            EmojiGlyph(newEmoji, size: 14)
                        } else {
                            Image(icon: "smile", size: 13)
                                .foregroundStyle(.notchInk.opacity(model.pickingNewEmoji ? 0.9 : 0.4))
                        }
                    }
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Эмодзи")
                Button {
                    controller.showProjectMenu(current: newProjectID) { newProject = .some($0) }
                } label: {
                    HStack(spacing: 5) {
                        if let p = store.project(newProjectID) {
                            Circle().fill(p.color.color).frame(width: 6, height: 6)
                            Text(verbatim: p.name)
                        } else {
                            Text("Проект")
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.notchInk.opacity(newProjectID == nil ? 0.4 : 0.75))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .frame(maxWidth: 110)
                    .background(Capsule().fill(.notchInk.opacity(0.08)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Проект")
                if dueOn {
                    Button {
                        withAnimation(.snappy) {
                            model.pickingNewDue.toggle()
                            model.pickingNewEmoji = false
                            model.dueFor = nil
                        }
                    } label: {
                        DueLabel(due: newDue, minutes: newDueMinutes, active: model.pickingNewDue)
                    }
                    .buttonStyle(.plain)
                    .help("Срок")
                }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
            .onHover { newRowHover = $0 }
            .onTapGesture {
                controller.focusPanel()
                adding = true
            }
            if model.pickingNewEmoji {
                EmojiGrid(selection: Binding(get: { newEmoji }, set: { value in
                    newEmoji = value
                    withAnimation(.snappy) { model.pickingNewEmoji = false }
                    adding = true
                }))
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.notchInk.opacity(0.06)))
                .padding(.vertical, 4)
                .transition(inlineRow)
            }
            if dueOn, model.pickingNewDue {
                calendar(newDue, newDueMinutes) { date, minutes in
                    newDue = date
                    newDueMinutes = minutes
                } onDone: {
                    withAnimation(.snappy) { model.pickingNewDue = false }
                    adding = true
                }
            }
        }
    }

    private func toggleDue(_ id: UUID) {
        withAnimation(.snappy) {
            model.dueFor = model.dueFor == id ? nil : id
            model.pickingNewDue = false
            model.pickingNewEmoji = false
        }
    }

    private func calendar(_ date: Date?, _ minutes: Int?, onChange: @escaping (Date?, Int?) -> Void, onDone: @escaping () -> Void) -> some View {
        DuePicker(date: date, minutes: minutes, onChange: onChange, onDone: onDone)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.notchInk.opacity(0.06)))
            .padding(.vertical, 4)
            .transition(inlineRow)
    }
}

struct TaskRow: View {
    let task: TodoTask
    var pickingDue = false
    let start: () -> Void
    let pickProject: () -> Void
    let pickDue: () -> Void
    @EnvironmentObject var store: Store
    @AppStorage("extra.dueDates") private var dueOn = false
    @State private var hover = false
    @State private var checked = false

    var body: some View {
        HStack(spacing: 5) {
            Button {
                withAnimation(.snappy) { checked = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    withAnimation(.snappy) { store.toggleTask(task.id) }
                }
            } label: {
                TaskCheckmark(priority: task.priority, done: checked, side: 14, ink: AnyShapeStyle(.notchInk.opacity(0.4)), doneColor: store.color(for: task.projectID))
                    .frame(width: 22, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: start) {
                EmojiText(emoji: task.emoji, text: task.title)
                    .foregroundStyle(.notchInk.opacity(checked ? 0.4 : 0.85))
                    .strikethrough(checked)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            // Проект выбирается прямо в строке; без проекта подпись появляется при наведении.
            Button(action: pickProject) {
                Group {
                    if let p = store.project(task.projectID) {
                        EmojiText(emoji: p.emoji, text: p.name)
                            .foregroundStyle(.notchInk.opacity(hover ? 0.6 : 0.4))
                    } else {
                        Text("Проект")
                            .foregroundStyle(.notchInk.opacity(hover ? 0.35 : 0))
                    }
                }
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Проект")
            // Пустое место и треугольник запускают задачу, как и раньше.
            Button(action: start) {
                Color.clear.frame(maxWidth: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if dueOn, task.due != nil || hover || pickingDue {
                Button(action: pickDue) {
                    DueLabel(due: task.due, minutes: task.dueMinutes, active: pickingDue)
                }
                .buttonStyle(.plain)
                .help("Срок")
            }
            Button(action: start) {
                Image(icon: "play", size: 9)
                    .foregroundStyle(.notchInk.opacity(hover ? 0.9 : 0.3))
                    .frame(width: 14, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 13))
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.notchInk.opacity(hover ? 0.07 : 0)))
        .onHover { hover = $0 }
    }
}

/// Срок в Notch: дата или значок календаря, если срока ещё нет.
struct DueLabel: View {
    let due: Date?
    var minutes: Int?
    let active: Bool

    var body: some View {
        Group {
            if let due {
                Text(verbatim: DueDate.text(due, minutes: minutes))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DueDate.isOverdue(due, minutes: minutes) ? AnyShapeStyle(Color(nsColor: .systemRed)) : AnyShapeStyle(.notchInk.opacity(active ? 0.9 : 0.5)))
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Image(icon: "calendar", size: 12)
                    .foregroundStyle(.notchInk.opacity(active ? 0.9 : 0.4))
            }
        }
        .frame(minWidth: 16, minHeight: 24)
        .contentShape(Rectangle())
    }
}

/// Подменю «Эмодзи» для правого клика по задаче в Notch (там нет места под сетку).
struct EmojiMenu: View {
    let task: TodoTask
    @EnvironmentObject var store: Store

    var body: some View {
        Menu("Эмодзи") {
            Picker("Эмодзи", selection: Binding(get: { task.emoji ?? "" }, set: { e in
                var t = task
                t.emoji = e.isEmpty ? nil : e
                store.updateTask(t)
            })) {
                Text("Без эмодзи").tag("")
                ForEach(WorkEmoji.all, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
        }
    }
}

/// Сетка эмодзи 8×3 и кнопка «Без эмодзи» — для задач и проектов в журнале.
struct EmojiGrid: View {
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            grid(WorkEmoji.all)
            Button { selection = nil } label: {
                Label("Без эмодзи", icon: "ban")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(selection == nil)
            .opacity(selection == nil ? 0.4 : 1)
        }
    }

    private func grid(_ items: [String]) -> some View {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 4), count: 8), spacing: 4) {
                ForEach(items, id: \.self) { e in
                    Button { selection = selection == e ? nil : e } label: {
                        EmojiGlyph(e, size: 19)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selection == e ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.0001)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .fixedSize()
    }
}

/// Кружок выполнения задачи: его цвет и есть приоритет. Без приоритета он нейтральный.
struct TaskCheckmark: View {
    let priority: Int
    let done: Bool
    let side: CGFloat
    let ink: AnyShapeStyle
    let doneColor: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flash = false

    private var tint: Color { priority > 0 ? Priority.color(priority) : doneColor }

    var body: some View {
        ZStack {
            if !done {
                if priority > 0 {
                    Circle()
                        .fill(Priority.color(priority).opacity(0.18))
                        .overlay(Circle().strokeBorder(Priority.color(priority), lineWidth: 1.5))
                        .accessibilityLabel(L(Priority.titles[priority] ?? ""))
                } else {
                    Circle().strokeBorder(ink, lineWidth: 1.5)
                }
            } else {
                Circle()
                    .fill(tint)
                    .overlay {
                        Image(icon: "check", size: side * 0.72)
                            .foregroundStyle(Color.white)
                    }
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.55).combined(with: .opacity))
            }
            // Вспышка: кольцо расходится и гаснет. На размер строки не влияет.
            Circle()
                .stroke(tint, lineWidth: 1.5)
                .scaleEffect(flash ? 1.9 : 1)
                .opacity(flash ? 0 : (done && !reduceMotion ? 0.7 : 0))
                .allowsHitTesting(false)
        }
        .frame(width: side, height: side)
        .onChange(of: done) {
            flash = false
            guard done else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            if !reduceMotion { withAnimation(.easeOut(duration: 0.38)) { flash = true } }
        }
        .onAppear { if done { flash = true } }
    }
}

/// Один эмодзи нужного размера.
struct EmojiGlyph: View {
    let emoji: String
    let size: CGFloat

    init(_ emoji: String, size: CGFloat) {
        self.emoji = emoji
        self.size = size
    }

    var body: some View {
        Text(verbatim: emoji).font(.system(size: size))
    }
}

/// Название с эмодзи впереди.
struct EmojiText: View {
    let emoji: String?
    let text: String

    var body: some View {
        Text(verbatim: emoji.map { "\($0) \(text)" } ?? text)
    }
}

/// Подменю «Приоритет» с галочкой у текущего — для правого клика по задаче.
struct PriorityPicker: View {
    let task: TodoTask
    @EnvironmentObject var store: Store

    var body: some View {
        Picker("Приоритет", selection: Binding(get: { task.priority }, set: { p in
            withAnimation(.snappy) { store.setPriority(p, for: task.id) }
        })) {
            ForEach([3, 2, 1, 0], id: \.self) { p in
                Label {
                    Text(L(Priority.titles[p]!))
                } icon: {
                    Image(nsImage: Priority.menuImage(p)).renderingMode(.original)
                }
                .tag(p)
            }
        }
    }
}

// MARK: - Заметки в Notch

/// Список в Notch: до пяти строк во всю высоту, дальше прокрутка. Нижний край гаснет, чтобы было видно продолжение.
struct NotchScrollList<Content: View>: View {
    let count: Int
    /// Пока под списком открыт календарь, строк меньше: Notch не должен вырасти выше экрана.
    var visible = 5
    /// Для снимков: список сразу прокручен до конца.
    var startAtBottom = false
    @ViewBuilder let content: () -> Content

    private static var row: CGFloat { 29 }
    /// Пустое место после последней строки и высота затухания: затухание всегда меньше запаса.
    private static var tail: CGFloat { 22 }
    private static var fade: CGFloat { 14 }
    private var height: CGFloat { Self.row * (CGFloat(visible) + 0.5) }

    var body: some View {
        if count > visible {
            // Внизу запас: в конце прокрутки последняя строка стоит целиком над затуханием.
            ScrollView {
                VStack(alignment: .leading, spacing: 1) { content() }
                    .padding(.bottom, Self.tail)
            }
            .scrollIndicators(.automatic)
            .defaultScrollAnchor(startAtBottom ? .bottom : .top)
            .frame(height: height)
            .mask(LinearGradient(stops: [.init(color: .black, location: 1 - Self.fade / height), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        } else {
            VStack(alignment: .leading, spacing: 1) { content() }
        }
    }
}

struct NotesSection: View {
    @ObservedObject var model: NotchModel
    let controller: NotchController
    @EnvironmentObject var store: Store
    @State private var newNote = ""
    @FocusState private var adding: Bool
    @FocusState private var editing: Bool

    var body: some View {
        let notes = store.sortedNotes
        VStack(alignment: .leading, spacing: 1) {
            NotchScrollList(count: notes.count) {
            ForEach(notes) { n in
                if model.editingNoteID == n.id {
                    editor(n)
                } else {
                    NoteRow(note: n) { open(n.id) }
                        .contextMenu {
                            Button("Изменить") { open(n.id) }
                            Button("Скопировать") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(n.text, forType: .string)
                            }
                            Divider()
                            Button("Удалить", role: .destructive) { withAnimation(.snappy) { store.deleteNote(n.id) } }
                        }
                }
            }
            }
            HStack(spacing: 9) {
                Image(icon: "plus", size: 10)
                    .foregroundStyle(.notchInk.opacity(0.35))
                    .frame(width: 14)
                TextField("", text: $newNote, prompt: Text("Новая заметка").foregroundStyle(.notchInk.opacity(0.3)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.notchInk)
                    .focused($adding)
                    .onSubmit {
                        guard !newNote.trimmed.isEmpty else { return }
                        withAnimation(.snappy) { _ = store.addNote(newNote.trimmed) }
                        newNote = ""
                        adding = true
                    }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .onTapGesture {
                controller.focusPanel()
                adding = true
            }
        }
    }

    private func open(_ id: UUID) {
        model.editingNoteID = id
        controller.focusPanel()
        DispatchQueue.main.async { editing = true }
    }

    private func close() {
        model.editingNoteID = nil
        withAnimation(.snappy) { store.dropEmptyNotes() }
    }

    /// Правка заметки прямо в Notch: Enter — новая строка через ⌥, ⌘Enter или ✓ — готово.
    private func editor(_ n: Note) -> some View {
        HStack(alignment: .top, spacing: 10) {
            TextField("", text: Binding(get: { store.note(n.id)?.text ?? "" }, set: { store.updateNote(n.id, text: $0) }),
                      prompt: Text("Заметка").foregroundStyle(.notchInk.opacity(0.3)), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.notchInk)
                .lineLimit(2 ... 8)
                .focused($editing)
                .onSubmit(close)
                .onExitCommand(perform: close)
            Button(action: close) {
                Image(icon: "check", size: 11)
                    .foregroundStyle(.notchPaper)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.notchInk))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.notchInk.opacity(0.06)))
        .transition(.opacity)
    }
}

struct NoteRow: View {
    let note: Note
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(icon: "sticky-note", size: 11)
                    .foregroundStyle(.notchInk.opacity(0.4))
                    .frame(width: 14)
                Text(note.title)
                    .foregroundStyle(.notchInk.opacity(0.85))
                    .lineLimit(1)
                if !note.preview.isEmpty {
                    Text(note.preview)
                        .foregroundStyle(.notchInk.opacity(0.4))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(Fmt.noteDate(note.updated))
                    .font(.system(size: 11))
                    .foregroundStyle(.notchInk.opacity(0.35))
                    .monospacedDigit()
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.notchInk.opacity(hover ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
