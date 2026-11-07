import AppKit
import SwiftUI

// MARK: - Виды задач

enum TaskLayout: String, CaseIterable, Identifiable {
    case list, kanban, priority, project, due
    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: "Список"
        case .kanban: "Канбан"
        case .priority: "По приоритету"
        case .project: "По проектам"
        case .due: "По срокам"
        }
    }

    var icon: String {
        switch self {
        case .list: "list"
        case .kanban: "view-columns"
        case .priority: "bars-arrow-down"
        case .project: "folder"
        case .due: "calendar"
        }
    }
}

/// Колонка доски. Куда бросили задачу, решает она сама: статус, приоритет, проект или срок.
struct TaskColumn: Identifiable {
    let id: String
    let title: String
    var dot: Color?
    var tasks: [TodoTask]
    /// nil: в эту колонку бросить нельзя, например в «Просрочено».
    var drop: ((Store, UUID) -> Void)?
    /// nil: новую задачу здесь не добавить.
    var add: ((Store, String) -> Void)?
    /// Пустая колонка уходит в список справа: проектов бывает много, и пустые съедают всю доску.
    var hidesWhenEmpty = false
}

enum TaskBoard {
    static func columns(_ layout: TaskLayout, store: Store, now: Date = Date()) -> [TaskColumn] {
        let open = store.openTasks
        switch layout {
        case .list:
            return []
        case .kanban:
            let draft = store.draftProjectID
            return [
                TaskColumn(id: "todo", title: L("Сделать"), tasks: open.filter { !$0.inProgress },
                           drop: { $0.moveTask($1, inProgress: false) },
                           add: { $0.addTask($1, projectID: draft) }),
                TaskColumn(id: "doing", title: L("В работе"), dot: .accentColor, tasks: open.filter(\.inProgress),
                           drop: { $0.moveTask($1, inProgress: true) },
                           add: { store, title in
                               let before = Set(store.tasks.map(\.id))
                               store.addTask(title, projectID: draft)
                               if let new = store.tasks.first(where: { !before.contains($0.id) }) {
                                   store.moveTask(new.id, inProgress: true)
                               }
                           }),
                TaskColumn(id: "done", title: L("Готово"), dot: Color(nsColor: .systemGreen), tasks: store.doneTasks,
                           drop: { $0.completeTask($1) }),
            ]
        case .priority:
            return [3, 2, 1, 0].map { p in
                TaskColumn(id: "p\(p)", title: L(Priority.titles[p] ?? "Без приоритета"), dot: p > 0 ? Priority.color(p) : nil,
                           tasks: open.filter { $0.priority == p },
                           drop: { $0.setPriority(p, for: $1) },
                           add: { $0.addTask($1, projectID: $0.draftProjectID, priority: p) })
            }
        case .project:
            var result = store.activeProjects.map { project in
                TaskColumn(id: project.id.uuidString, title: project.label, dot: project.color.color,
                           tasks: open.filter { $0.projectID == project.id },
                           drop: { $0.setProject(project.id, for: $1) },
                           add: { $0.addTask($1, projectID: project.id) },
                           hidesWhenEmpty: true)
            }
            // Задачи архивных проектов не теряем: они уходят в общую колонку.
            let known = Set(store.activeProjects.map(\.id))
            result.append(TaskColumn(id: "none", title: L("Без проекта"),
                                     tasks: open.filter { $0.projectID.map { !known.contains($0) } ?? true },
                                     drop: { $0.setProject(nil, for: $1) },
                                     add: { $0.addTask($1, projectID: nil) },
                                     hidesWhenEmpty: true))
            return result
        case .due:
            let today = Cal.ru.startOfDay(for: now)
            let tomorrow = Cal.ru.date(byAdding: .day, value: 1, to: today) ?? today
            let afterTomorrow = Cal.ru.date(byAdding: .day, value: 1, to: tomorrow) ?? tomorrow
            let nextWeek = Cal.ru.date(byAdding: .day, value: 7, to: today) ?? today
            func day(_ t: TodoTask) -> Date? { t.due.map { Cal.ru.startOfDay(for: $0) } }
            func late(_ t: TodoTask) -> Bool { t.due.map { DueDate.isOverdue($0, minutes: t.dueMinutes, now: now) } ?? false }
            func target(_ date: Date?) -> (Store, UUID) -> Void { { $0.setDue(date, for: $1) } }
            func adding(_ date: Date?) -> (Store, String) -> Void {
                { $0.addTask($1, projectID: $0.draftProjectID, due: date) }
            }
            return [
                TaskColumn(id: "late", title: L("Просрочено"), dot: Color(nsColor: .systemRed), tasks: open.filter(late)),
                TaskColumn(id: "today", title: L("Сегодня"), dot: .accentColor,
                           tasks: open.filter { !late($0) && day($0) == today }, drop: target(today), add: adding(today)),
                TaskColumn(id: "tomorrow", title: L("Завтра"),
                           tasks: open.filter { !late($0) && day($0) == tomorrow }, drop: target(tomorrow), add: adding(tomorrow)),
                TaskColumn(id: "later", title: L("Позже"),
                           tasks: open.filter { !late($0) && (day($0).map { $0 >= afterTomorrow } ?? false) },
                           drop: target(nextWeek), add: adding(nextWeek)),
                TaskColumn(id: "none", title: L("Без срока"), tasks: open.filter { $0.due == nil },
                           drop: target(nil), add: adding(nil)),
            ]
        }
    }
}

extension Store {
    /// Колонки «Сделать» и «В работе». Выполненная задача при этом снова становится открытой.
    func moveTask(_ id: UUID, inProgress: Bool) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].done = false
        tasks[i].inProgress = inProgress
    }

    /// Колонка «Готово»: то же, что щелчок по кружку, с возможностью отменить.
    func completeTask(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }), !task.done else { return }
        toggleTask(id)
    }
}

// MARK: - Доска

/// Доска как в Notion: колонка по высоте содержимого, заголовок меткой, под карточками добавление.
struct TaskBoardView: View {
    let layout: TaskLayout
    @EnvironmentObject var store: Store

    var body: some View {
        let columns = TaskBoard.columns(layout, store: store)
        let shown = columns.filter { !$0.hidesWhenEmpty || !$0.tasks.isEmpty }
        let empty = columns.filter { $0.hidesWhenEmpty && $0.tasks.isEmpty }
        GeometryReader { geo in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(shown) { TaskColumnView(column: $0, layout: layout) }
                    if !empty.isEmpty { EmptyColumnsList(columns: empty) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
            }
        }
    }
}

/// Цвет метки колонки. Без своего цвета метка нейтральная.
private func columnTint(_ column: TaskColumn) -> Color { column.dot ?? Color.primary }

private struct TaskColumnView: View {
    let column: TaskColumn
    let layout: TaskLayout
    @EnvironmentObject var store: Store
    @State private var targeted = false
    @State private var isAdding = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            VStack(spacing: 6) {
                ForEach(column.tasks) { TaskCard(task: $0, layout: layout) }
            }
            if column.add != nil { addRow }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(columnTint(column).opacity(targeted ? 0.14 : 0.05)))
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
            }
        }
        // Бросить можно и ниже карточек, поэтому цель занимает всю высоту доски, хотя колонка по содержимому.
        .frame(width: 272, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let drop = column.drop else { return false }
            let ids = items.compactMap(UUID.init(uuidString:))
            guard !ids.isEmpty else { return false }
            withAnimation(.snappy) { ids.forEach { drop(store, $0) } }
            return true
        } isTargeted: { targeted = $0 && column.drop != nil }
    }

    private var header: some View {
        HStack(spacing: 7) {
            HStack(spacing: 5) {
                if let dot = column.dot {
                    Circle().fill(dot).frame(width: 7, height: 7)
                }
                Text(verbatim: column.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(columnTint(column).opacity(0.16)))
            Text(verbatim: "\(column.tasks.count)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var addRow: some View {
        if isAdding {
            TextField("", text: $draft, prompt: Text("Название задачи"))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($fieldFocused)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08)))
                .onAppear { DispatchQueue.main.async { fieldFocused = true } }
                .onSubmit(commit)
                .onExitCommand { close() }
                .onChange(of: fieldFocused) { if !fieldFocused { commit(); close() } }
        } else {
            BoardGhostButton {
                isAdding = true
            }
        }
    }

    private func commit() {
        guard !draft.trimmed.isEmpty, let add = column.add else { return }
        withAnimation(.snappy) { add(store, draft) }
        draft = ""
        fieldFocused = true
    }

    private func close() {
        draft = ""
        isAdding = false
    }
}

/// «+ Новая задача» под карточками: тихая строка, как в Notion.
private struct BoardGhostButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(icon: "plus", size: 12)
                Text("Новая задача")
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .foregroundStyle(Color.primary.opacity(hover ? 0.75 : 0.42))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hover ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Пустые колонки не занимают доску: они списком справа, и на строку можно бросить карточку.
private struct EmptyColumnsList: View {
    let columns: [TaskColumn]
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Пустые")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(height: 22)
                .padding(.horizontal, 8)
            ForEach(columns) { EmptyColumnRow(column: $0) }
        }
        .padding(8)
        .frame(width: 210, alignment: .topLeading)
    }
}

private struct EmptyColumnRow: View {
    let column: TaskColumn
    @EnvironmentObject var store: Store
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(column.dot ?? Color.primary.opacity(0.25))
                .frame(width: 7, height: 7)
            Text(verbatim: column.title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor.opacity(targeted ? 0.2 : 0)))
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let drop = column.drop else { return false }
            let ids = items.compactMap(UUID.init(uuidString:))
            withAnimation(.snappy) { ids.forEach { drop(store, $0) } }
            return !ids.isEmpty
        } isTargeted: { targeted = $0 }
    }
}

private struct TaskCard: View {
    let task: TodoTask
    let layout: TaskLayout
    @EnvironmentObject var store: Store
    @AppStorage("extra.dueDates") private var dueOn = false
    @State private var checking = false
    @State private var hover = false
    @State private var renaming = false
    @State private var newTitle = ""

    /// По этой задаче сейчас идёт таймер.
    private var isRunning: Bool {
        store.running.map { $0.title == task.title && $0.projectID == task.projectID } ?? false
    }

    private var isDone: Bool { task.done || checking }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            EmojiText(emoji: task.emoji, text: task.title)
                .font(.system(size: 13, weight: .medium))
                .strikethrough(isDone)
                .foregroundStyle(isDone ? .secondary : .primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, hover ? 48 : 0)
            properties
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.12 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isRunning ? Color.accentColor : Color.primary.opacity(hover ? 0.16 : 0.09), lineWidth: isRunning ? 1.5 : 1))
        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
        .overlay(alignment: .topTrailing) {
            if hover && !isDone { actions } else if hover { reopen }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hover = $0 }
        .draggable(task.id.uuidString)
        .onTapGesture(count: 2) {
            newTitle = task.title
            renaming = true
        }
        .contextMenu {
            if !task.done {
                Button("Начать") { store.start(title: task.title, projectID: task.projectID, emoji: task.emoji) }
            }
            Button("Переименовать…") {
                newTitle = task.title
                renaming = true
            }
            PriorityPicker(task: task)
            TaskProjectMenu(task: task)
            Divider()
            Button("Удалить", role: .destructive) { store.deleteTask(task.id) }
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

    /// Свойства метками. То, по чему собрана доска, не повторяем: оно уже в заголовке колонки.
    @ViewBuilder private var properties: some View {
        let project = layout == .project ? nil : store.project(task.projectID)
        let priority = layout == .priority ? 0 : task.priority
        let due = layout == .due || !dueOn || task.done ? nil : task.due
        if project != nil || priority > 0 || due != nil || isRunning {
            // Метки переносятся по строкам только в крайнем случае: их обычно одна-две.
            HStack(spacing: 5) {
                if isRunning {
                    chip(L("Идёт"), tint: .accentColor)
                }
                if let project {
                    chip(project.name, tint: project.color.color)
                }
                if priority > 0 {
                    chip(L(Priority.titles[priority] ?? ""), tint: Priority.color(priority))
                }
                if let due {
                    Text(verbatim: DueDate.text(due, minutes: task.dueMinutes))
                        .font(.system(size: 11))
                        .foregroundStyle(DueDate.color(due, minutes: task.dueMinutes))
                        .lineLimit(1)
                }
            }
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.opacity(0.2)))
    }

    /// Действия появляются над карточкой при наведении.
    private var actions: some View {
        HStack(spacing: 0) {
            cardButton(isRunning ? "square" : "play", help: isRunning ? L("Стоп") : L("Начать"), size: 11) {
                if isRunning {
                    store.stop()
                } else {
                    store.start(title: task.title, projectID: task.projectID, emoji: task.emoji)
                }
            }
            cardButton("check", help: L("Выполнить"), size: 13) {
                withAnimation(.snappy) { checking = true }
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(.snappy) { store.toggleTask(task.id) }
                    checking = false
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .padding(5)
    }

    private var reopen: some View {
        cardButton("undo", help: L("Вернуть"), size: 12) {
            withAnimation(.snappy) { store.toggleTask(task.id) }
        }
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .padding(5)
    }

    private func cardButton(_ icon: String, help: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(icon: icon, size: size)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
