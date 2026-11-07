import SwiftUI

// MARK: - Умный ввод

/// Разбирает строку вроде «созвон @клиент 30м !!»: проект, таймер, приоритет и срок задачи.
/// Неузнанное остаётся в названии как есть: новый проект из опечатки не создаём.
enum SmartInput {
    struct Parsed: Equatable {
        var title: String
        var projectID: UUID?
        var minutes: Int?
        var priority: Int?
        var due: Date?
    }

    static func parse(_ text: String, projects: [Project], allowDue: Bool = false, now: Date = Date()) -> Parsed {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var result = Parsed(title: "")

        if let (range, id) = projectMatch(words, projects: projects) {
            result.projectID = id
            words.removeSubrange(range)
        }

        var rest: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            index += 1
            // «30 мин» с пробелом: цифры и единица отдельными словами.
            if result.minutes == nil, word.allSatisfy(\.isNumber), index < words.count,
               !words[index].contains(where: \.isNumber), let minutes = minutes(word + words[index]) {
                result.minutes = minutes
                index += 1
            } else if result.minutes == nil, let minutes = minutes(word) {
                result.minutes = minutes
            } else if result.priority == nil, (1 ... 3).contains(word.count), word.allSatisfy({ $0 == "!" }) {
                result.priority = word.count
            } else if allowDue, result.due == nil, let due = due(word, now: now) {
                result.due = due
            } else {
                rest.append(word)
            }
        }
        result.title = rest.joined(separator: " ")
        return result
    }

    /// Точное имя важнее начала имени; проект из нескольких слов: «@Мой клиент».
    private static func projectMatch(_ words: [String], projects: [Project]) -> (Range<Int>, UUID)? {
        guard let start = words.firstIndex(where: { $0.hasPrefix("@") && $0.count > 1 }) else { return nil }
        let first = String(words[start].dropFirst())
        for end in stride(from: words.count, to: start, by: -1) {
            let name = ([first] + words[(start + 1) ..< end]).joined(separator: " ")
            if let p = projects.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return (start ..< end, p.id)
            }
        }
        let byPrefix = projects.filter { $0.name.lowercased().hasPrefix(first.lowercased()) }
        guard byPrefix.count == 1 else { return nil }
        return (start ..< start + 1, byPrefix[0].id)
    }

    private static let minuteUnit = "(?:м|мин|минут|минуты|минута|хв|хвилин|хвилини|хвилина|m|min)"
    private static let hourUnit = "(?:ч|час|часа|часов|год|годин|години|година|h|hr)"

    /// 30м, 45min, 2ч, 1h, 1ч30м, 1ч30. Голое число остаётся в названии: «звонок 3» — не таймер.
    static func minutes(_ word: String) -> Int? {
        let lower = word.lowercased()
        func groups(_ pattern: String) -> [Int]? {
            guard let regex = try? NSRegularExpression(pattern: "^\(pattern)$"),
                  let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) else { return nil }
            return (1 ..< match.numberOfRanges).compactMap {
                Range(match.range(at: $0), in: lower).flatMap { Int(lower[$0]) }
            }
        }
        var total: Int?
        if let g = groups("(\\d{1,3})\(minuteUnit)"), let m = g.first {
            total = m
        } else if let g = groups("(\\d{1,2})\(hourUnit)(?:(\\d{1,2})\(minuteUnit)?)?"), let h = g.first {
            total = h * 60 + (g.count > 1 ? g[1] : 0)
        }
        guard let total, (1 ... 720).contains(total) else { return nil }
        return total
    }

    private static func due(_ word: String, now: Date) -> Date? {
        let offset: Int
        switch word.lowercased() {
        case "сегодня", "сьогодні", "today": offset = 0
        case "завтра", "tomorrow": offset = 1
        case "послезавтра", "післязавтра": offset = 2
        default: return nil
        }
        return Cal.ru.date(byAdding: .day, value: offset, to: now)
    }
}

// MARK: - Подсказки

extension SmartInput {
    enum Suggestion: Identifiable, Equatable {
        case project(Project)
        case newProject(String)
        case minutes(Int)

        var id: String {
            switch self {
            case let .project(p): "p\(p.id)"
            case let .newProject(name): "n\(name)"
            case let .minutes(m): "m\(m)"
            }
        }
    }

    /// Что предложить к слову, которое сейчас набирают. После пробела слово закончено, подсказок нет.
    static func suggestions(for text: String, projects: [Project]) -> [Suggestion] {
        guard let last = text.last, !last.isWhitespace,
              let word = text.split(whereSeparator: \.isWhitespace).last.map(String.init) else { return [] }
        if word.hasPrefix("@") {
            let query = word.dropFirst().lowercased()
            let found = projects
                .filter { query.isEmpty || $0.name.lowercased().contains(query) }
                .sorted { $0.name.lowercased().hasPrefix(query) && !$1.name.lowercased().hasPrefix(query) }
            var result = found.prefix(5).map(Suggestion.project)
            // Новый проект предлагаем, только когда похожего нет: иначе опечатка плодит проекты.
            if !query.isEmpty, found.isEmpty {
                result.append(.newProject(String(word.dropFirst())))
            }
            return Array(result)
        }
        guard word.allSatisfy(\.isNumber), let number = Int(word), (1 ... 720).contains(number) else { return [] }
        return number <= 12 ? [.minutes(number), .minutes(number * 60)] : [.minutes(number)]
    }

    /// Заменяет набираемое слово выбранной подсказкой.
    static func applying(_ token: String, to text: String) -> String {
        var head = text
        while let last = head.last, !last.isWhitespace { head.removeLast() }
        return head + token + " "
    }

    static func token(minutes: Int) -> String {
        minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
    }
}

extension Store {
    /// Новый проект из подсказки или выбранный: в строке остаётся «@Имя ».
    func accept(_ suggestion: SmartInput.Suggestion) {
        switch suggestion {
        case let .project(p):
            currentTitle = SmartInput.applying("@\(p.name)", to: currentTitle)
        case let .newProject(name):
            let p = addProject(name: name, color: nextColor())
            currentTitle = SmartInput.applying("@\(p.name)", to: currentTitle)
        case let .minutes(m):
            currentTitle = SmartInput.applying(SmartInput.token(minutes: m), to: currentTitle)
        }
    }

    /// Enter при идущей записи: проект и таймер применяются сразу, в названии остаётся только текст.
    func applySmartInputToRunning(now: Date = Date()) {
        guard let i = runningIndex else { return }
        let parsed = SmartInput.parse(entries[i].title, projects: activeProjects, now: now)
        guard parsed.projectID != nil || parsed.minutes != nil else { return }
        entries[i].title = parsed.title
        if let id = parsed.projectID {
            entries[i].projectID = id
            draftProjectID = id
        }
        if let minutes = parsed.minutes {
            entries[i].planned = entries[i].duration(at: now) + TimeInterval(minutes * 60)
        }
    }
}

/// Под строкой ввода: подсказки к набираемому слову, а если их нет — что Hourfox уже понял.
struct SmartInputBar: View {
    let onPick: () -> Void
    @EnvironmentObject var store: Store

    var body: some View {
        let text = store.currentTitle
        let suggestions = SmartInput.suggestions(for: text, projects: store.activeProjects)
        let parsed = SmartInput.parse(text, projects: store.activeProjects)
        if !suggestions.isEmpty {
            HStack(spacing: 6) {
                ForEach(suggestions) { suggestion in
                    Button {
                        store.accept(suggestion)
                        onPick()
                    } label: {
                        chip(suggestion)
                    }
                    .buttonStyle(PressScaleStyle())
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, -6)
        } else if parsed.projectID != nil || parsed.minutes != nil {
            HStack(spacing: 12) {
                if let project = store.project(parsed.projectID) {
                    HStack(spacing: 5) {
                        Circle().fill(project.color.color).frame(width: 6, height: 6)
                        Text(verbatim: project.name)
                    }
                }
                if let minutes = parsed.minutes {
                    HStack(spacing: 4) {
                        Image(icon: "timer", size: 15)
                        Text(verbatim: Fmt.minutes(minutes))
                    }
                }
                Spacer()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.notchInk.opacity(0.6))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.top, -6)
        }
    }

    private func chip(_ suggestion: SmartInput.Suggestion) -> some View {
        HStack(spacing: 5) {
            switch suggestion {
            case let .project(p):
                Circle().fill(p.color.color).frame(width: 6, height: 6)
                EmojiText(emoji: p.emoji, text: p.name)
            case let .newProject(name):
                Image(icon: "plus", size: 9)
                Text(verbatim: L("Новый проект «%@»", name))
            case let .minutes(m):
                Image(icon: "timer", size: 15)
                Text(verbatim: Fmt.minutes(m))
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.notchInk.opacity(0.85))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(.notchInk.opacity(0.1)))
        .contentShape(Capsule())
    }
}
