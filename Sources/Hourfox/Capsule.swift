import SwiftUI

// MARK: - Капсула: панель, сжатая до мини-плеера

/// Название записи, проект и время; справа пауза и стоп. Капсулу таскают мышью,
/// она прилипает к краю экрана и прячется за него, если её туда утащить.
struct CapsuleView: View {
    @ObservedObject var model: NotchModel
    @EnvironmentObject var store: Store
    let controller: NotchController
    @AppStorage(GlassStyle.key) private var glass = false

    private var shape: NotchShape { NotchShape(topRadius: 20, bottomRadius: 20, isPanel: true) }

    var body: some View {
        HStack(spacing: 11) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                title
                subtitle
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            controls
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(width: NotchController.capsuleSize.width, height: NotchController.capsuleSize.height)
        .background { NotchBackground(shape: shape, glass: glass, expanded: true) }
        .clipShape(shape)
        .overlay(shape.stroke(.notchInk.opacity(0.12), lineWidth: 1))
        .contentShape(shape)
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { _ in controller.dragCapsule() }
            .onEnded { _ in controller.endDragCapsule() })
        .onTapGesture { controller.tapCapsule() }
        .contextMenu {
            Button("Развернуть") { controller.expand() }
            if store.running != nil { Button("Остановить") { store.stop() } }
            Divider()
            Button("Вернуть Notch") { controller.setMini(false) }
        }
        .help(model.tucked ? L("Показать капсулу") : L("Открыть панель"))
    }

    /// Квадрат слева, как обложка у плеера: эмодзи, кольцо таймера или цвет проекта.
    private var cover: some View {
        let color = store.color(for: store.running?.projectID ?? store.currentProjectID)
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(color.opacity(store.running == nil ? 0.12 : 0.22))
            .frame(width: 38, height: 38)
            .overlay {
                if let r = store.running {
                    if let e = r.emoji {
                        EmojiGlyph(e, size: 19)
                    } else if r.planned != nil {
                        CountdownRing(entry: r, color: color).scaleEffect(1.6)
                    } else if r.isPaused {
                        Image(icon: "pause", size: 12).foregroundStyle(color)
                    } else {
                        PulseDot(color: color).scaleEffect(1.4)
                    }
                } else {
                    Image(icon: "play", size: 12).foregroundStyle(.notchInk.opacity(0.6))
                }
            }
    }

    private var title: some View {
        let r = store.running
        let text = r.map { $0.title.isEmpty ? L("Без названия") : $0.title } ?? L("Ничего не записывается")
        return Text(verbatim: text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.notchInk.opacity(r == nil ? 0.6 : 0.95))
            .lineLimit(1)
    }

    private var subtitle: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 5) {
                if let r = store.running {
                    // С таймером — сколько осталось, без него — сколько прошло.
                    let value = r.remaining(at: ctx.date) ?? r.duration(at: ctx.date)
                    Text(verbatim: Fmt.clock(value.rounded(.up)))
                        .monospacedDigit()
                        .foregroundStyle(.notchInk.opacity(r.isPaused ? 0.35 : 0.75))
                    if let p = store.project(r.projectID) {
                        Text(verbatim: "·").foregroundStyle(.notchInk.opacity(0.3))
                        Text(verbatim: p.name).foregroundStyle(.notchInk.opacity(0.45))
                    }
                } else {
                    Text("Сегодня").foregroundStyle(.notchInk.opacity(0.4))
                    Text(verbatim: Fmt.short(store.total(in: Cal.day(ctx.date), now: ctx.date)))
                        .monospacedDigit()
                        .foregroundStyle(.notchInk.opacity(0.6))
                }
            }
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
        }
    }

    @ViewBuilder private var controls: some View {
        if let r = store.running {
            HStack(spacing: 2) {
                CapsuleButton(symbol: r.isPaused ? "play" : "pause", size: 15, help: r.isPaused ? "Продолжить" : "Пауза") {
                    withAnimation(.snappy) { store.togglePause() }
                }
                CapsuleButton(symbol: "square", size: 12, help: "Остановить") {
                    withAnimation(.snappy) { store.stop() }
                }
            }
        } else {
            CapsuleButton(symbol: "plus", size: 14, help: "Начать запись") { controller.expand() }
        }
    }
}

private struct CapsuleButton: View {
    let symbol: String
    let size: CGFloat
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(icon: symbol, size: size)
                .foregroundStyle(.notchInk.opacity(hover ? 1 : 0.75))
                .frame(width: 32, height: 32)
                .background(Circle().fill(.notchInk.opacity(hover ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .help(L(help))
        .onHover { hover = $0 }
    }
}
