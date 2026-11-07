import SwiftUI

// MARK: - Архив

/// Всё, что удаляли, и проекты, убранные в архив. Вернуть можно в один щелчок, а удалить навсегда только отсюда.
struct ArchiveView: View {
    @ObservedObject var nav: JournalNav
    @EnvironmentObject var store: Store
    @State private var pending: Erase?
    @State private var confirmAll = false

    /// Что удаляем навсегда: вопрос задаётся один раз перед действием.
    private struct Erase: Identifiable {
        let id = UUID()
        let title: String
        let action: () -> Void
    }

    private var isEmpty: Bool { store.archiveCount == 0 }
    private var erasableCount: Int { store.archiveCount - store.archivedProjects.count }

    var body: some View {
        Group {
            if isEmpty {
                ContentUnavailableView {
                    Label("В архиве пусто", icon: "archive")
                } description: {
                    Text("Сюда попадает всё удалённое. Удалить окончательно можно только отсюда.")
                }
            } else {
                List {
                    if !store.archivedProjects.isEmpty || !store.archive.projects.isEmpty {
                        Section("Проекты") {
                            ForEach(store.archivedProjects) { p in
                                row(title: p.label, detail: p.archivedAt.map(dateText) ?? "", dot: p.color.color, open: { nav.selection = .project(p.id) },
                                    restore: { store.setArchived(false, for: p.id) }) { store.eraseProject(p.id) }
                            }
                            ForEach(store.archive.projects) { d in
                                row(title: d.project.label, detail: dateText(d.deletedAt), dot: d.project.color.color,
                                    restore: { store.restoreProject(d.id) }) { store.eraseProject(d.id) }
                            }
                        }
                    }
                    if !store.archive.entries.isEmpty {
                        Section("Записи") {
                            ForEach(store.archive.entries) { a in
                                row(title: entryTitle(a.item), detail: "\(Fmt.short(a.item.duration(at: a.deletedAt))), \(dateText(a.deletedAt))",
                                    dot: store.project(a.item.projectID)?.color.color,
                                    restore: { store.restoreEntry(a.id) }) { store.eraseEntry(a.id) }
                            }
                        }
                    }
                    if !store.archive.expenses.isEmpty {
                        Section("Расходы") {
                            ForEach(store.archive.expenses) { a in
                                row(title: a.item.title.isEmpty ? store.name(for: a.item.projectID) : a.item.title,
                                    detail: "\(Fmt.money(a.item.amount)), \(dateText(a.deletedAt))",
                                    dot: store.project(a.item.projectID)?.color.color,
                                    restore: { store.restoreExpense(a.id) }) { store.eraseExpense(a.id) }
                            }
                        }
                    }
                    if !store.archive.tasks.isEmpty {
                        Section("Задачи") {
                            ForEach(store.archive.tasks) { a in
                                row(title: a.item.label, detail: dateText(a.deletedAt), dot: store.project(a.item.projectID)?.color.color,
                                    restore: { store.restoreTask(a.id) }) { store.eraseTask(a.id) }
                            }
                        }
                    }
                    if !store.archive.notes.isEmpty {
                        Section("Заметки") {
                            ForEach(store.archive.notes) { a in
                                row(title: a.item.title, detail: dateText(a.deletedAt), dot: nil,
                                    restore: { store.restoreNote(a.id) }) { store.eraseNote(a.id) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(L("Архив"))
        .navigationSubtitle(isEmpty ? "" : "\(store.archiveCount)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { confirmAll = true } label: {
                    Label("Очистить архив", icon: "trash-2")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(erasableCount == 0)
            }
        }
        .confirmationDialog(L("Удалить навсегда?"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { erase in
            Button(L("Удалить навсегда"), role: .destructive) { erase.action() }
        } message: { erase in
            Text(verbatim: "\(erase.title). \(L("Это нельзя отменить."))")
        }
        .confirmationDialog(L("Очистить архив?"), isPresented: $confirmAll) {
            Button(L("Удалить навсегда"), role: .destructive) { store.eraseArchive() }
        } message: {
            Text(verbatim: L("Всё удалённое исчезнет. Это нельзя отменить."))
        }
    }

    private func entryTitle(_ e: Entry) -> String {
        e.title.isEmpty ? store.name(for: e.projectID) : e.title
    }

    private func dateText(_ d: Date) -> String {
        "\(Fmt.dayShort.string(from: d)), \(Fmt.hhmm.string(from: d))"
    }

    private func row(title: String, detail: String, dot: Color?, open: (() -> Void)? = nil, restore: @escaping () -> Void, erase: @escaping () -> Void) -> some View {
        ArchiveRow(title: title, detail: detail, dot: dot, open: open, restore: {
            withAnimation(.snappy) { restore() }
        }, erase: {
            pending = Erase(title: title) { withAnimation(.snappy) { erase() } }
        })
    }
}

private struct ArchiveRow: View {
    let title: String
    let detail: String
    let dot: Color?
    let open: (() -> Void)?
    let restore: () -> Void
    let erase: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dot ?? Color.primary.opacity(0.2))
                .frame(width: 8, height: 8)
            Text(verbatim: title)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(verbatim: detail)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button(action: restore) {
                Image(icon: "undo", size: 13)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Вернуть")
            Button(action: erase) {
                Image(icon: "trash-2", size: 13)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hover ? 1 : 0.35)
            .help("Удалить навсегда")
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { open?() }
    }
}
