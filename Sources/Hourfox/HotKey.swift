import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Сочетание клавиш, которое открывает панель из любого приложения

/// Сочетания на выбор. ⌃ Пробел и ⌃⌥ Пробел не предлагаем: в macOS ими переключают раскладку.
/// ⌥ Пробел часто заняты Alfred, Raycast и ChatGPT, поэтому по умолчанию ⇧⌥ Пробел.
enum HotKeyCombo: String, CaseIterable, Identifiable {
    case shiftOptionSpace, controlShiftSpace, optionSpace, controlOptionT, off

    static let key = "hotkey.combo"
    static let fallback = HotKeyCombo.shiftOptionSpace
    /// Убранные из списка сочетания тоже превращаются в сочетание по умолчанию.
    static var current: HotKeyCombo {
        UserDefaults.standard.string(forKey: key).flatMap(HotKeyCombo.init(rawValue:)) ?? fallback
    }

    var id: String { rawValue }

    /// Подпись в настройках: значки модификаторов не переводятся, слово «Пробел» переводится.
    var label: String? {
        switch self {
        case .off: nil
        case .shiftOptionSpace: "⇧⌥ \(L("Пробел"))"
        case .controlShiftSpace: "⌃⇧ \(L("Пробел"))"
        case .optionSpace: "⌥ \(L("Пробел"))"
        case .controlOptionT: "⌃⌥T"
        }
    }

    fileprivate var keyCode: UInt32 { self == .controlOptionT ? UInt32(kVK_ANSI_T) : UInt32(kVK_Space) }

    fileprivate var carbonModifiers: UInt32 {
        switch self {
        case .off: 0
        case .shiftOptionSpace: UInt32(shiftKey | optionKey)
        case .controlShiftSpace: UInt32(controlKey | shiftKey)
        case .optionSpace: UInt32(optionKey)
        case .controlOptionT: UInt32(controlKey | optionKey)
        }
    }
}

/// Глобальное сочетание через Carbon: не нужен доступ к Универсальному доступу.
final class GlobalHotKey: ObservableObject {
    static let shared = GlobalHotKey()

    /// Сочетание уже занято другим приложением или системой.
    @Published private(set) var busy = false
    var action: (() -> Void)?

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func apply(_ combo: HotKeyCombo = .current) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        busy = false
        guard combo != .off else { return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x48_46_4F_58), id: 1) // «HFOX»
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            ref = nil
            busy = true
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { GlobalHotKey.shared.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

/// Строка настроек: каким сочетанием открывать панель.
struct HotKeyPicker: View {
    @AppStorage(HotKeyCombo.key) private var combo = HotKeyCombo.fallback.rawValue
    @ObservedObject private var hotKey = GlobalHotKey.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: Binding(get: { HotKeyCombo(rawValue: combo)?.rawValue ?? HotKeyCombo.fallback.rawValue }, set: { new in
                combo = new
                hotKey.apply()
            })) {
                ForEach(HotKeyCombo.allCases) { c in
                    if let label = c.label {
                        Text(verbatim: label).tag(c.rawValue)
                    } else {
                        Text("Не открывать").tag(c.rawValue)
                    }
                }
            } label: {
                settingLabel("Сочетание клавиш", "Открывает панель Hourfox из\u{00A0}любого приложения", "search")
            }
            if hotKey.busy {
                Text("Это сочетание уже занято, выберите другое")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
