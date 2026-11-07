import AppKit
import Combine

// MARK: - Где живёт Hourfox

/// Авто: Notch там, где есть вырез, иначе значок в строке меню.
enum DisplayMode: String, CaseIterable, Identifiable {
    case auto, notch, menuBar

    static let key = "display.mode"
    static var current: DisplayMode {
        UserDefaults.standard.string(forKey: key).flatMap(DisplayMode.init(rawValue:)) ?? .auto
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Авто"
        case .notch: "Notch"
        case .menuBar: "Строка меню"
        }
    }

    /// Нужен ли значок вместо острова при текущем наборе экранов.
    var usesMenuBar: Bool {
        switch self {
        case .auto: !NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        case .notch: false
        case .menuBar: true
        }
    }
}

// MARK: - Рисунок значка

/// Что показывает значок. Сравниваем состояния, чтобы перерисовывать только при изменении.
struct MenuBarIconState: Equatable {
    /// Время записи; nil — записи нет, в строке меню только значок Hourfox.
    var text: String?
    var color: NSColor = .systemBlue
    var isPaused = false
    var isDark = true
}

enum MenuBarIcon {
    static let height: CGFloat = 22
    private static let idleWidth: CGFloat = 22
    private static let ringSide: CGFloat = 11
    private static let iconSide: CGFloat = 16
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

    /// Ширина постоянна, пока идёт запись: соседние значки не прыгают.
    private static func width(for text: String) -> CGFloat {
        let sample = String(repeating: "0", count: max(text.count, 8) - 2) + "::"
        let textWidth = NSAttributedString(string: sample, attributes: [.font: font]).size().width
        return (2 + ringSide + 6 + textWidth + 7 + iconSide + 2).rounded(.up)
    }

    static func image(_ state: MenuBarIconState) -> NSImage {
        let size = NSSize(width: state.text.map(width(for:)) ?? idleWidth, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            draw(state, in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(_ state: MenuBarIconState, in rect: NSRect) {
        let ink = state.isDark ? NSColor.white : NSColor.black
        guard let text = state.text else {
            drawLogo(center: NSPoint(x: rect.midX, y: rect.midY), radius: 7, ink: ink)
            return
        }
        // Кольцо цвета проекта, время, значок Hourfox.
        let ring = NSBezierPath(ovalIn: NSRect(x: 2, y: rect.midY - ringSide / 2, width: ringSide, height: ringSide).insetBy(dx: 1, dy: 1))
        ring.lineWidth = 2
        state.color.setStroke()
        ring.stroke()

        let string = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: ink.withAlphaComponent(state.isPaused ? 0.5 : 1),
        ])
        string.draw(at: NSPoint(x: 2 + ringSide + 6, y: rect.midY - string.size().height / 2))
        drawLogo(center: NSPoint(x: rect.maxX - 2 - iconSide / 2, y: rect.midY), radius: iconSide / 2 - 1, ink: ink)
    }

    /// Упрощённая иконка приложения: кольцо таймера и оранжевая стрелка.
    private static func drawLogo(center: NSPoint, radius: CGFloat, ink: NSColor) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 1.7
        ink.withAlphaComponent(0.3).setStroke()
        track.stroke()

        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: -150, clockwise: true)
        arc.lineWidth = 1.7
        arc.lineCapStyle = .round
        ink.setStroke()
        arc.stroke()

        let hand = NSBezierPath()
        hand.move(to: center)
        hand.line(to: NSPoint(x: center.x, y: center.y + radius - 1.8))
        hand.lineWidth = 1.5
        hand.lineCapStyle = .round
        NSColor.systemOrange.setStroke()
        hand.stroke()
    }
}

// MARK: - Значок в строке меню

final class MenuBarItem {
    private let store: Store
    private let onClick: () -> Void
    private let onRightClick: () -> Void
    private var item: NSStatusItem?
    private var appearanceObservation: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    private var lastState: MenuBarIconState?

    init(store: Store, onClick: @escaping () -> Void, onRightClick: @escaping () -> Void) {
        self.store = store
        self.onClick = onClick
        self.onRightClick = onRightClick
    }

    var isShown: Bool { item != nil }

    /// Окно значка в строке меню: под ним открывается панель.
    var buttonWindow: NSWindow? { item?.button?.window }

    func setShown(_ shown: Bool) {
        shown ? show() : hide()
    }

    private func show() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Hourfox"
            button.setAccessibilityLabel("Hourfox")
            button.imagePosition = .imageOnly
            // Строка меню бывает и светлой, и тёмной — зависит от обоев.
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async { self?.update() }
            }
        }
        store.$entries
            .sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }
            .store(in: &cancellables)
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        update()
    }

    private func hide() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
        appearanceObservation = nil
        cancellables.removeAll()
        lastState = nil
    }

    private func update() {
        guard let button = item?.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let state = Self.state(for: store.running, color: store.running.flatMap { store.project($0.projectID)?.color.nsColor }, isDark: dark)
        guard state != lastState else { return }
        lastState = state
        button.image = MenuBarIcon.image(state)
    }

    /// Таймер показывает остаток, секундомер — прошедшее время: 01:03:40.
    static func state(for entry: Entry?, color: NSColor?, isDark: Bool, now: Date = Date()) -> MenuBarIconState {
        guard let entry else { return MenuBarIconState(text: nil, isDark: isDark) }
        let remaining = entry.remaining(at: now)
        let seconds = Int((remaining ?? entry.duration(at: now)).rounded(remaining == nil ? .down : .up))
        let text = String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        let tint: NSColor
        if entry.isPaused {
            tint = .systemGray
        } else if let remaining, remaining <= 60 {
            tint = .systemRed
        } else {
            tint = color ?? .systemBlue
        }
        return MenuBarIconState(text: text, color: tint, isPaused: entry.isPaused, isDark: isDark)
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            onRightClick()
        } else {
            onClick()
        }
    }
}
