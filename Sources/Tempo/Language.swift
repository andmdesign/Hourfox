import SwiftUI

/// Язык интерфейса. По умолчанию английский, меняется на лету, без перезапуска.
/// Ключи переводов — русские строки; переводы лежат в Resources/<код>.lproj/Localizable.strings.
final class AppLanguage: ObservableObject {
    static let shared = AppLanguage()

    /// Код .lproj, идентификатор локали и самоназвание языка.
    static let all: [(code: String, locale: String, name: String)] = [
        ("en", "en_US", "English"),
        ("ru", "ru_RU", "Русский"),
        ("uk", "uk_UA", "Українська"),
        ("zh-Hans", "zh_Hans_CN", "简体中文"),
        ("es", "es_ES", "Español"),
        ("pt-BR", "pt_BR", "Português"),
        ("cs", "cs_CZ", "Čeština"),
        ("it", "it_IT", "Italiano"),
    ]

    @Published var setting: String {
        didSet {
            UserDefaults.standard.set(setting, forKey: "appLanguage")
            resolve()
        }
    }
    @Published private(set) var code = "ru"
    private var bundle: Bundle?

    init() {
        setting = ProcessInfo.processInfo.environment["TEMPO_LANG"]
            ?? UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
        resolve()
    }

    private func resolve() {
        code = Self.all.contains { $0.code == setting } ? setting : "en"
        bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap { Bundle(path: $0) }
    }

    var locale: Locale { Locale(identifier: Self.all.first { $0.code == code }?.locale ?? "en_US") }

    func translate(_ key: String) -> String {
        bundle?.localizedString(forKey: key, value: key, table: nil) ?? key
    }
}

/// Перевод строки вне SwiftUI-литералов: меню, форматы, модели.
func L(_ key: String) -> String {
    AppLanguage.shared.translate(key)
}

/// Перевод с подстановкой: L("Ещё %@", "5 мин").
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: AppLanguage.shared.locale, arguments: args)
}

/// Выбор языка: меню с самоназваниями языков.
struct LanguagePicker: View {
    @ObservedObject private var language = AppLanguage.shared
    var label: LocalizedStringKey = "Язык"

    var body: some View {
        Picker(selection: $language.setting) {
            ForEach(AppLanguage.all, id: \.code) { Text(verbatim: $0.name).tag($0.code) }
        } label: {
            HStack(spacing: 10) {
                SettingIcon(name: "globe")
                Text(label)
            }
        }
    }
}

/// Корень окна: подставляет выбранную локаль и перерисовывает всё при смене языка.
struct Localized<Content: View>: View {
    @ObservedObject private var language = AppLanguage.shared
    let content: Content

    init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.locale, language.locale)
            .id(language.code)
    }
}
