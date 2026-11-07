import AppKit
import SwiftUI

/// Тема Hourfox: как в системе, светлая или тёмная.
/// Раскрытый Notch следует теме; свёрнутый всегда чёрный, он продолжает вырез экрана.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "style.theme"
    static var current: AppTheme {
        UserDefaults.standard.string(forKey: key).flatMap(AppTheme.init(rawValue:)) ?? .system
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Как в системе"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }

    var icon: String {
        switch self {
        case .system: "computer"
        case .light: "sun"
        case .dark: "contrast"
        }
    }

    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct ThemePicker: View {
    var body: some View {
        LabeledContent {
            ThemeButtons()
        } label: {
            settingLabel("Тема", "Окна и раскрытый Notch. Свёрнутый Notch всегда чёрный", "contrast")
        }
    }
}

struct ThemeButtons: View {
    @AppStorage(AppTheme.key) private var theme = AppTheme.system.rawValue

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTheme.allCases) { item in
                Button {
                    theme = item.rawValue
                    AppTheme.current.apply()
                } label: {
                    Image(icon: item.icon, size: 16)
                        .foregroundStyle(theme == item.rawValue ? Color.white : Color.primary)
                        .frame(width: 34, height: 30)
                        .background(Capsule().fill(theme == item.rawValue ? Color.accentColor : Color.primary.opacity(0.07)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L(item.title))
                .accessibilityLabel(L(item.title))
            }
        }
    }
}

/// Режим «Стекло»: вместо чёрного фона острова — стеклянное покрытие.
/// Включается в «Настройках» → «Оформление».
enum GlassStyle {
    static let key = "style.glass"
}

/// Фон острова: чёрный, а в режиме «Стекло» раскрытый остров — дымчатое стекло.
/// Свёрнутый остров лежит поверх меню-бара: прозрачным он показывал бы значки строки меню
/// под собой, поэтому он всегда чёрный — как продолжение выреза. При раскрытии фон плавно
/// переходит в стекло.
/// Liquid Glass меняет вид, когда окно становится активным (клик по Notch), поэтому
/// берём системное размытие, которое всегда в «активном» состоянии, — вид не прыгает.
struct NotchBackground<S: Shape>: View {
    let shape: S
    let glass: Bool
    var expanded = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let showGlass = glass && expanded
        let light = expanded && scheme == .light
        ZStack {
            if glass {
                ZStack {
                    BehindWindowBlur(light: light)
                    (light ? Color.white : Color.black).opacity(0.3)
                    // К верху темнее: стекло плавно уходит в чёрный вырез экрана.
                    LinearGradient(colors: light ? [.white.opacity(0.45), .white.opacity(0.1), .clear] : [.black.opacity(0.45), .black.opacity(0.1), .clear],
                                   startPoint: .top, endPoint: .bottom)
                    // Тонкая светлая кромка, ярче снизу.
                    shape.stroke(LinearGradient(colors: [.white.opacity(0.02), .white.opacity(0.1), .white.opacity(0.3)],
                                                startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
                }
                .opacity(showGlass ? 1 : 0)
            }
            (light ? Color.white : Color.black).opacity(showGlass ? 0 : 1)
            // Тонкая кромка отделяет светлый остров от светлых окон под ним.
            if light { shape.stroke(Color.black.opacity(0.12), lineWidth: 1) }
        }
    }
}

/// Размытие того, что под окном. Состояние всегда «активно», чтобы не зависеть от фокуса окна.
private struct BehindWindowBlur: NSViewRepresentable {
    var light = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    }
}


// MARK: - Цвета Notch

/// Основной цвет содержимого Notch: белый на тёмном острове, чёрный на светлом.
struct NotchInk: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        (environment.colorScheme == .dark ? Color.white : Color.black).resolve(in: environment)
    }
}

/// Цвет поверх кнопок с заливкой `notchInk`: обратный основному.
struct NotchPaper: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        (environment.colorScheme == .dark ? Color.black : Color.white).resolve(in: environment)
    }
}

extension ShapeStyle where Self == NotchInk {
    static var notchInk: NotchInk { NotchInk() }
}

extension ShapeStyle where Self == NotchPaper {
    static var notchPaper: NotchPaper { NotchPaper() }
}
