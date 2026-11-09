import AppKit
import SwiftUI

// MARK: - Проверка обновлений

/// Раз в сутки спрашивает у hourfox.app номер последней версии. Ничего о человеке не отправляет:
/// это обычный запрос файла без куки и идентификаторов. Выключается в настройках.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let enabledKey = "updates.check"
    private static let lastCheckKey = "updates.lastCheck"

    struct Release: Decodable, Equatable {
        let version: String
        let apple: URL
        let intel: URL
    }

    @Published private(set) var available: Release?
    @Published private(set) var checking = false

    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    private var feed: URL {
        ProcessInfo.processInfo.environment["HOURFOX_UPDATE_URL"].flatMap(URL.init(string:))
            ?? URL(string: "https://hourfox.app/version.json")!
    }

    private var timer: Timer?

    /// Проверка при запуске и дальше раз в час смотрим, не прошли ли сутки с прошлой.
    func start() {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard isEnabled else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3600 else { return }
        check()
    }

    func check(completion: (() -> Void)? = nil) {
        guard !checking else { return }
        checking = true
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Hourfox/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession(configuration: .ephemeral).dataTask(with: request) { [weak self] data, _, _ in
            let release = data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                if let release {
                    UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                    self.available = Self.isNewer(release.version, than: self.current) ? release : nil
                }
                completion?()
            }
        }.resume()
    }

    /// 1.10 новее 1.9: сравниваем числа, а не строки.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Архив под процессор этого Mac скачивается браузером, ставит человек сам.
    func download() {
        guard let available else { return }
        #if arch(arm64)
        NSWorkspace.shared.open(available.apple)
        #else
        NSWorkspace.shared.open(available.intel)
        #endif
    }

    /// Для снимков и проверок.
    func pretend(_ release: Release?) { available = release }
}

/// Капсула в шапке Notch, пока есть новая версия.
struct UpdatePill: View {
    @ObservedObject var updates = UpdateChecker.shared

    var body: some View {
        if let release = updates.available {
            Button { updates.download() } label: {
                HStack(spacing: 3) {
                    Image(icon: "arrow-up-right", size: 9)
                    Text(verbatim: release.version)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(Color.accentColor))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(L("Доступна версия %@. Скачать", release.version))
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }
}

/// Строка в основных настройках: выключатель и ручная проверка.
struct UpdateSettingsRow: View {
    @ObservedObject var updates = UpdateChecker.shared
    @AppStorage(UpdateChecker.enabledKey) private var enabled = true
    @State private var checkedNow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $enabled) {
                settingLabel("Проверять обновления", "Раз в\u{00A0}день узнаёт номер новой версии на\u{00A0}hourfox.app. Ваши данные не\u{00A0}отправляются", "arrow-up-right")
            }
            HStack(spacing: 10) {
                if let release = updates.available {
                    Text(verbatim: L("Доступна версия %@", release.version))
                    Spacer()
                    Button("Скачать") { updates.download() }
                } else {
                    Text(verbatim: checkedNow ? L("У вас последняя версия, %@", updates.current) : L("Версия %@", updates.current))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(updates.checking ? L("Проверяю…") : L("Проверить сейчас")) {
                        updates.check { checkedNow = true }
                    }
                    .disabled(updates.checking)
                }
            }
            .font(.callout)
            .padding(.leading, 34)
        }
    }
}
