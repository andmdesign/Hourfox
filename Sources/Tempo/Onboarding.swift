import AppKit
import ServiceManagement
import SwiftUI

/// Экран приветствия при первом запуске. Повторно — из меню ⋯ → «Знакомство с Tempo».
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onFinish: () -> Void

    static var isDone: Bool {
        get { UserDefaults.standard.bool(forKey: "onboardingDone") }
        set { UserDefaults.standard.set(newValue, forKey: "onboardingDone") }
    }

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func show() {
        if window == nil {
            let view = Localized { OnboardingView { [weak self] in self?.finish() } }
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            // Цвет под заголовком окна: меняется вместе с темой.
            w.backgroundColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white }
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        window?.close()
    }

    // Закрыли крестиком или кнопкой «Начать» — считаем знакомство пройденным.
    func windowWillClose(_ notification: Notification) {
        Self.isDone = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [onFinish] in onFinish() }
    }
}

struct OnboardingView: View {
    let start: () -> Void
    @State private var customizing = false

    var body: some View {
        Group {
            if customizing {
                OnboardingCustomizeView(back: { withAnimation(.snappy) { customizing = false } }, start: start)
                    .transition(.opacity)
            } else {
                OnboardingWelcomeView { withAnimation(.snappy) { customizing = true } }
                    .transition(.opacity)
            }
        }
        .frame(width: 880, height: 680)
        .background(.notchPaper)
    }
}

/// Кнопка внизу экранов знакомства.
private struct OnboardingButton: View {
    let title: LocalizedStringKey
    var width: CGFloat = 220
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.notchPaper)
                .frame(width: width, height: 44)
                .background(Capsule().fill(.notchInk))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .keyboardShortcut(.defaultAction)
    }
}

/// «Настройте Tempo под себя»: только названия и выключатели, а показать функцию можно наведением на значок info.
struct OnboardingCustomizeView: View {
    let back: () -> Void
    let start: () -> Void
    @State private var calendarOn = CalendarSync.shared.isEnabled
    private var heading: some View {
        VStack(spacing: 8) {
            Text("Настройте Tempo под себя")
                .font(.system(size: 30, weight: .semibold))
                .kerning(-0.4)
                .foregroundStyle(.notchInk)
            Text("Включите только то, что нужно. Всё можно поменять позже в\u{00A0}настройках.")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 34)
        .padding(.bottom, 10)
    }

    var body: some View {
        Form {
            ForEach(ExtraGroup.allCases) { group in
                Section {
                    ForEach(group.extras.filter(\.inOnboarding)) { OnboardingExtraRow(extra: $0) }
                } header: {
                    SectionHeaderWithTop(top: group == ExtraGroup.allCases.first ? AnyView(heading) : nil, title: L(group.title))
                }
            }
            OnboardingAppearanceSection()
            Section("Интеграции") {
                OnboardingRow(title: "Показывать в\u{00A0}Календаре", subtitle: "Завершённые записи — в\u{00A0}календаре «Tempo»", symbol: "calendar", demo: .calendar) {
                    Toggle("Показывать в\u{00A0}Календаре", isOn: Binding(get: { calendarOn }, set: { on in
                        calendarOn = on
                        CalendarSync.shared.setEnabled(on) { calendarOn = $0 }
                    }))
                    .labelsHidden()
                }
            }
            if GoogleCalendar.isConfigured {
                GoogleCalendarSettings()
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        // Настройки уходят под кнопки плавно, без резкой границы.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Две кнопки одного размера, ровно по центру окна.
            HStack(spacing: 10) {
                Button(action: back) {
                    Text("Назад")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.notchInk)
                        .frame(width: 170, height: 44)
                        .background(Capsule().fill(.notchInk.opacity(0.1)))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle())
                OnboardingButton(title: "Начать", width: 170, action: start)
            }
            .padding(.top, 34)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity)
            .background(fade)
        }
    }

    private var fade: some View {
        Rectangle()
            .fill(.notchPaper)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.32)], startPoint: .top, endPoint: .bottom))
    }
}

/// Оформление показывает себя сразу: тема, сияние и стекло меняют Notch прямо в этой секции.
struct OnboardingAppearanceSection: View {
    @AppStorage(Aurora.key) private var aurora = false
    @AppStorage(GlassStyle.key) private var glass = false

    private static let scale: CGFloat = 0.82

    var body: some View {
        Section("Оформление") {
            OnboardingStage(scene: .notch)
                .scaleEffect(Self.scale, anchor: .topLeading)
                .frame(width: OnboardingStage.size.width * Self.scale,
                       height: OnboardingStage.size.height * Self.scale,
                       alignment: .topLeading)
                .frame(maxWidth: .infinity)
            OnboardingRow(title: "Тема", symbol: "contrast") {
                ThemeButtons()
            }
            OnboardingRow(title: "Сияние", symbol: "sparkles") {
                Toggle("Сияние", isOn: $aurora.animation(.snappy)).labelsHidden()
            }
            OnboardingRow(title: "Стекло", symbol: "droplet") {
                Toggle("Стекло", isOn: $glass.animation(.snappy)).labelsHidden()
            }
        }
    }
}

/// Функция из «Дополнительно»: выключатель, а если включена, её настройка под строкой.
private struct OnboardingExtraRow: View {
    let extra: Extra
    @AppStorage private var isOn: Bool

    init(extra: Extra) {
        self.extra = extra
        _isOn = AppStorage(wrappedValue: false, extra.key)
    }

    private var demo: OnboardingDemo {
        switch extra {
        case .smartInput: .smartInput
        case .goal: .goal
        case .dueDates: .dueDates
        case .rates: .rates
        case .clientReport, .autoReport, .closeMonths, .yearReview: .report
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            OnboardingRow(title: extra.title, subtitle: extra.subtitle, symbol: extra.symbol, demo: demo) {
                Toggle(L(extra.title), isOn: $isOn.animation(.snappy)).labelsHidden()
            }
            if isOn {
                ExtraOptions(extra: extra)
                    .padding(.leading, 34)
                    .transition(.opacity)
            }
        }
    }
}

private struct OnboardingRow<Control: View>: View {
    let title: String
    var subtitle = ""
    let symbol: String
    /// Подсказка по значку info. Без неё значка нет: функция видна прямо в секции.
    var demo: OnboardingDemo?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 10) {
            SettingIcon(name: symbol)
            Text(L(title))
            if let demo { OnboardingInfo(subtitle: subtitle, demo: demo) }
            Spacer(minLength: 12)
            control()
        }
        .frame(minHeight: 30)
    }
}

/// Значок info: наведение показывает функцию в работе. Щелчок тоже открывает.
private struct OnboardingInfo: View {
    let subtitle: String
    let demo: OnboardingDemo
    @State private var hover = false
    @State private var pinned = false

    var body: some View {
        Button { pinned.toggle() } label: {
            Image(icon: "info", size: 15)
                .foregroundStyle(hover || pinned ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .popover(isPresented: Binding(get: { hover || pinned }, set: { if !$0 { hover = false; pinned = false } }), arrowEdge: .trailing) {
            OnboardingDemoCard(demo: demo, subtitle: subtitle)
        }
    }
}

enum OnboardingDemo: CaseIterable {
    case smartInput, goal, dueDates, rates, report, calendar
}

/// Содержимое подсказки: функция на маленьком примере и одна строка пояснения.
struct OnboardingDemoCard: View {
    let demo: OnboardingDemo
    let subtitle: String

    private let design = Color(nsColor: .systemOrange)
    private let client = Color(nsColor: .systemBlue)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            Text(L(subtitle))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 372, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        switch demo {
        case .smartInput: smartInput
        case .goal: goal
        case .dueDates: dueDates
        case .rates: rates
        case .report: report
        case .calendar: calendar
        }
    }

    private func surface(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.notchInk.opacity(0.06)))
    }

    private var smartInput: some View {
        surface {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "\(L("Созвон по ТЗ")) @\(L("Клиент А")) 30m")
                    .font(.system(size: 14))
                    .foregroundStyle(.notchInk)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.notchInk.opacity(0.09)))
                HStack(spacing: 12) {
                    HStack(spacing: 5) {
                        Circle().fill(client).frame(width: 6, height: 6)
                        Text(verbatim: L("Клиент А"))
                    }
                    HStack(spacing: 4) {
                        Image(icon: "timer", size: 12)
                        Text(verbatim: Fmt.minutes(30))
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.notchInk.opacity(0.6))
                .padding(.leading, 4)
            }
        }
    }

    private var goal: some View {
        surface {
            HStack(spacing: 8) {
                GoalRing(progress: 0.68)
                Text(verbatim: Fmt.short(14700)).foregroundStyle(.notchInk.opacity(0.9))
                Text(verbatim: "/ \(Fmt.short(21600))").foregroundStyle(.notchInk.opacity(0.45))
            }
            .font(.system(size: 14, weight: .medium))
            .monospacedDigit()
        }
    }

    private func taskRow(_ title: String, priority: Int, due: String, late: Bool = false) -> some View {
        HStack(spacing: 9) {
            TaskCheckmark(priority: priority, done: false, side: 14, ink: AnyShapeStyle(.notchInk.opacity(0.4)), doneColor: .clear)
            Text(verbatim: title).foregroundStyle(.notchInk.opacity(0.85))
            Spacer(minLength: 8)
            Text(verbatim: due)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(late ? AnyShapeStyle(Color(nsColor: .systemRed)) : AnyShapeStyle(.notchInk.opacity(0.5)))
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .frame(height: 26)
    }

    private var dueDates: some View {
        surface {
            VStack(spacing: 2) {
                taskRow(L("Обновить резюме"), priority: 2, due: L("Вчера"), late: true)
                taskRow(L("Ответить по смете"), priority: 3, due: "\(L("Сегодня")) 14:30")
                taskRow(L("Фото для галереи"), priority: 0, due: L("Завтра"))
            }
        }
    }

    private func moneyRow(_ name: String, _ color: Color, seconds: TimeInterval, amount: Double) -> some View {
        HStack(spacing: 9) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(verbatim: name).fontWeight(.medium).foregroundStyle(.notchInk)
            Spacer(minLength: 8)
            Text(verbatim: Fmt.short(seconds)).foregroundStyle(.notchInk.opacity(0.55))
            Text(verbatim: Fmt.money(amount)).foregroundStyle(.notchInk).frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 13))
        .monospacedDigit()
        .lineLimit(1)
        .frame(height: 28)
    }

    private var rates: some View {
        surface {
            VStack(spacing: 2) {
                moneyRow(L("Дизайн"), design, seconds: 5400, amount: 90)
                moneyRow(L("Клиент А"), client, seconds: 2700, amount: 45)
            }
        }
    }

    private var report: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: L("Отчёт о работе"))
                .font(.system(size: 15, weight: .semibold))
                .padding(.bottom, 4)
            ForEach([(L("Правки главной страницы"), 5400.0), (L("Созвон по ТЗ"), 2700.0)], id: \.0) { row in
                HStack {
                    Text(verbatim: row.0).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(verbatim: Fmt.short(row.1)).foregroundStyle(Color(white: 0.45))
                }
                .font(.system(size: 12))
                Color(white: 0.87).frame(height: 0.5)
            }
            HStack {
                Text(verbatim: L("Итого"))
                Spacer()
                Text(verbatim: Fmt.short(8100))
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.top, 2)
        }
        .monospacedDigit()
        .foregroundStyle(Color(white: 0.1))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white))
    }

    private var calendar: some View {
        surface {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(verbatim: "14:00")
                    Text(verbatim: "15:00")
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.notchInk.opacity(0.4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(L("Дизайн")) · \(L("Правки главной страницы"))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.notchInk)
                        .lineLimit(1)
                    Text(verbatim: "14:20–15:50")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.notchInk.opacity(0.55))
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(design.opacity(0.22), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .leading) { design.frame(width: 3) }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }
}

/// Важные пункты показаны тем же Notch, что и в работе, поверх рабочего стола.
enum OnboardingScene: Int, CaseIterable, Identifiable {
    case notch, timer, tasks, report

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .notch: DisplayMode.current.usesMenuBar ? "Строка меню" : "Notch"
        case .timer: "Секундомер или таймер"
        case .tasks: "Задачи"
        case .report: "Журнал и\u{00A0}отчёт"
        }
    }

    var caption: String {
        switch self {
        case .notch:
            DisplayMode.current.usesMenuBar
                ? "Щёлкните значок Tempo в\u{00A0}строке меню, и\u{00A0}он раскроется."
                : "Наведите курсор на\u{00A0}вырез экрана, и\u{00A0}Tempo раскроется."
        case .timer: "Кнопка с\u{00A0}часами рядом с\u{00A0}проектом задаёт обратный отсчёт."
        case .tasks: "Список дел с\u{00A0}приоритетами во\u{00A0}вкладке «Задачи»."
        case .report: "Всё время по\u{00A0}дням и\u{00A0}проектам. Можно показывать в\u{00A0}Календаре."
        }
    }
}

struct OnboardingWelcomeView: View {
    let next: () -> Void
    @State private var scene: OnboardingScene
    /// Пока человек сам не выбрал вкладку, пункты сменяют друг друга.
    @State private var autoplay: Bool
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    init(scene: OnboardingScene = .notch, autoplay: Bool = true, next: @escaping () -> Void) {
        self.next = next
        _scene = State(initialValue: scene)
        _autoplay = State(initialValue: autoplay)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Добро пожаловать в\u{00A0}Tempo")
                .font(.system(size: 32, weight: .semibold))
                .kerning(-0.5)
                .multilineTextAlignment(.center)
                .padding(.top, 44)
            Text("Учёт времени прямо в\u{00A0}Notch")
                .font(.system(size: 16))
                .foregroundStyle(.notchInk.opacity(0.56))
                .padding(.top, 6)

            HStack(spacing: 4) {
                ForEach(OnboardingScene.allCases) { item in
                    Button {
                        autoplay = false
                        withAnimation(.snappy) { scene = item }
                    } label: {
                        Text(L(item.title))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.notchInk.opacity(scene == item ? 1 : 0.5))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(Capsule().fill(.notchInk.opacity(scene == item ? 0.14 : 0)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 22)

            OnboardingStage(scene: scene)
                .padding(.top, 18)

            Text(L(scene.caption))
                .font(.system(size: 14))
                .foregroundStyle(.notchInk.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(height: 22)
                .id(scene)
                .transition(.opacity)
                .padding(.top, 6)

            Spacer(minLength: 12)

            OnboardingButton(title: "Далее", action: next)
                .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            LanguagePicker(label: "")
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .padding(.top, 14)
                .padding(.trailing, 18)
        }
        .onReceive(timer) { _ in
            guard autoplay else { return }
            withAnimation(.snappy) {
                scene = OnboardingScene(rawValue: (scene.rawValue + 1) % OnboardingScene.allCases.count) ?? .notch
            }
        }
    }
}

/// Рабочий стол с Notch. Только показ: нажимать тут нечего.
struct OnboardingStage: View {
    let scene: OnboardingScene
    static let size = CGSize(width: 640, height: 352)
    private let menuBar = DisplayMode.current.usesMenuBar
    @AppStorage(Aurora.key) private var aurora = false
    @AppStorage(GlassStyle.key) private var glass = false
    @Environment(\.colorScheme) private var scheme

    private var showAurora: Bool { aurora }
    private var showGlass: Bool { glass }

    init(scene: OnboardingScene) {
        self.scene = scene
    }

    private var islandShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(cornerRadii: .init(topLeading: menuBar ? 26 : 0, bottomLeading: 26, bottomTrailing: 26, topTrailing: menuBar ? 26 : 0), style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .top) {
            desktop
            HStack(spacing: 16) {
                Text(verbatim: "Tempo").fontWeight(.semibold)
                Spacer()
                Text(verbatim: Fmt.hhmm.string(from: Date())).monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(scheme == .light ? Color.black.opacity(0.7) : Color.white.opacity(0.85))
            .padding(.horizontal, 14)
            .frame(height: 28)

            panel
                .frame(width: 500, alignment: .top)
                .background(island)
                .overlay {
                    if showAurora { IntelligenceGlow(shape: islandShape) }
                }
                .clipShape(islandShape)
                .animation(.snappy, value: showAurora)
                .animation(.snappy, value: showGlass)
                .padding(.top, menuBar ? 34 : 0)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .clipShape(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 16, bottomLeading: 0, bottomTrailing: 0, topTrailing: 16), style: .continuous))
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.8), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
    }

    /// Стекло в окне только изображается: настоящее размытие показывает то, что под окном, а не этот рисунок.
    private var island: some View {
        ZStack {
            islandShape.fill(.notchPaper.opacity(showGlass ? 0.42 : 1))
            if showGlass {
                islandShape.stroke(LinearGradient(colors: [.white.opacity(0.02), .white.opacity(0.14), .white.opacity(0.34)], startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
            } else if scheme == .light {
                islandShape.stroke(Color.black.opacity(0.12), lineWidth: 1)
            }
        }
    }

    private var desktop: some View {
        let light = scheme == .light
        return ZStack {
            LinearGradient(colors: light
                ? [Color(red: 0.91, green: 0.92, blue: 0.96), Color(red: 0.95, green: 0.94, blue: 0.95)]
                : [Color(red: 0.067, green: 0.075, blue: 0.11), Color(red: 0.106, green: 0.11, blue: 0.169)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [light ? Color(red: 0.74, green: 0.70, blue: 0.96) : Color(red: 0.227, green: 0.165, blue: 0.42), .clear], center: UnitPoint(x: 0.2, y: 1.1), startRadius: 0, endRadius: 400)
            RadialGradient(colors: [light ? Color(red: 0.98, green: 0.76, blue: 0.66) : Color(red: 0.478, green: 0.231, blue: 0.173), .clear], center: UnitPoint(x: 0.85, y: 1), startRadius: 0, endRadius: 320)
        }
    }

    private var design: Color { Color(nsColor: .systemOrange) }
    private var client: Color { Color(nsColor: .systemBlue) }

    @ViewBuilder private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Сегодня").foregroundStyle(.notchInk.opacity(0.45))
                Text(verbatim: Fmt.short(8100)).foregroundStyle(.notchInk.opacity(0.9))
                Spacer()
            }
            .font(.system(size: 12, weight: .medium))
            .frame(height: 30)
            Group {
                switch scene {
                case .notch: notchScene
                case .timer: timerScene
                case .tasks: tasksScene
                case .report: reportScene
                }
            }
            .transition(.opacity)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .id(scene)
    }

    // MARK: Сцены

    private var notchScene: some View {
        VStack(alignment: .leading, spacing: 12) {
            input(title: nil, running: false)
            dayBar
            VStack(spacing: 1) {
                recent(L("Созвон по ТЗ"), L("Клиент А"), client)
                recent(L("Вёрстка карточек"), L("Дизайн"), design)
            }
        }
    }

    private var timerScene: some View {
        VStack(alignment: .leading, spacing: 12) {
            input(title: L("Правки главной страницы"), running: true)
            HStack(spacing: 12) {
                Image(icon: "bell", size: 14).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Время вышло")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.notchInk)
                    Text(verbatim: L("Правки главной страницы"))
                        .font(.system(size: 12))
                        .foregroundStyle(.notchInk.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("+5\u{00A0}мин")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.notchInk)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(.notchInk.opacity(0.12)))
                Text("Готово")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.notchPaper)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(.notchInk))
            }
            .padding(.leading, 14)
            .padding(.trailing, 9)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.accentColor.opacity(0.16)))
        }
    }

    private var tasksScene: some View {
        VStack(spacing: 1) {
            task(L("Ответить по смете"), L("Клиент А"), priority: 3, due: "\(L("Сегодня")) 14:30")
            task(L("Обновить резюме"), nil, priority: 2, due: L("Завтра"))
            task(L("Фото для галереи"), L("Дизайн"), priority: 1, due: nil)
            task(L("Вёрстка карточек"), L("Дизайн"), priority: 0, due: nil)
        }
    }

    private var reportScene: some View {
        VStack(alignment: .leading, spacing: 10) {
            dayBar
            reportRow(L("Дизайн"), design, share: 0.67, seconds: 5400)
            reportRow(L("Клиент А"), client, share: 0.33, seconds: 2700)
        }
    }

    // MARK: Детали

    private func input(title: String?, running: Bool) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: title ?? L("Чем вы заняты?"))
                .font(.system(size: 15))
                .foregroundStyle(.notchInk.opacity(title == nil ? 0.35 : 1))
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Circle().fill(design).frame(width: 7, height: 7)
                Text(verbatim: L("Дизайн"))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.notchInk.opacity(0.9))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(.notchInk.opacity(0.08)))
            HStack(spacing: 4) {
                Image(icon: "timer", size: 11)
                if running { Text(verbatim: Fmt.minutes(25)) }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.notchInk.opacity(running ? 0.9 : 0.45))
            .padding(.horizontal, running ? 9 : 7)
            .frame(height: 26)
            .background(Capsule().fill(.notchInk.opacity(running ? 0.14 : 0.08)))
            Image(icon: running ? "square" : "play", size: 12)
                .foregroundStyle(running ? AnyShapeStyle(Color.white) : AnyShapeStyle(.notchPaper))
                .frame(width: 32, height: 32)
                .background(Circle().fill(running ? AnyShapeStyle(Color(nsColor: .systemRed)) : AnyShapeStyle(.notchInk)))
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.notchInk.opacity(0.09)))
    }

    private var dayBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    Capsule().fill(design).frame(width: (g.size.width - 2) * 0.67)
                    Capsule().fill(client)
                }
            }
            .frame(height: 5)
            HStack(spacing: 14) {
                legend(L("Дизайн"), design, 5400)
                legend(L("Клиент А"), client, 2700)
            }
        }
        .padding(.horizontal, 4)
    }

    private func legend(_ name: String, _ color: Color, _ seconds: TimeInterval) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(verbatim: name).foregroundStyle(.notchInk.opacity(0.7))
            Text(verbatim: Fmt.short(seconds)).foregroundStyle(.notchInk.opacity(0.4))
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
    }

    private func recent(_ title: String, _ project: String, _ color: Color) -> some View {
        HStack(spacing: 9) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(verbatim: title).foregroundStyle(.notchInk.opacity(0.85))
            Text(verbatim: project).foregroundStyle(.notchInk.opacity(0.4))
            Spacer(minLength: 8)
            Image(icon: "play", size: 9).foregroundStyle(.notchInk.opacity(0.3))
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private func task(_ title: String, _ project: String?, priority: Int, due: String?) -> some View {
        HStack(spacing: 9) {
            TaskCheckmark(priority: priority, done: false, side: 14, ink: AnyShapeStyle(.notchInk.opacity(0.4)), doneColor: .clear)
            Text(verbatim: title).foregroundStyle(.notchInk.opacity(0.85))
            if let project { Text(verbatim: project).foregroundStyle(.notchInk.opacity(0.4)) }
            Spacer(minLength: 8)
            if let due {
                Text(verbatim: due)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.notchInk.opacity(0.5))
            }
            Image(icon: "play", size: 9).foregroundStyle(.notchInk.opacity(0.3))
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private func reportRow(_ name: String, _ color: Color, share: Double, seconds: TimeInterval) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(verbatim: name).font(.system(size: 13, weight: .medium)).foregroundStyle(.notchInk)
            Spacer(minLength: 12)
            ZStack(alignment: .leading) {
                Capsule().fill(.notchInk.opacity(0.08))
                Capsule().fill(color).frame(width: 120 * share)
            }
            .frame(width: 120, height: 5)
            Text(verbatim: "\(Int(share * 100))\u{00A0}%")
                .foregroundStyle(.notchInk.opacity(0.55))
                .frame(width: 44, alignment: .trailing)
            Text(verbatim: Fmt.short(seconds))
                .foregroundStyle(.notchInk)
                .frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 13))
        .monospacedDigit()
        .padding(.horizontal, 4)
        .frame(height: 30)
    }
}
