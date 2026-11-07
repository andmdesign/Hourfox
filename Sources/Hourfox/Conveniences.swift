import AppKit
import SwiftUI

// MARK: - Отмена удаления

struct UndoOffer: Identifiable {
    let id = UUID()
    let message: String
    let restore: () -> Void
}

/// Несколько секунд после удаления: что случилось и кнопка «Отменить».
struct UndoBar: View {
    enum Style { case notch, window }

    let style: Style
    @EnvironmentObject var store: Store

    var body: some View {
        if let offer = store.undoOffer {
            switch style {
            case .notch:
                HStack(spacing: 10) {
                    Text(verbatim: offer.message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.notchInk.opacity(0.7))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button { withAnimation(.snappy) { store.performUndo() } } label: {
                        Text("Отменить")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.notchInk)
                            .padding(.horizontal, 11)
                            .frame(height: 24)
                            .background(Capsule().fill(.notchInk.opacity(0.12)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressScaleStyle())
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.notchInk.opacity(0.06)))
            case .window:
                HStack(spacing: 14) {
                    Text(verbatim: offer.message)
                        .lineLimit(1)
                    Button("Отменить") { withAnimation(.snappy) { store.performUndo() } }
                        .keyboardShortcut("z")
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .frame(height: 42)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            }
        }
    }
}

// MARK: - Свой цвет проекта

/// Системная панель цветов. Держит того, кто её открыл, пока панель не закроют.
final class ColorPanelBridge: NSObject {
    private static let shared = ColorPanelBridge()
    private var onChange: ((NSColor) -> Void)?

    static var isOpen: Bool { NSColorPanel.sharedColorPanelExists && NSColorPanel.shared.isVisible }

    static func open(initial: NSColor, onChange: @escaping (NSColor) -> Void) {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.color = initial
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.hidesOnDeactivate = false
        // Выше окна Notch, которое стоит над строкой меню.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        shared.onChange = onChange
        panel.setTarget(shared)
        panel.setAction(#selector(changed(_:)))
        panel.orderFrontRegardless()
    }

    static func close() {
        guard NSColorPanel.sharedColorPanelExists else { return }
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.orderOut(nil)
        shared.onChange = nil
    }

    @objc private func changed(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}

/// Все цвета проекта в один ряд и в конце кружок, который открывает панель цветов.
struct ProjectColorRow: View {
    @Binding var selection: ProjectColor
    let side: CGFloat
    let ring: AnyShapeStyle

    private let spectrum = AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ProjectColor.allCases) { c in
                Circle()
                    .fill(c.color)
                    .frame(width: side, height: side)
                    .overlay(selectionRing(selection == c))
                    .padding(4)
                    .contentShape(Circle())
                    .onTapGesture {
                        ColorPanelBridge.close()
                        selection = c
                    }
            }
            Group {
                if selection.isCustom {
                    Circle().fill(selection.color)
                } else {
                    Circle().fill(spectrum)
                }
            }
            .frame(width: side, height: side)
            .overlay(selectionRing(selection.isCustom))
            .padding(4)
            .contentShape(Circle())
            .onTapGesture {
                let binding = $selection
                ColorPanelBridge.open(initial: selection.nsColor) { binding.wrappedValue = .custom($0) }
            }
            .help("Другой цвет")
        }
    }

    private func selectionRing(_ on: Bool) -> some View {
        Circle().strokeBorder(ring, lineWidth: on ? 2 : 0).padding(-4)
    }
}

// MARK: - Разделение записи

struct SplitEntrySheet: View {
    let entry: Entry
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var time: Date
    @State private var secondTitle: String

    init(entry: Entry) {
        self.entry = entry
        let end = entry.end ?? entry.start
        _time = State(initialValue: entry.start.addingTimeInterval(end.timeIntervalSince(entry.start) / 2))
        _secondTitle = State(initialValue: entry.title)
    }

    private var end: Date { entry.end ?? entry.start }
    private var isValid: Bool { time > entry.start && time < end }

    private var minutesBinding: Binding<Int> {
        Binding(get: { EntryTimes.minutes(of: time) }, set: { time = EntryTimes.moment(in: entry, minutes: $0) })
    }

    var body: some View {
        HourfoxSheet(title: L("Разделить запись"), width: 400) {
            FormCard {
                FormRow(title: "Разделить в") { TimeField(minutes: minutesBinding) }
                FormLine()
                FormRow(title: "Первая часть") {
                    Text(verbatim: "\(Fmt.hhmm.string(from: entry.start))–\(Fmt.hhmm.string(from: time))").monospacedDigit()
                }
                FormLine()
                FormRow(title: "Вторая часть") {
                    Text(verbatim: "\(Fmt.hhmm.string(from: time))–\(Fmt.hhmm.string(from: end))").monospacedDigit()
                }
                FormLine()
                TextField("", text: $secondTitle, prompt: Text("Название второй части"))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
            }
        } buttons: {
            Spacer()
            Button("Отмена") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Разделить") {
                store.splitEntry(entry.id, at: time, secondTitle: secondTitle)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid)
        }
    }
}

// MARK: - Автобэкапы

/// Раз в день копия данных: <папка данных>/backups/data-ГГГГ-ММ-ДД.json. Хранятся последние 30 копий.
enum Backups {
    static let keep = 30

    static func directory(for dataFile: URL) -> URL {
        dataFile.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func run(dataFile: URL, now: Date = Date()) {
        // Повреждённый файл в копию не берём, иначе он вытеснит хорошие.
        guard let data = try? Data(contentsOf: dataFile), (try? JSONSerialization.jsonObject(with: data)) != nil else { return }
        let dir = directory(for: dataFile)
        let today = dir.appendingPathComponent("data-\(dayFormat.string(from: now)).json")
        let manager = FileManager.default
        guard !manager.fileExists(atPath: today.path) else { return }
        do {
            try manager.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: today, options: .atomic)
        } catch {
            NSLog("Hourfox: не удалось сохранить копию данных: \(error.localizedDescription)")
            return
        }
        prune(dir)
    }

    private static func prune(_ dir: URL) {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: dir.path)) ?? []
        // Имя с датой сортируется по времени. Чужие файлы в папке не трогаем.
        let copies = names
            .filter { $0.hasPrefix("data-") && $0.hasSuffix(".json") && dayFormat.date(from: String($0.dropFirst(5).dropLast(5))) != nil }
            .sorted()
        for name in copies.dropLast(keep) {
            try? manager.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
