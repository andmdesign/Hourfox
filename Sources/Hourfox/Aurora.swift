import SwiftUI

/// Режим «Сияние»: переливающаяся подсветка края в стиле Apple Intelligence.
/// Включается в «Настройках» → «Оформление».
enum Aurora {
    static let key = "style.aurora"

    /// Палитра Apple Intelligence; первый цвет повторён в конце, чтобы круг замыкался без шва.
    static let colors: [Color] = [
        Color(red: 0.36, green: 0.55, blue: 1.00),   // синий
        Color(red: 0.62, green: 0.42, blue: 1.00),   // фиолетовый
        Color(red: 0.91, green: 0.42, blue: 0.94),   // маджента
        Color(red: 1.00, green: 0.48, blue: 0.54),   // коралловый
        Color(red: 1.00, green: 0.72, blue: 0.42),   // янтарный
        Color(red: 0.36, green: 0.55, blue: 1.00),
    ]
}

/// Подсветка края изнутри формы: чёткая световая линия, короткое мягкое свечение под ней
/// и тонкий блик. Цвета плавно бегут по кругу.
/// Идея слоёв из размытых обводок с угловым градиентом — jacobamobin/AppleIntelligenceGlowEffect
/// (MIT, см. Vendor/AppleIntelligenceGlowEffect/LICENSE).
struct IntelligenceGlow<S: Shape>: View {
    let shape: S
    var strength: Double = 1
    /// Множитель толщины и размытия: для маленького свёрнутого Notch — тонкая версия.
    var scale: CGFloat = 1
    /// Вращение цветов. В свёрнутом Notch выключено: неподвижная подсветка не тратит процессор.
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if animated && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                    // Полный оборот за 9 секунд — спокойно, без суеты.
                    let turn = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 9) / 9
                    layers(angle: .degrees(turn * 360))
                }
            } else {
                layers(angle: .degrees(200))
            }
        }
        .clipShape(shape)
        // У верхней кромки (стык с краем экрана) подсветка гаснет.
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3)],
                             startPoint: .top, endPoint: .bottom))
        .opacity(strength)
        .allowsHitTesting(false)
    }

    /// drawingGroup растеризует размытые слои один раз — соседние анимации их не пересчитывают.
    private func layers(angle: Angle) -> some View {
        let gradient = AngularGradient(colors: Aurora.colors, center: .center, angle: angle)
        return ZStack {
            // Обводка идёт по центру контура; после обрезки формой видна внутренняя половина.
            shape.stroke(gradient, lineWidth: 18 * scale).blur(radius: 14 * scale).opacity(0.4)
            shape.stroke(gradient, lineWidth: 7 * scale).blur(radius: 4 * scale).opacity(0.7)
            shape.stroke(gradient, lineWidth: max(1.6, 3 * scale))
            shape.stroke(.white.opacity(0.45), lineWidth: 0.7)
        }
        .drawingGroup()
    }
}
