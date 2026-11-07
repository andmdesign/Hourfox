import AppKit
import Charts
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case journal, tasks, notes, report, settings, archive
    case project(UUID)
}

final class JournalNav: ObservableObject {
    @Published var selection: SidebarItem? = .journal
}

// MARK: - Окно

final class JournalWindowController: NSObject, NSWindowDelegate {
    let store: Store
    let nav = JournalNav()
    private var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    init(store: Store) {
        self.store = store
        super.init()
        // Заголовок окна: «Журнал», «Отчёт» или имя проекта.
        nav.$selection.combineLatest(store.$projects, AppLanguage.shared.$code)
            .sink { [weak self] selection, projects, _ in
                DispatchQueue.main.async {
                    self?.window?.title = switch selection ?? .journal {
                    case .journal: L("Журнал")
                    case .tasks: L("Задачи")
                    case .notes: L("Заметки")
                    case .settings: L("Настройки")
                    case .report: L("Отчёт")
                    case .archive: L("Архив")
                    case .project(let id): projects.first { $0.id == id }?.label ?? L("Проект")
                    }
                }
            }
            .store(in: &cancellables)
    }

    func show(_ item: SidebarItem? = nil) {
        if let item { nav.selection = item }
        if window == nil {
            let root = Localized {
                JournalView(nav: nav)
                    .environmentObject(store)
            }
            let hc = NSHostingController(rootView: root)
            hc.sceneBridgingOptions = [.toolbars, .title]
            hc.sizingOptions = [.minSize]
            let w = NSWindow(contentViewController: hc)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(NSSize(width: 940, height: 640))
            w.center()
            w.setFrameAutosaveName("Journal")
            window = w
            nav.selection = nav.selection
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Без открытого журнала приложение живёт только в Notch — без иконки в Dock.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Корень журнала

struct JournalView: View {
    @ObservedObject var nav: JournalNav
    @EnvironmentObject var store: Store
    @State private var creatingProject = false
    @AppStorage("feature.tasks") private var tasksOn = true
    @AppStorage("feature.notes") private var notesOn = true

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.selection) {
                Label("Журнал", icon: "list").tag(SidebarItem.journal)
                if tasksOn {
                    Label("Задачи", icon: "list-checks").tag(SidebarItem.tasks)
                }
                if notesOn {
                    Label("Заметки", icon: "sticky-note").tag(SidebarItem.notes)
                }
                Label("Отчёт", icon: "chart-column").tag(SidebarItem.report)
                Section("Проекты") {
                    ForEach(store.activeProjects) { sidebarRow($0) }
                    Button { creatingProject = true } label: {
                        Label("Новый проект", icon: "plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Section {
                    Label("Архив", icon: "archive").tag(SidebarItem.archive)
                    Label("Настройки", icon: "settings").tag(SidebarItem.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            switch nav.selection ?? .journal {
            case .journal:
                JournalPage()
            case .tasks:
                TasksView()
            case .notes:
                NotesView()
            case .settings:
                SettingsView()
            case .report:
                ReportView()
            case .archive:
                ArchiveView(nav: nav)
            case .project(let id):
                ProjectDetail(id: id, nav: nav)
            }
        }
        .sheet(isPresented: $creatingProject) {
            Localized {
            ProjectEditor(existing: nil) { p in nav.selection = .project(p.id) }
            }
        }
        // Панель инструментов нужна всегда: без неё у разделов без кнопок (например, «Настройки»)
        // сайдбар не доходит до верха окна, и кнопки окна оказываются над ним.
        .toolbar {
            if #available(macOS 26, *) {
                ToolbarItem(placement: .automatic) { Color.clear.frame(width: 1, height: 1) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .automatic) { Color.clear.frame(width: 1, height: 1) }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        // Выключенный раздел не может оставаться открытым.
        .onChange(of: tasksOn) { if !tasksOn && nav.selection == .tasks { nav.selection = .journal } }
        .onChange(of: notesOn) { if !notesOn && nav.selection == .notes { nav.selection = .journal } }
        .overlay(alignment: .bottom) {
            if store.undoOffer != nil {
                UndoBar(style: .window)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: store.undoOffer?.id)
    }

    private func sidebarRow(_ p: Project) -> some View {
        Label {
            EmojiText(emoji: p.emoji, text: p.name)
        } icon: {
            Circle().fill(p.color.color).frame(width: 9, height: 9)
        }
        .tag(SidebarItem.project(p.id))
        .contextMenu {
            Button(p.isArchived ? L("Вернуть из архива") : L("В архив")) { store.setArchived(!p.isArchived, for: p.id) }
        }
    }
}

// MARK: - Настройки

enum SettingsTab: String, CaseIterable, Identifiable {
    case main = "Основные", advanced = "Дополнительно"
    var id: String { rawValue }
}

struct SettingsView: View {
    @AppStorage("settings.tab") private var tab: SettingsTab = .main

    var body: some View {
        Form {
            // Переключатель в заголовке первой секции: он уезжает вместе с настройками.
            let bar = AnyView(SettingsTabBar(tab: $tab))
            switch tab {
            case .main: MainSettingsSections(top: bar)
            case .advanced: AdvancedSettingsSections(top: bar)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .navigationTitle(L("Настройки"))
        .navigationSubtitle("")
    }
}

/// Заголовок первой секции и то, что стоит над ним.
struct SectionHeaderWithTop: View {
    let top: AnyView?
    let title: String

    var body: some View {
        if let top {
            VStack(alignment: .leading, spacing: 18) {
                top.frame(maxWidth: .infinity)
                Text(verbatim: title)
            }
        } else {
            Text(verbatim: title)
        }
    }
}

/// Свой переключатель: у системного нельзя задать поля внутри кнопки.
struct SettingsTabBar: View {
    @Binding var tab: SettingsTab

    var body: some View {
        HourfoxSegments(selection: $tab, items: SettingsTab.allCases.map { .init(value: $0, title: L($0.rawValue)) }, size: .large)
    }
}

/// То, без чего приложением неудобно пользоваться.
struct MainSettingsSections: View {
    var top: AnyView?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Section {
            LanguagePicker()
            DisplayModePicker()
            Toggle(isOn: Binding(get: { launchAtLogin }, set: { on in
                launchAtLogin = on
                let service = SMAppService.mainApp
                if on { try? service.register() } else { try? service.unregister() }
            })) {
                settingLabel("Открывать при входе в\u{00A0}систему", "Hourfox запустится вместе с\u{00A0}Mac", "power")
            }
        } header: {
            SectionHeaderWithTop(top: top, title: L("Общие"))
        }
        Section {
            ForEach(Feature.allCases.filter(\.isAvailable)) { FeatureToggle(feature: $0) }
        } header: {
            Text("Notch")
        } footer: {
            Text("Выключите лишнее — если выключить всё, в\u{00A0}Notch останется только строка таймера.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Второстепенные функции: всё выключено, пока не понадобится. Этот же набор показан при знакомстве.
struct AdvancedSettingsSections: View {
    var top: AnyView?
    @State private var calendarOn = CalendarSync.shared.isEnabled

    var body: some View {
        ExtraSections(top: top)
        Section("Оформление") {
            ThemePicker()
            AuroraToggle()
            GlassToggle()
            SoundsToggle()
        }
        Section("Интеграции") {
            Toggle(isOn: Binding(get: { calendarOn }, set: { on in
                calendarOn = on
                CalendarSync.shared.setEnabled(on) { calendarOn = $0 }
            })) {
                settingLabel("Показывать в\u{00A0}Календаре", "Завершённые записи — в\u{00A0}календаре «Hourfox»", "calendar")
            }
        }
        if GoogleCalendar.isConfigured {
            GoogleCalendarSettings()
        }
    }
}

struct DisplayModePicker: View {
    @AppStorage(DisplayMode.key) private var mode = DisplayMode.auto.rawValue

    var body: some View {
        Picker(selection: Binding(get: { mode }, set: { new in
            mode = new
            AppDelegate.shared.notch.applyDisplayMode()
        })) {
            ForEach(DisplayMode.allCases) { Text(L($0.title)).tag($0.rawValue) }
        } label: {
            settingLabel("Вид", "Авто: Notch, если есть вырез, иначе значок в\u{00A0}строке меню", "panel-top")
        }
    }
}

struct AuroraToggle: View {
    @AppStorage(Aurora.key) private var aurora = false

    var body: some View {
        Toggle(isOn: $aurora.animation(.snappy)) {
            settingLabel("Сияние", "Переливающаяся подсветка края в\u{00A0}стиле Apple Intelligence", "sparkles")
        }
    }
}

struct GlassToggle: View {
    @AppStorage(GlassStyle.key) private var glass = false

    var body: some View {
        Toggle(isOn: $glass.animation(.snappy)) {
            settingLabel("Стекло", "Стеклянное покрытие вместо чёрного фона Notch", "droplet")
        }
    }
}

struct FeatureToggle: View {
    let feature: Feature
    @AppStorage private var isOn: Bool

    init(feature: Feature) {
        self.feature = feature
        _isOn = AppStorage(wrappedValue: true, feature.key)
    }

    var body: some View {
        Toggle(isOn: $isOn.animation(.snappy)) {
            settingLabel(feature.title, feature.subtitle, feature.symbol)
        }
    }
}

func settingLabel(_ title: String, _ subtitle: String, _ symbol: String) -> some View {
    HStack(spacing: 10) {
        SettingIcon(name: symbol)
        VStack(alignment: .leading, spacing: 2) {
            Text(L(title))
            if !subtitle.isEmpty {
                Text(L(subtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Список записей

struct EntriesList: View {
    let projectID: UUID?
    let title: String
    @EnvironmentObject var store: Store
    @State private var editing: Entry?
    @State private var focusNote = false
    @State private var exporting = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var selected = Set<UUID>()
    @State private var splitting: Entry?

    private var isSearching: Bool { !query.trimmed.isEmpty }

    var body: some View {
        let groups = store.dayGroups(projectID: projectID, query: query)
        VStack(spacing: 0) {
            if store.entries.contains(where: { projectID == nil || $0.projectID == projectID }) {
                searchField
            }
            if groups.isEmpty && isSearching {
                ContentUnavailableView {
                    Label("Ничего не найдено", icon: "search")
                } description: {
                    Text("Поиск идёт по названию, комментарию и проекту.")
                }
                .frame(maxHeight: .infinity)
            } else if groups.isEmpty {
                ContentUnavailableView {
                    Label("Записей пока нет", icon: "clock")
                } description: {
                    Text("Наведите курсор на Notch вверху экрана и запустите таймер — или добавьте запись вручную.")
                } actions: {
                    Button("Добавить запись") { focusNote = false; editing = newEntry() }
                }
                .frame(maxHeight: .infinity)
            } else {
                // Выделение как в Finder: щелчок, ⇧ и ⌘ со щелчком, протягивание мышкой.
                List(selection: $selected) {
                    ForEach(groups) { g in
                        Section {
                            ForEach(g.entries) { e in
                                EntryRow(entry: e).tag(e.id)
                            }
                        } header: {
                            DayHeader(group: g)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    entryMenu(ids)
                } primaryAction: { ids in
                    if ids.count == 1, let id = ids.first, let e = store.entry(id) {
                        focusNote = false
                        editing = e
                    }
                }
                .onDeleteCommand { deleteSelected() }
                .safeAreaInset(edge: .bottom) {
                    if liveSelection.count > 1 { selectionBar }
                }
                .onChange(of: query) { selected = [] }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle(groups))
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
                .disabled(!store.entries.contains { projectID == nil || $0.projectID == projectID })
            }
        }
        .sheet(item: $editing) { e in
            Localized { EntryEditor(entry: e, isNew: !store.contains(e.id), focusNote: focusNote) }
        }
        .sheet(isPresented: $exporting) {
            Localized { ExportSheet(projectID: projectID) }
        }
        .sheet(item: $splitting) { entry in Localized { SplitEntrySheet(entry: entry) } }
    }

    /// Выделенные записи, которые ещё существуют.
    private var liveSelection: Set<UUID> { selected.filter { store.contains($0) } }

    private func deleteSelected() {
        let ids = liveSelection
        selected = []
        store.deleteEntries(ids)
    }

    private func mergeSelected() {
        let ids = liveSelection
        selected = []
        store.mergeEntries(ids)
    }

    private var selectionBar: some View {
        let ids = liveSelection
        let total = ids.compactMap { store.entry($0)?.duration() }.reduce(0, +)
        return HStack(spacing: 10) {
            Text(verbatim: L("Выбрано: %@, всего %@", "\(ids.count)", Fmt.short(total)))
                .monospacedDigit()
                .lineLimit(1)
            Button("Склеить", action: mergeSelected)
                .disabled(!store.canMerge(ids))
                .help(store.canMerge(ids) ? "" : L("Склеить можно завершённые записи подряд за один день"))
            Button("Удалить", role: .destructive, action: deleteSelected)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 42)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.bottom, 14)
    }

    /// Меню по правому щелчку: для одной записи и для нескольких.
    @ViewBuilder private func entryMenu(_ ids: Set<UUID>) -> some View {
        if ids.count > 1 {
            Button("Склеить") {
                selected = []
                store.mergeEntries(ids)
            }
            .disabled(!store.canMerge(ids))
            Divider()
            Button(L("Удалить выбранные: %@", "\(ids.count)"), role: .destructive) {
                selected = []
                store.deleteEntries(ids)
            }
        } else if let id = ids.first, let entry = store.entry(id) {
            EntryContextMenu(entry: entry, store: store,
                             edit: { focusNote = false; editing = entry },
                             editNote: { focusNote = true; editing = entry },
                             split: { splitting = entry })
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(icon: "search", size: 13)
                .foregroundStyle(.secondary)
            TextField(L("Поиск по записям"), text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { query = ""; searchFocused = false }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(icon: "x", size: 11)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Очистить")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("f")
                .opacity(0)
        }
    }

    private func subtitle(_ groups: [DayGroup]) -> String {
        if isSearching {
            let found = groups.flatMap(\.entries)
            return L("Найдено: %@, всего %@", "\(found.count)", Fmt.short(found.reduce(0) { $0 + $1.duration() }))
        }
        let all = DateInterval(start: .distantPast, end: .distantFuture)
        let sum = store.totals(in: all, projectID: projectID.map { .some($0) })
            .reduce(0) { $0 + $1.seconds }
        return sum > 0 ? L("Всего %@", Fmt.short(sum)) : ""
    }

    private func newEntry() -> Entry {
        let end = Date()
        return Entry(title: "", projectID: projectID ?? store.draftProjectID,
                     start: end.addingTimeInterval(-3600), end: end)
    }
}

/// Меню одной записи: в списке и в календаре.
struct EntryContextMenu: View {
    let entry: Entry
    let store: Store
    let edit: () -> Void
    let editNote: () -> Void
    let split: () -> Void

    var body: some View {
        let closed = store.isClosed(entry)
        Button(closed ? L("Открыть…") : L("Изменить…"), action: edit)
        if !closed {
            Button(entry.note.isEmpty ? L("Добавить комментарий…") : L("Изменить комментарий…"), action: editNote)
        }
        if !entry.isRunning {
            Button("Продолжить") { store.start(title: entry.title, projectID: entry.projectID, emoji: entry.emoji) }
            if store.isPinned(title: entry.title, projectID: entry.projectID) {
                Button("Открепить") { store.unpin(title: entry.title, projectID: entry.projectID) }
            } else if store.canPin, !entry.title.isEmpty || entry.projectID != nil {
                Button("Закрепить") { store.pin(title: entry.title, projectID: entry.projectID, emoji: entry.emoji) }
            }
            Divider()
            Button("Разделить…", action: split)
                .disabled(closed)
            let around = closed ? (earlier: nil, later: nil) : store.neighbors(of: entry.id)
            if let earlier = around.earlier {
                Button(L("Склеить с «%@»", name(earlier))) { store.mergeEntries(entry.id, earlier.id) }
            }
            if let later = around.later {
                Button(L("Склеить с «%@»", name(later))) { store.mergeEntries(entry.id, later.id) }
            }
        }
        Divider()
        Button("Удалить", role: .destructive) { store.deleteEntry(entry.id) }
            .disabled(closed)
    }

    private func name(_ e: Entry) -> String {
        e.title.isEmpty ? store.name(for: e.projectID) : e.title
    }
}

struct DayHeader: View {
    let group: DayGroup

    var body: some View {
        HStack {
            Text(Fmt.dayTitle(group.day))
            Spacer()
            if group.entries.contains(where: \.isRunning) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in total(ctx.date) }
            } else {
                total(Date())
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .padding(.top, 10)
        .padding(.bottom, 2)
        // Шапка дня прилипает при прокрутке: без своего фона записи проступают сквозь неё.
        .background {
            Color(nsColor: .windowBackgroundColor)
                .padding(.horizontal, -24)
                .padding(.vertical, -16)
        }
    }

    private func total(_ now: Date) -> some View {
        Text(Fmt.short(group.entries.reduce(0) { $0 + $1.duration(at: now) }))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            // Итог дня стоит в колонке длительности: правее неё в строках кнопка запуска.
            .padding(.trailing, 36)
    }
}

struct EntryRow: View {
    let entry: Entry
    @EnvironmentObject var store: Store
    @State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                EmojiText(emoji: entry.emoji, text: entry.title.isEmpty ? L("Без описания") : entry.title)
                    .foregroundStyle(entry.title.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                if let p = store.project(entry.projectID) {
                    HStack(spacing: 5) {
                        Circle().fill(p.color.color).frame(width: 7, height: 7)
                        EmojiText(emoji: p.emoji, text: p.name)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 12)
            Text(Fmt.range(entry))
                .font(.body)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Group {
                if entry.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(Fmt.clock(entry.duration(at: ctx.date)))
                    }
                } else {
                    Text(verbatim: Fmt.short(entry.duration()))
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: 88, alignment: .trailing)
            Button {
                if entry.isRunning { store.stop() } else { store.start(title: entry.title, projectID: entry.projectID, emoji: entry.emoji) }
            } label: {
                Image(icon: entry.isRunning ? "square" : "play", size: 11)
                    .foregroundStyle(entry.isRunning ? Color(nsColor: .systemRed) : .secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hover || entry.isRunning ? 1 : 0)
            .help(entry.isRunning ? L("Остановить") : L("Продолжить"))
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: - Задачи

struct TasksView: View {
    @EnvironmentObject var store: Store

    private var newProjectID: UUID? { newProject ?? store.draftProjectID }
    @State private var newTask = ""
    @State private var newDue: Date?
    @State private var newDueMinutes: Int?
    @State private var pickingNewDue = false
    @State private var newPriority = 0
    @State private var newEmoji: String?
    @State private var pickingNewEmoji = false
    /// Проект новой задачи; пока его не выбрали сами, берётся текущий.
    @State private var newProject: UUID??
    @State private var showDone = false
    @AppStorage("extra.dueDates") private var dueOn = false
    @AppStorage("tasks.layout") private var layout: TaskLayout = .list
    @State private var newRowHover = false

    /// Сроки выключены: вид по срокам недоступен, и открывается список.
    private var current: TaskLayout { layout == .due && !dueOn ? .list : layout }

    var body: some View {
        Group {
            if current == .list {
                list
            } else {
                TaskBoardView(layout: current)
            }
        }
        .navigationTitle(L("Задачи"))
        .navigationSubtitle(store.openTasks.isEmpty ? "" : L("Открытых: %lld", store.openTasks.count))
        .toolbar {
            BareToolbarItem {
                HourfoxSegments(selection: Binding(get: { current }, set: { layout = $0 }),
                              items: TaskLayout.allCases.filter { $0 != .due || dueOn }.map {
                                  .init(value: $0, icon: $0.icon, help: L($0.title))
                              })
            }
        }
    }

    /// Приоритет, эмодзи, проект и срок новой задачи не шумят, пока строкой не пользуются.
    private var showsNewTaskControls: Bool {
        newRowHover || !newTask.isEmpty || newPriority > 0 || newEmoji != nil || newDue != nil || newProject != nil
            || pickingNewEmoji || pickingNewDue
    }

    private var list: some View {
        List {
            Section {
                ForEach(store.openTasks) { TaskListRow(task: $0) }
                    .onMove { store.moveOpenTasks(from: $0, to: $1) }

                HStack(spacing: 12) {
                    Image(icon: "circle-plus", size: 20)
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    TextField(L("Новая задача"), text: $newTask)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .onSubmit {
                            withAnimation {
                                store.addTask(newTask, projectID: newProjectID, due: newDue, dueMinutes: newDueMinutes, priority: newPriority, emoji: newEmoji)
                            }
                            if !newTask.trimmed.isEmpty {
                                newDue = nil
                                newDueMinutes = nil
                                newPriority = 0
                                newEmoji = nil
                            }
                            newTask = ""
                        }
                    if showsNewTaskControls {
                    Menu {
                        ForEach([3, 2, 1, 0], id: \.self) { p in
                            Button { newPriority = p } label: {
                                Label {
                                    Text(L(Priority.titles[p] ?? ""))
                                } icon: {
                                    Image(nsImage: Priority.menuImage(p)).renderingMode(.original)
                                }
                            }
                        }
                    } label: {
                        TaskCheckmark(priority: newPriority, done: false, side: 15, ink: AnyShapeStyle(.secondary), doneColor: .clear)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Приоритет")
                    Button { pickingNewEmoji = true } label: {
                        Group {
                            if let newEmoji {
                                EmojiGlyph(newEmoji, size: 15)
                            } else {
                                Image(icon: "smile", size: 14)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Эмодзи")
                    .popover(isPresented: $pickingNewEmoji, arrowEdge: .bottom) {
                        EmojiGrid(selection: Binding(get: { newEmoji }, set: { value in
                            newEmoji = value
                            pickingNewEmoji = false
                        }))
                        .padding(12)
                    }
                    Menu {
                        Button("Без проекта") { newProject = .some(nil) }
                        Divider()
                        ForEach(store.activeProjects) { p in
                            Button(p.label) { newProject = .some(p.id) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if let p = store.project(newProjectID) {
                                Circle().fill(p.color.color).frame(width: 7, height: 7)
                                Text(verbatim: p.name)
                            } else {
                                Text("Проект")
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                        .contentShape(Capsule())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Проект")
                    if dueOn {
                        Button { pickingNewDue = true } label: {
                            Group {
                                if let newDue {
                                    Text(verbatim: DueDate.text(newDue, minutes: newDueMinutes))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(DueDate.color(newDue, minutes: newDueMinutes))
                                } else {
                                    Image(icon: "calendar", size: 14)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(minWidth: 22, minHeight: 22)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Срок")
                        .popover(isPresented: $pickingNewDue, arrowEdge: .bottom) {
                            DuePicker(date: newDue, minutes: newDueMinutes) { date, minutes in
                                newDue = date
                                newDueMinutes = minutes
                            } onDone: {
                                pickingNewDue = false
                            }
                            .frame(width: 390)
                            .padding(12)
                        }
                    }
                    }
                }
                .frame(minHeight: 24)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .onHover { newRowHover = $0 }
                .listRowSeparator(.hidden)
            }
            if !store.doneTasks.isEmpty {
                Section {
                    if showDone {
                        ForEach(store.doneTasks) { TaskListRow(task: $0) }
                    }
                } header: {
                    HStack {
                        Button { withAnimation(.snappy) { showDone.toggle() } } label: {
                            HStack(spacing: 6) {
                                Text("Выполненные · \(store.doneTasks.count)")
                                Image(icon: "chevron-right", size: 11)
                                    .rotationEffect(.degrees(showDone ? 90 : 0))
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button("Очистить") { withAnimation(.snappy) { store.clearDoneTasks() } }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Удалить все выполненные задачи")
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

struct TaskListRow: View {
    let task: TodoTask
    @EnvironmentObject var store: Store
    @State private var hover = false
    @State private var checking = false
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var pickingEmoji = false
    @State private var pickingDue = false
    @AppStorage("extra.dueDates") private var dueOn = false

    private var emojiBinding: Binding<String?> {
        Binding(get: { task.emoji }, set: { e in
            var t = task
            t.emoji = e
            store.updateTask(t)
            pickingEmoji = false
        })
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                // Выполненная задача уходит из списка: сначала даём договорить кружку.
                if task.done {
                    withAnimation(.snappy) { store.toggleTask(task.id) }
                } else {
                    withAnimation(.snappy) { checking = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        withAnimation(.snappy) { store.toggleTask(task.id) }
                    }
                }
            } label: {
                TaskCheckmark(priority: task.priority, done: task.done || checking, side: 18, ink: AnyShapeStyle(.secondary), doneColor: store.color(for: task.projectID))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                EmojiText(emoji: task.emoji, text: task.title)
                    .strikethrough(task.done)
                    .foregroundStyle(task.done ? .secondary : .primary)
                    .font(.system(size: 15))
                // Проект выбирается прямо в строке; без проекта подпись появляется при наведении.
                if task.projectID != nil || hover {
                    Menu {
                        Button("Без проекта") { store.setProject(nil, for: task.id) }
                        Divider()
                        ForEach(store.activeProjects) { p in
                            Button(p.label) { store.setProject(p.id, for: task.id) }
                        }
                    } label: {
                        if let p = store.project(task.projectID) {
                            HStack(spacing: 5) {
                                Circle().fill(p.color.color).frame(width: 7, height: 7)
                                EmojiText(emoji: p.emoji, text: p.name)
                            }
                        } else {
                            Text("Проект")
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Проект")
                }
            }
            Spacer()
            if dueOn, !task.done, task.due != nil || hover || pickingDue {
                Button { pickingDue = true } label: {
                    Group {
                        if let due = task.due {
                            Text(verbatim: DueDate.text(due, minutes: task.dueMinutes))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DueDate.color(due, minutes: task.dueMinutes))
                        } else {
                            Image(icon: "calendar", size: 13)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 22, minHeight: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Срок")
                .popover(isPresented: $pickingDue, arrowEdge: .bottom) {
                    DuePicker(date: task.due, minutes: task.dueMinutes) { date, minutes in
                        store.setDue(date, minutes: minutes, for: task.id)
                    } onDone: {
                        pickingDue = false
                    }
                    .frame(width: 390)
                    .padding(12)
                }
            }
            Button { pickingEmoji = true } label: {
                Image(icon: "smile", size: 13)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hover || pickingEmoji ? 1 : 0)
            .help("Эмодзи")
            .popover(isPresented: $pickingEmoji, arrowEdge: .bottom) {
                EmojiGrid(selection: emojiBinding).padding(12)
            }
            if !task.done {
                Button { store.start(title: task.title, projectID: task.projectID, emoji: task.emoji) } label: {
                    Image(icon: "play", size: 11)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hover ? 1 : 0)
                .help("Начать")
            }
        }
        .padding(.vertical, 6)
        .onHover { hover = $0 }
        .contextMenu {
            if !task.done {
                Button("Начать") { store.start(title: task.title, projectID: task.projectID, emoji: task.emoji) }
            }
            Button("Переименовать…") {
                newTitle = task.title
                renaming = true
            }
            PriorityPicker(task: task)
            if dueOn && !task.done { Button("Срок") { pickingDue = true } }
            Button("Эмодзи…") { pickingEmoji = true }
            TaskProjectMenu(task: task)
            Divider()
            Button("Удалить", role: .destructive) { store.deleteTask(task.id) }
        }
        .onTapGesture(count: 2) {
            newTitle = task.title
            renaming = true
        }
        .alert("Название задачи", isPresented: $renaming) {
            TextField(L("Название"), text: $newTitle)
            Button("Отмена", role: .cancel) {}
            Button("Сохранить") {
                guard !newTitle.trimmed.isEmpty else { return }
                var t = task
                t.title = newTitle.trimmed
                store.updateTask(t)
            }
        }
    }
}

// MARK: - Заметки

/// Как в «Заметках»: список слева, текст справа.
struct NotesView: View {
    @EnvironmentObject var store: Store
    @State private var selection: UUID?
    @FocusState private var editorFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.sortedNotes) { n in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(n.title)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(Fmt.noteDate(n.updated)).monospacedDigit()
                            Text(n.preview).lineLimit(1)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(n.id)
                    .contextMenu {
                        Button("Удалить", role: .destructive) { delete(n.id) }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(width: 260)

            Divider()

            if let id = selection, store.note(id) != nil {
                NoteEditor(id: id, focusTitle: editorFocused)
                    .id(id)
            } else {
                ContentUnavailableView {
                    Label(store.notes.isEmpty ? L("Заметок пока нет") : L("Выберите заметку"), icon: "sticky-note")
                } description: {
                    Text("Записывайте мысли прямо в\u{00A0}Notch или здесь.")
                } actions: {
                    Button("Новая заметка", action: create)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(L("Заметки"))
        .navigationSubtitle(store.notes.isEmpty ? "" : "\(store.notes.count)")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: create) { Label("Новая заметка", icon: "square-pen") }
                    .help("Новая заметка")
                Button { if let id = selection { delete(id) } } label: { Label("Удалить", icon: "trash-2") }
                    .help("Удалить заметку")
                    .disabled(selection == nil)
            }
        }
        .onAppear { selection = selection ?? store.sortedNotes.first?.id }
        .onDisappear { store.dropEmptyNotes() }
        .onChange(of: selection) { store.dropEmptyNotes(except: selection) }
    }

    private func create() {
        store.dropEmptyNotes()
        let n = store.addNote()
        selection = n.id
        DispatchQueue.main.async { editorFocused = true }
    }

    private func delete(_ id: UUID) {
        let order = store.sortedNotes.map(\.id)
        store.deleteNote(id)
        if selection == id {
            let i = order.firstIndex(of: id) ?? 0
            selection = store.sortedNotes.indices.contains(i) ? store.sortedNotes[i].id : store.sortedNotes.last?.id
        }
    }
}

/// Редактор заметки как в Apple Notes: дата сверху, первая строка — крупный заголовок, ниже текст.
struct NoteEditor: View {
    let id: UUID
    var focusTitle = false
    @EnvironmentObject var store: Store
    @State private var title = ""
    @State private var text = ""
    @FocusState private var field: Field?

    private enum Field { case title, text }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let n = store.note(id) {
                Text(Fmt.noteFull(n.updated))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            TextField("", text: $title, prompt: Text("Заголовок"), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 26, weight: .bold))
                .focused($field, equals: .title)
                .onSubmit { field = .text }
            TextEditor(text: $text)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .focused($field, equals: .text)
                .padding(.horizontal, -5)
        }
        .padding(.horizontal, 32)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .onAppear {
            let full = store.note(id)?.text ?? ""
            if let i = full.firstIndex(of: "\n") {
                title = String(full[..<i])
                text = String(full[full.index(after: i)...])
            } else {
                title = full
            }
            if focusTitle || full.isEmpty { DispatchQueue.main.async { field = .title } }
        }
        .onChange(of: title) { save() }
        .onChange(of: text) { save() }
    }

    private func save() {
        store.updateNote(id, text: text.isEmpty ? title : title + "\n" + text)
    }
}

// MARK: - Редактор записи

struct EntryEditor: View {
    let isNew: Bool
    let focusNote: Bool
    @State private var draft: Entry
    private let original: Entry
    @FocusState private var noteFocused: Bool
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    init(entry: Entry, isNew: Bool, focusNote: Bool = false) {
        _draft = State(initialValue: entry)
        original = entry
        self.isNew = isNew
        self.focusNote = focusNote
    }

    private var valid: Bool {
        draft.end.map { $0 > draft.start } ?? true
    }

    /// Запись из закрытого месяца только смотрят.
    private var readOnly: Bool { !isNew && store.isClosed(original) }
    private var inClosedPeriod: Bool { !draft.isRunning && store.isClosed(draft.start) }
    private var canSave: Bool { valid && !inClosedPeriod && !readOnly }

    private var dayBinding: Binding<Date> {
        Binding(get: { draft.start }, set: { draft = EntryTimes.settingDay(draft, $0) })
    }

    private var startBinding: Binding<Int> {
        Binding(get: { EntryTimes.minutes(of: draft.start) }, set: { draft = EntryTimes.settingStart(draft, minutes: $0) })
    }

    private var endBinding: Binding<Int> {
        Binding(get: { draft.end.map(EntryTimes.minutes(of:)) ?? 0 }, set: { draft = EntryTimes.settingEnd(draft, minutes: $0) })
    }

    var body: some View {
        HourfoxSheet(title: isNew ? L("Новая запись") : L("Запись")) {
            FormCard {
                TextField("", text: $draft.title, prompt: Text("Чем вы занимались?"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                FormLine()
                ProjectLine(selection: $draft.projectID)
                FormLine()
                TextField("", text: $draft.note, prompt: Text("Заметки по ходу работы"), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2 ... 6)
                    .focused($noteFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            }
            FormCard {
                DateLine(date: dayBinding)
                FormLine()
                HStack(spacing: 8) {
                    Image(icon: "clock", size: 13)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    times
                    Spacer(minLength: 8)
                    Text(verbatim: valid ? Fmt.short(draft.duration()) : L("конец раньше начала"))
                        .monospacedDigit()
                        .foregroundStyle(valid ? Color.secondary : Color.red)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
            }
            .disabled(readOnly)
            if readOnly || inClosedPeriod {
                HStack(spacing: 6) {
                    Image(icon: "lock", size: 13)
                    Text("Месяц закрыт. Открыть его можно в отчёте.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
            }
        } buttons: {
            if !isNew && !readOnly {
                Button("Удалить", role: .destructive) {
                    store.deleteEntry(draft.id)
                    dismiss()
                }
            }
            Spacer()
            Button("Отмена") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if !readOnly {
                Button(isNew ? L("Добавить") : L("Сохранить")) {
                    store.upsert(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .onAppear {
            if focusNote { DispatchQueue.main.async { noteFocused = true } }
        }
    }

    @ViewBuilder private var times: some View {
        HStack(spacing: 6) {
            TimeField(minutes: startBinding)
            Text(verbatim: "–").foregroundStyle(.tertiary)
            if draft.end != nil {
                TimeField(minutes: endBinding)
                let days = EntryTimes.dayOffset(draft)
                if days > 0 {
                    Text(verbatim: "+\(days)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .help("Конец на следующий день")
                }
            } else {
                Text("идёт сейчас").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Проекты

struct ProjectDetail: View {
    let id: UUID
    @ObservedObject var nav: JournalNav
    @EnvironmentObject var store: Store
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var showingExpenses = false
    @AppStorage("extra.rates") private var ratesOn = false
    @AppStorage(ExtraKey.expenses) private var expensesOn = false

    var body: some View {
        if let p = store.project(id) {
            VStack(spacing: 0) {
                if ratesOn { ProjectEconomyStrip(projectID: id) }
                EntriesList(projectID: id, title: p.label)
            }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if ratesOn && expensesOn {
                            Button { showingExpenses = true } label: { Label("Расходы", icon: "banknote") }
                                .help("Расходы")
                        }
                        Button { editing = true } label: { Label("Изменить проект", icon: "pencil") }
                        Button { store.setArchived(!p.isArchived, for: id) } label: {
                            Label(p.isArchived ? L("Вернуть из архива") : L("В архив"), icon: "archive")
                        }
                        .help(p.isArchived ? L("Вернуть из архива") : L("В архив"))
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Удалить проект", icon: "trash-2")
                        }
                    }
                }
                .sheet(isPresented: $editing) { Localized { ProjectEditor(existing: p) } }
                .sheet(isPresented: $showingExpenses) { Localized { ExpensesSheet(projectID: id) } }
                .confirmationDialog("Удалить проект «\(p.name)»?", isPresented: $confirmDelete) {
                    Button("Удалить", role: .destructive) {
                        nav.selection = .journal
                        store.deleteProject(id)
                    }
                } message: {
                    Text("Проект попадёт в архив. Записи останутся в журнале, но без проекта.")
                }
        } else {
            ContentUnavailableView { Label("Проект не найден", icon: "folder") }
        }
    }
}

struct ProjectEditor: View {
    let existing: Project?
    var onCreate: (Project) -> Void = { _ in }
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color: ProjectColor = .blue
    @State private var emoji: String?
    @State private var pickingEmoji = false
    @State private var isFixed = false
    @State private var price = ""
    @AppStorage("extra.rates") private var ratesOn = false
    @AppStorage(ExtraKey.currency) private var currency = "USD"

    private var parsedPrice: Double? { Project.parseRate(price) }

    var body: some View {
        HourfoxSheet(title: existing == nil ? L("Новый проект") : L("Проект"), width: 460) {
            FormCard {
                HStack(spacing: 8) {
                    Button { pickingEmoji.toggle() } label: {
                        Group {
                            if let emoji {
                                Text(verbatim: emoji).font(.system(size: 18))
                            } else {
                                Image(icon: "smile", size: 16).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Эмодзи")
                    .popover(isPresented: $pickingEmoji, arrowEdge: .bottom) {
                        Localized {
                            EmojiGrid(selection: Binding(get: { emoji }, set: { value in
                                emoji = value
                                pickingEmoji = false
                            }))
                            .padding(12)
                        }
                    }
                    TextField("", text: $name, prompt: Text("Название"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .onSubmit(save)
                }
                .padding(.horizontal, 8)
                .frame(height: 44)
                FormLine()
                ProjectColorRow(selection: $color, side: 18, ring: AnyShapeStyle(Color.primary.opacity(0.85)))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            }
            if ratesOn {
                FormCard {
                    FormRow(title: "Оплата") {
                        HourfoxSegments(selection: $isFixed, items: [
                            .init(value: false, title: L("В час")),
                            .init(value: true, title: L("За проект")),
                        ])
                    }
                    FormLine()
                    FormRow(title: isFixed ? "Цена проекта" : "Ставка в час") {
                        HStack(spacing: 6) {
                            TextField("", text: $price, prompt: Text(verbatim: "0"))
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .onSubmit(save)
                            Text(verbatim: currency).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } buttons: {
            Spacer()
            Button("Отмена") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(existing == nil ? L("Создать") : L("Сохранить"), action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmed.isEmpty)
        }
        .onAppear {
            name = existing?.name ?? ""
            color = existing?.color ?? store.nextColor()
            emoji = existing?.emoji
            isFixed = existing?.fixedPrice != nil
            price = (existing?.fixedPrice ?? existing?.rate).map { $0.formatted(.number.grouping(.never)) } ?? ""
        }
        .onDisappear { ColorPanelBridge.close() }
    }

    private func applyMoney(_ p: inout Project) {
        guard ratesOn else { return }
        p.rate = isFixed ? nil : parsedPrice
        p.fixedPrice = isFixed ? parsedPrice : nil
    }

    private func save() {
        guard !name.trimmed.isEmpty else { return }
        if var p = existing {
            p.name = name.trimmed
            p.color = color
            p.emoji = emoji
            applyMoney(&p)
            store.updateProject(p)
        } else {
            var p = store.addProject(name: name, color: color)
            p.emoji = emoji
            applyMoney(&p)
            store.updateProject(p)
            onCreate(p)
        }
        dismiss()
    }
}

// MARK: - Отчёт

enum Period: String, CaseIterable, Identifiable {
    case day = "День", week = "Неделя", month = "Месяц", year = "Год"
    var id: String { rawValue }
    var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }
}
