import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Сочетание клавиш, которое открывает панель из любого приложения

/// Сочетания на выбор. Пробел с модификаторами легко запомнить, как у Spotlight.
enum HotKeyCombo: String, CaseIterable, Identifiable {
    case off, optionSpace, controlOptionSpace, shiftOptionSpace, controlSpace

    static let key = "hotkey.combo"
    static var current: HotKeyCombo {
        UserDefaults.standard.string(forKey: key).flatMap(HotKeyCombo.init(rawValue:)) ?? .optionSpace
    }

    var id: String { rawValue }

    /// Подпись в настройках: значки модификаторов не переводятся, слово «Пробел» переводится.
    var symbols: String? {
        switch self {
        case .off: nil
        case .optionSpace: "⌥"
        case .controlOptionSpace: "⌃⌥"
        case .shiftOptionSpace: "⇧⌥"
        case .controlSpace: "⌃"
        }
    }

    fileprivate var carbonModifiers: UInt32 {
        switch self {
        case .off: 0
        case .optionSpace: UInt32(optionKey)
        case .controlOptionSpace: UInt32(controlKey | optionKey)
        case .shiftOptionSpace: UInt32(shiftKey | optionKey)
        case .controlSpace: UInt32(controlKey)
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
        let status = RegisterEventHotKey(UInt32(kVK_Space), combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
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
    @AppStorage(HotKeyCombo.key) private var combo = HotKeyCombo.optionSpace.rawValue
    @ObservedObject private var hotKey = GlobalHotKey.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: Binding(get: { combo }, set: { new in
                combo = new
                hotKey.apply()
            })) {
                ForEach(HotKeyCombo.allCases) { c in
                    if let s = c.symbols {
                        Text(verbatim: "\(s) \(L("Пробел"))").tag(c.rawValue)
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
