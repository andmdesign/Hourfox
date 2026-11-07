import Combine
import SwiftUI

/// Всё хранится локально в ~/Library/Application Support/Tempo/data.json — интернет не нужен.
final class Store: ObservableObject {
    static let shared = Store()

    @Published var projects: [Project] = []
    /// Отсортированы от новых к старым.
    @Published var entries: [Entry] = []
    @Published var draftTitle = ""
    @Published var draftProjectID: UUID?
    /// Таймер для следующего старта; nil — секундомер.
    @Published var draftDuration: TimeInterval?
    @Published var draftEmoji: String?
    @Published var tasks: [TodoTask] = []
    @Published var notes: [Note] = []
    @Published var pins: [PinnedTask] = []
    /// Всё удалённое. Окончательно удалить можно только отсюда.
    @Published var archive = ArchiveBox()
    @Published var expenses: [Expense] = []
    /// Записи раньше этого момента закрыты для правок.
    @Published var lockedBefore: Date?
    /// Что можно вернуть прямо сейчас: кнопка «Отменить» висит несколько секунд.
    @Published var undoOffer: UndoOffer?
    private var undoWork: DispatchWorkItem?

    let fileURL: URL
    private(set) var isFirstLaunch = false
    /// Файл данных не прочитался: копия лежит здесь, человеку об этом надо сказать.
    private(set) var damagedDataCopy: URL?
    private var cancellables = Set<AnyCancellable>()

    private struct Snapshot: Codable {
        var version = 1
        var projects: [Project]
        var entries: [Entry]
        var draftProjectID: UUID?
        var draftDuration: TimeInterval?
        var tasks: [TodoTask]?
        var notes: [Note]?
        var pins: [PinnedTask]?
        var archive: ArchiveBox?
        var expenses: [Expense]?
        var lockedBefore: Date?
    }

    init() {
        let dir = ProcessInfo.processInfo.environment["TEMPO_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tempo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("data.json")
        load()

        objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in self?.save() }
            .store(in: &cancellables)

        Backups.run(dataFile: fileURL)
        // Mac неделями работает без перезапуска, поэтому новый день проверяем и на ходу.
        Timer.publish(every: 3600, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                save()
                Backups.run(dataFile: fileURL)
                MainActor.assumeIsolated { _ = AutoReport.run(store: self) }
            }
            .store(in: &cancellables)
    }

    // MARK: Файл

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            isFirstLaunch = true
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let s = try? decoder.decode(Snapshot.self, from: data) else {
            // Повреждённый файл не затираем — откладываем копию рядом.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            damagedDataCopy = backup
            return
        }
        // Копия данных прошлого запуска — на случай, если что-то удалят по ошибке.
        let backup = fileURL.deletingPathExtension().appendingPathExtension("previous.json")
        try? data.write(to: backup, options: .atomic)
        projects = s.projects
        entries = s.entries.sorted { $0.start > $1.start }
        // Свои картинки-эмодзи больше не поддерживаются: их ссылки не должны попасть на экран текстом.
        func plain(_ emoji: String?) -> String? { emoji?.hasPrefix("custom:") == true ? nil : emoji }
        for i in projects.indices { projects[i].emoji = plain(projects[i].emoji) }
        for i in entries.indices { entries[i].emoji = plain(entries[i].emoji) }
        draftProjectID = s.draftProjectID
        draftDuration = s.draftDuration
        tasks = s.tasks ?? []
        for i in tasks.indices { tasks[i].emoji = plain(tasks[i].emoji) }
        notes = s.notes ?? []
        pins = s.pins ?? []
        archive = s.archive ?? ArchiveBox()
        expenses = s.expenses ?? []
        lockedBefore = s.lockedBefore
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let s = Snapshot(projects: projects, entries: entries, draftProjectID: draftProjectID,
                         draftDuration: draftDuration, tasks: tasks, notes: notes, pins: pins, archive: archive,
                         expenses: expenses, lockedBefore: lockedBefore)
        guard let data = try? encoder.encode(s) else {
            NSLog("Tempo: не удалось подготовить данные к сохранению")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Tempo: не удалось сохранить данные: \(error.localizedDescription)")
        }
    }

    // MARK: Таймер

    var runningIndex: Int? { entries.firstIndex { $0.end == nil } }
    var running: Entry? { runningIndex.map { entries[$0] } }

    /// Поле «Чем вы заняты?»: пока таймер идёт — правит текущую запись, иначе черновик.
    var currentTitle: String {
        get { running?.title ?? draftTitle }
        set {
            if let i = runningIndex { entries[i].title = newValue } else { draftTitle = newValue }
        }
    }

    /// Комментарий к идущей записи.
    var currentNote: String {
        get { running?.note ?? "" }
        set { if let i = runningIndex { entries[i].note = newValue } }
    }

    /// Эмодзи записи: пока таймер идёт — у текущей, иначе у следующей.
    var currentEmoji: String? {
        get { running.map(\.emoji) ?? draftEmoji }
        set { if let i = runningIndex { entries[i].emoji = newValue } else { draftEmoji = newValue } }
    }

    var currentProjectID: UUID? {
        get { running.map(\.projectID) ?? draftProjectID }
        set {
            if let i = runningIndex { entries[i].projectID = newValue }
            draftProjectID = newValue
        }
    }

    func start() {
        if Extra.smartInput.isOn {
            let parsed = SmartInput.parse(draftTitle, projects: activeProjects)
            let planned: TimeInterval?? = parsed.minutes.map { .some(TimeInterval($0 * 60)) }
            start(title: parsed.title, projectID: parsed.projectID ?? draftProjectID, planned: planned, emoji: draftEmoji)
        } else {
            start(title: draftTitle, projectID: draftProjectID, emoji: draftEmoji)
        }
        draftTitle = ""
        draftEmoji = nil
    }

    /// planned: длительность таймера; по умолчанию — выбранная для следующего старта.
    func start(title: String, projectID: UUID?, planned: TimeInterval?? = nil, emoji: String? = nil) {
        Sounds.hush = true
        stop()
        Sounds.hush = false
        Sounds.play(.start)
        let fallback = Feature.countdown.isOn ? draftDuration : nil
        entries.insert(Entry(title: title.trimmed, projectID: projectID, start: Date(), planned: planned ?? fallback, emoji: emoji), at: 0)
        draftProjectID = projectID
    }

    /// Выбор таймера: до старта — на следующую запись, во время работы — «ещё N минут»:
    /// прибавляется к оставшемуся, а если таймера не было — отсчитывается от текущего момента.
    func setTimer(_ minutes: Int?) {
        let seconds = minutes.map { TimeInterval($0 * 60) }
        if let i = runningIndex {
            entries[i].planned = seconds.map { (entries[i].planned ?? entries[i].duration()) + $0 }
        } else {
            draftDuration = seconds
        }
    }

    /// Если время таймера вышло — закрываем запись ровно по таймеру и возвращаем её.
    func finishIfDue(now: Date = Date()) -> Entry? {
        guard let i = runningIndex, let planned = entries[i].planned,
              entries[i].duration(at: now) >= planned else { return nil }
        entries[i].end = entries[i].start.addingTimeInterval(planned + entries[i].pausedTotal)
        entries[i].title = entries[i].title.trimmed
        entries[i].note = entries[i].note.trimmed
        return entries[i]
    }

    func stop() {
        guard let i = runningIndex else { return }
        Sounds.play(.stop)
        let now = Date()
        // Остановка на паузе: пауза закрывается, запись заканчивается сейчас.
        entries[i].pausedTotal = entries[i].paused(at: now)
        entries[i].pausedAt = nil
        entries[i].end = now
        entries[i].title = entries[i].title.trimmed
        entries[i].note = entries[i].note.trimmed
        if entries[i].duration() < 1 { entries.remove(at: i) }
    }

    /// Пауза: время записи замирает, а запись остаётся той же — после продолжения счёт идёт дальше.
    func togglePause() {
        guard let i = runningIndex else { return }
        let now = Date()
        if let p = entries[i].pausedAt {
            entries[i].pausedTotal += now.timeIntervalSince(p)
            entries[i].pausedAt = nil
        } else {
            entries[i].pausedAt = now
        }
    }

    /// Отменить идущую запись, ничего не сохраняя.
    func discardRunning() {
        if let id = running?.id { deleteEntry(id) }
    }

    func toggle() {
        running == nil ? start() : stop()
    }

    // MARK: Записи

    func upsert(_ e: Entry) {
        // В закрытый период запись не попадает и из него не уходит.
        if !e.isRunning, isClosed(e.start) || isClosed(id: e.id) { return }
        var e = e
        e.title = e.title.trimmed
        e.note = e.note.trimmed
        if let i = entries.firstIndex(where: { $0.id == e.id }) {
            entries[i] = e
        } else {
            entries.append(e)
        }
        entries.sort { $0.start > $1.start }
    }

    func deleteEntry(_ id: UUID) {
        deleteEntries([id])
    }

    // MARK: Отмена

    func offerUndo(_ message: String, restore: @escaping () -> Void) {
        undoWork?.cancel()
        let offer = UndoOffer(message: message, restore: restore)
        undoOffer = offer
        let work = DispatchWorkItem { [weak self] in
            if self?.undoOffer?.id == offer.id { self?.undoOffer = nil }
        }
        undoWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    func performUndo() {
        undoWork?.cancel()
        undoOffer?.restore()
        undoOffer = nil
    }

    func entry(_ id: UUID?) -> Entry? {
        guard let id else { return nil }
        return entries.first { $0.id == id }
    }

    func setNote(_ note: String, for id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }), !isClosed(entries[i]) else { return }
        entries[i].note = note.trimmed
    }

    func contains(_ id: UUID) -> Bool {
        entries.contains { $0.id == id }
    }

    // MARK: Задачи

    /// Открытые задачи: сначала важные, внутри приоритета — в порядке добавления.
    /// Перетаскивание важнее приоритета. Если включены сроки: просроченные наверху, а при равном приоритете — у кого срок раньше.
    var openTasks: [TodoTask] {
        let useDue = Extra.dueDates.isOn
        return tasks.enumerated()
            .filter { !$0.element.done }
            .sorted { a, b in
                if useDue {
                    let lateA = a.element.due.map { DueDate.isOverdue($0, minutes: a.element.dueMinutes) } ?? false
                    let lateB = b.element.due.map { DueDate.isOverdue($0, minutes: b.element.dueMinutes) } ?? false
                    if lateA != lateB { return lateA }
                }
                let rankA = a.element.rank ?? .infinity, rankB = b.element.rank ?? .infinity
                if rankA != rankB { return rankA < rankB }
                if a.element.priority != b.element.priority { return a.element.priority > b.element.priority }
                if useDue {
                    let dueA = a.element.due.map { DueDate.moment($0, minutes: a.element.dueMinutes) } ?? .distantFuture
                    let dueB = b.element.due.map { DueDate.moment($0, minutes: b.element.dueMinutes) } ?? .distantFuture
                    if dueA != dueB { return dueA < dueB }
                }
                return a.offset < b.offset
            }
            .map(\.element)
    }
    var doneTasks: [TodoTask] { tasks.filter(\.done).reversed() }

    /// «!!! Позвонить» — восклицательные знаки в начале задают приоритет.
    func addTask(_ title: String, projectID: UUID?, due: Date? = nil, dueMinutes: Int? = nil, priority: Int = 0, emoji: String? = nil) {
        if Extra.smartInput.isOn {
            let parsed = SmartInput.parse(title, projects: activeProjects, allowDue: Extra.dueDates.isOn)
            guard !parsed.title.isEmpty else { return }
            var task = TodoTask(title: parsed.title, projectID: parsed.projectID ?? projectID, priority: parsed.priority ?? priority)
            task.due = (parsed.due ?? due).map { Cal.ru.startOfDay(for: $0) }
            task.dueMinutes = parsed.due == nil && due != nil ? dueMinutes : nil
            task.emoji = emoji
            tasks.append(task)
            placeByPriority(task.id)
            return
        }
        var t = title.trimmed
        let marks = t.prefix(while: { $0 == "!" }).count
        if (1 ... 3).contains(marks) { t = String(t.dropFirst(marks)).trimmed }
        guard !t.isEmpty else { return }
        // Знаки в тексте важнее выбранного: их написали только что.
        var task = TodoTask(title: t, projectID: projectID, priority: (1 ... 3).contains(marks) ? marks : priority)
        task.emoji = emoji
        task.due = due.map { Cal.ru.startOfDay(for: $0) }
        task.dueMinutes = due == nil ? nil : dueMinutes
        tasks.append(task)
        placeByPriority(task.id)
    }

    /// Перетаскивание в списке: порядок запоминается у всех открытых задач.
    func moveOpenTasks(from source: IndexSet, to destination: Int) {
        var list = openTasks
        list.move(fromOffsets: source, toOffset: destination)
        rerank(list)
    }

    private func rerank(_ list: [TodoTask]) {
        for (position, task) in list.enumerated() {
            if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i].rank = Double(position) }
        }
    }

    /// Если порядок уже задан руками, новая задача или новый приоритет встают над менее важными.
    private func placeByPriority(_ id: UUID) {
        guard tasks.contains(where: { !$0.done && $0.rank != nil }),
              let task = tasks.first(where: { $0.id == id }) else { return }
        var list = openTasks.filter { $0.id != id }
        list.insert(task, at: list.firstIndex { $0.priority < task.priority } ?? list.count)
        rerank(list)
    }

    func setPriority(_ priority: Int, for id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].priority = priority
        placeByPriority(id)
    }

    func setProject(_ projectID: UUID?, for id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].projectID = projectID
    }

    func toggleTask(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].done.toggle()
        if tasks[i].done { tasks[i].inProgress = false }
        // Задача сразу уходит из списка, поэтому случайный щелчок можно отменить.
        guard tasks[i].done else { return }
        offerUndo(L("Задача выполнена")) { [weak self] in
            guard let self, let j = tasks.firstIndex(where: { $0.id == id }) else { return }
            tasks[j].done = false
        }
    }

    func updateTask(_ task: TodoTask) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[i] = task
    }

    func deleteTask(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let removed = tasks.remove(at: index)
        archive.tasks.insert(ArchiveItem(item: removed), at: 0)
        offerUndo(L("Задача удалена")) { [weak self] in
            guard let self else { return }
            archive.tasks.removeAll { $0.id == removed.id }
            tasks.insert(removed, at: min(index, tasks.count))
        }
    }

    /// Убрать все выполненные разом. Вернуть можно той же кнопкой «Отменить», порядок сохранится.
    func clearDoneTasks() {
        let removed = tasks.enumerated().filter { $0.element.done }
        guard !removed.isEmpty else { return }
        tasks.removeAll(where: \.done)
        archive.tasks.insert(contentsOf: removed.map { ArchiveItem(item: $0.element) }, at: 0)
        let ids = Set(removed.map(\.element.id))
        offerUndo(L("Выполненные задачи удалены")) { [weak self] in
            guard let self else { return }
            archive.tasks.removeAll { ids.contains($0.id) }
            for (index, task) in removed { tasks.insert(task, at: min(index, tasks.count)) }
        }
    }

    // MARK: Заметки

    /// Сначала недавно изменённые.
    var sortedNotes: [Note] { notes.sorted { $0.updated > $1.updated } }

    @discardableResult
    func addNote(_ text: String = "") -> Note {
        let n = Note(text: text)
        notes.append(n)
        return n
    }

    func note(_ id: UUID?) -> Note? {
        guard let id else { return nil }
        return notes.first { $0.id == id }
    }

    func updateNote(_ id: UUID, text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text
        notes[i].updated = Date()
    }

    func deleteNote(_ id: UUID) {
        guard let removed = note(id) else { return }
        notes.removeAll { $0.id == id }
        // Пустую заметку возвращать незачем.
        guard !removed.text.trimmed.isEmpty else { return }
        archive.notes.insert(ArchiveItem(item: removed), at: 0)
        offerUndo(L("Заметка удалена")) { [weak self] in
            self?.archive.notes.removeAll { $0.id == removed.id }
            self?.notes.append(removed)
        }
    }

    /// Пустые заметки не храним — кроме той, что открыта прямо сейчас.
    func dropEmptyNotes(except id: UUID? = nil) {
        notes.removeAll { $0.text.trimmed.isEmpty && $0.id != id }
    }

    // MARK: Проекты

    func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func color(for id: UUID?) -> Color {
        project(id)?.color.color ?? Color(nsColor: .systemGray)
    }

    func nsColor(for id: UUID?) -> NSColor {
        project(id)?.color.nsColor ?? .systemGray
    }

    func name(for id: UUID?) -> String {
        project(id)?.label ?? L("Без проекта")
    }

    func nextColor() -> ProjectColor {
        let used = Set(projects.map(\.color))
        return ProjectColor.quick.first { !used.contains($0) }
            ?? ProjectColor.quick[projects.count % ProjectColor.quick.count]
    }

    @discardableResult
    func addProject(name: String, color: ProjectColor) -> Project {
        let p = Project(name: name.trimmed, color: color)
        projects.append(p)
        return p
    }

    func updateProject(_ p: Project) {
        guard let i = projects.firstIndex(where: { $0.id == p.id }) else { return }
        projects[i] = p
    }

    func deleteProject(_ id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let removed = projects.remove(at: index)
        let entryIDs = Set(entries.filter { $0.projectID == id }.map(\.id))
        let taskIDs = Set(tasks.filter { $0.projectID == id }.map(\.id))
        let pinIDs = Set(pins.filter { $0.projectID == id }.map(\.id))
        let wasDraft = draftProjectID == id
        for i in entries.indices where entries[i].projectID == id {
            entries[i].projectID = nil
        }
        for i in tasks.indices where tasks[i].projectID == id {
            tasks[i].projectID = nil
        }
        for i in pins.indices where pins[i].projectID == id {
            pins[i].projectID = nil
        }
        if wasDraft { draftProjectID = nil }
        let deleted = DeletedProject(project: removed, entryIDs: entryIDs, taskIDs: taskIDs, pinIDs: pinIDs)
        archive.projects.insert(deleted, at: 0)
        offerUndo(L("Проект удалён")) { [weak self] in
            guard let self else { return }
            restoreProject(id, at: index)
            if wasDraft { draftProjectID = id }
        }
    }

    // MARK: Архив проектов

    /// Проекты для выбора: без архивных.
    var activeProjects: [Project] { projects.filter { !$0.isArchived } }
    var archivedProjects: [Project] { projects.filter(\.isArchived) }

    func setArchived(_ archived: Bool, for id: UUID) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].archivedAt = archived ? Date() : nil
        if archived, draftProjectID == id { draftProjectID = nil }
    }

    // MARK: Закреплённые задачи

    static let maxPins = 3

    func isPinned(title: String, projectID: UUID?) -> Bool {
        pins.contains { $0.title == title && $0.projectID == projectID }
    }

    var canPin: Bool { pins.count < Self.maxPins }

    func pin(title: String, projectID: UUID?, emoji: String?) {
        guard canPin, !isPinned(title: title, projectID: projectID) else { return }
        pins.append(PinnedTask(title: title, projectID: projectID, emoji: emoji))
    }

    func unpin(title: String, projectID: UUID?) {
        pins.removeAll { $0.title == title && $0.projectID == projectID }
    }

    /// Закреплённые для показа: задачи архивных проектов не предлагаем.
    var visiblePins: [PinnedTask] {
        pins.filter { !(project($0.projectID)?.isArchived ?? false) }
    }

    // MARK: Разделение и склейка

    /// Соседи записи за тот же день.
    func neighbors(of id: UUID) -> (earlier: Entry?, later: Entry?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return (nil, nil) }
        func usable(_ index: Int) -> Entry? {
            guard entries.indices.contains(index), !entries[index].isRunning,
                  Cal.ru.isDate(entries[index].start, inSameDayAs: entries[i].start) else { return nil }
            return entries[index]
        }
        return (usable(i + 1), usable(i - 1))
    }

    /// Запись делится на две в момент time; паузы расходятся пропорционально.
    @discardableResult
    func splitEntry(_ id: UUID, at time: Date, secondTitle: String? = nil) -> Bool {
        guard let i = entries.firstIndex(where: { $0.id == id }), let end = entries[i].end,
              time > entries[i].start, time < end, !isClosed(entries[i]) else { return false }
        let original = entries[i]
        let share = time.timeIntervalSince(original.start) / end.timeIntervalSince(original.start)
        var first = original
        first.end = time
        first.planned = nil
        first.pausedTotal = original.pausedTotal * share
        var second = Entry(title: secondTitle?.trimmed.isEmpty == false ? secondTitle!.trimmed : original.title,
                           projectID: original.projectID, start: time, end: end, note: original.note, emoji: original.emoji)
        second.pausedTotal = original.pausedTotal * (1 - share)
        entries[i] = first
        entries.append(second)
        entries.sort { $0.start > $1.start }
        offerUndo(L("Запись разделена")) { [weak self] in
            guard let self else { return }
            entries.removeAll { $0.id == second.id }
            upsert(original)
        }
        return true
    }

    /// Несколько записей подряд за один день: только такие можно склеить, иначе в итог попадёт чужое время.
    func canMerge(_ ids: Set<UUID>) -> Bool {
        guard ids.count > 1, !ids.contains(where: isClosed(id:)) else { return false }
        let positions = entries.indices.filter { ids.contains(entries[$0].id) }
        guard positions.count == ids.count, positions.last! - positions.first! == positions.count - 1 else { return false }
        let picked = positions.map { entries[$0] }
        return picked.allSatisfy { !$0.isRunning && Cal.ru.isDate($0.start, inSameDayAs: picked[0].start) }
    }

    @discardableResult
    func mergeEntries(_ a: UUID, _ b: UUID) -> Bool {
        guard canMerge([a, b]) else { return false }
        return mergeEntries([a, b])
    }

    /// Записи становятся одной: время работы складывается, промежутки между ними считаются паузой.
    /// Название и проект берутся у самой ранней.
    @discardableResult
    func mergeEntries(_ ids: Set<UUID>) -> Bool {
        guard canMerge(ids) else { return false }
        let picked = entries.filter { ids.contains($0.id) }.sorted { $0.start < $1.start }
        let end = picked.compactMap(\.end).max()!
        var merged = picked[0]
        merged.end = end
        merged.planned = nil
        merged.pausedAt = nil
        merged.pausedTotal = max(0, end.timeIntervalSince(merged.start) - picked.reduce(0) { $0 + $1.duration() })
        merged.note = picked.map(\.note).filter { !$0.isEmpty }.joined(separator: "\n")
        entries.removeAll { ids.contains($0.id) && $0.id != merged.id }
        upsert(merged)
        offerUndo(L("Записи склеены")) { [weak self] in
            guard let self else { return }
            for e in picked { upsert(e) }
        }
        return true
    }

    func deleteEntries(_ ids: Set<UUID>) {
        let removed = entries.filter { ids.contains($0.id) && !isClosed($0) }
        guard !removed.isEmpty else { return }
        let removedIDs = Set(removed.map(\.id))
        entries.removeAll { removedIDs.contains($0.id) }
        archive.entries.insert(contentsOf: removed.map { ArchiveItem(item: $0) }, at: 0)
        offerUndo(L(removed.count == 1 ? "Запись удалена" : "Записи удалены")) { [weak self] in
            guard let self else { return }
            for e in removed { restoreEntry(e.id) }
        }
    }

    // MARK: Сводки

    func totals(in interval: DateInterval, now: Date = Date(), projectID: UUID?? = nil) -> [ProjectTotal] {
        var map: [UUID?: (TimeInterval, [String: TimeInterval])] = [:]
        for e in entries {
            if let filter = projectID, e.projectID != filter { continue }
            let s = e.overlap(with: interval, now: now)
            guard s > 0 else { continue }
            let title = e.title.isEmpty ? L("Без описания") : e.title
            var cur = map[e.projectID] ?? (0, [:])
            cur.0 += s
            cur.1[title, default: 0] += s
            map[e.projectID] = cur
        }
        return map.map { key, value in
            ProjectTotal(
                projectID: key,
                seconds: value.0,
                tasks: value.1.map { TaskTotal(title: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }
            )
        }
        .sorted { $0.seconds > $1.seconds }
    }

    func total(in interval: DateInterval, now: Date = Date()) -> TimeInterval {
        entries.reduce(0) { $0 + $1.overlap(with: interval, now: now) }
    }

    func dailyPoints(in interval: DateInterval, now: Date = Date()) -> [DayPoint] {
        var points: [DayPoint] = []
        var day = interval.start
        while day < interval.end {
            let iv = Cal.day(day)
            for t in totals(in: iv, now: now) {
                points.append(DayPoint(day: iv.start, key: t.id, hours: t.seconds / 3600))
            }
            day = iv.end
        }
        return points
    }

    func recents(limit: Int) -> [Recent] {
        var seen = Set<String>()
        var result: [Recent] = []
        let pinned = Set(pins.map(\.key))
        for e in entries where !e.isRunning {
            guard !e.title.isEmpty || e.projectID != nil, !(project(e.projectID)?.isArchived ?? false) else { continue }
            let r = Recent(entryID: e.id, title: e.title, projectID: e.projectID, note: e.note, emoji: e.emoji)
            if !pinned.contains(r.id), seen.insert(r.id).inserted {
                result.append(r)
                if result.count == limit { break }
            }
        }
        return result
    }

    /// Поиск идёт по названию, комментарию и проекту.
    func matches(_ e: Entry, query: String) -> Bool {
        let q = query.trimmed
        guard !q.isEmpty else { return true }
        return e.title.localizedCaseInsensitiveContains(q) || e.note.localizedCaseInsensitiveContains(q)
            || (project(e.projectID)?.name.localizedCaseInsensitiveContains(q) ?? false)
    }

    func dayGroups(projectID: UUID?, query: String = "") -> [DayGroup] {
        var groups: [DayGroup] = []
        for e in entries where (projectID == nil || e.projectID == projectID) && matches(e, query: query) {
            let d = Cal.ru.startOfDay(for: e.start)
            if groups.last?.day == d {
                groups[groups.count - 1].entries.append(e)
            } else {
                groups.append(DayGroup(day: d, entries: [e]))
            }
        }
        return groups
    }

    // MARK: Архив

    var archiveCount: Int {
        archive.entries.count + archive.tasks.count + archive.notes.count + archive.projects.count + archive.expenses.count + archivedProjects.count
    }

    func restoreEntry(_ id: UUID) {
        // В закрытый период запись не вернуть: она остаётся в архиве, пока период не откроют.
        guard let item = archive.entries.first(where: { $0.id == id }), !isClosed(item.item.start) else { return }
        archive.entries.removeAll { $0.id == id }
        var e = item.item
        // Вторая идущая запись недопустима: пока лежала в архиве, могли запустить новую.
        if e.isRunning, running != nil { e.end = item.deletedAt }
        upsert(e)
    }

    func restoreTask(_ id: UUID) {
        guard let item = archive.tasks.first(where: { $0.id == id }) else { return }
        archive.tasks.removeAll { $0.id == id }
        tasks.append(item.item)
    }

    func restoreNote(_ id: UUID) {
        guard let item = archive.notes.first(where: { $0.id == id }) else { return }
        archive.notes.removeAll { $0.id == id }
        notes.append(item.item)
    }

    /// Проект возвращается вместе со связями: записи и задачи снова в нём, если их не перенесли в другой.
    func restoreProject(_ id: UUID, at index: Int? = nil) {
        guard let deleted = archive.projects.first(where: { $0.id == id }) else { return }
        archive.projects.removeAll { $0.id == id }
        projects.insert(deleted.project, at: min(index ?? projects.count, projects.count))
        for i in entries.indices where deleted.entryIDs.contains(entries[i].id) && entries[i].projectID == nil { entries[i].projectID = id }
        for i in tasks.indices where deleted.taskIDs.contains(tasks[i].id) && tasks[i].projectID == nil { tasks[i].projectID = id }
        for i in pins.indices where deleted.pinIDs.contains(pins[i].id) && pins[i].projectID == nil { pins[i].projectID = id }
    }

    func eraseEntry(_ id: UUID) { archive.entries.removeAll { $0.id == id } }
    func eraseTask(_ id: UUID) { archive.tasks.removeAll { $0.id == id } }
    func eraseNote(_ id: UUID) { archive.notes.removeAll { $0.id == id } }

    func eraseProject(_ id: UUID) {
        archive.projects.removeAll { $0.id == id }
        // Проект из архива проектов сначала снимает связи, как обычное удаление.
        guard projects.contains(where: { $0.id == id }) else { return }
        projects.removeAll { $0.id == id }
        for i in entries.indices where entries[i].projectID == id { entries[i].projectID = nil }
        for i in tasks.indices where tasks[i].projectID == id { tasks[i].projectID = nil }
        for i in pins.indices where pins[i].projectID == id { pins[i].projectID = nil }
    }

    /// Окончательная очистка. Проекты, убранные в архив целиком, остаются: у них живая история.
    func eraseArchive() {
        archive = ArchiveBox()
        undoOffer = nil
    }
}

