import Foundation

/// Приложение раньше называлось Tempo. Настройки и данные переезжают при первом запуске, старая папка остаётся как копия.
enum LegacyMigration {
    private static let oldDomain = "local.andrejm.tempo"
    private static let doneKey = "migration.fromTempo"

    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private static var newFolder: URL { support.appendingPathComponent("Hourfox", isDirectory: true) }
    private static var oldFolder: URL { support.appendingPathComponent("Tempo", isDirectory: true) }

    /// Запускать до всего остального: язык и настройки читаются сразу при старте.
    static func run() {
        guard ProcessInfo.processInfo.environment["HOURFOX_DATA_DIR"] == nil else { return }
        moveSettings()
        copyData()
    }

    private static func moveSettings() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        for (key, value) in defaults.persistentDomain(forName: oldDomain) ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: doneKey)
    }

    /// Копия собирается рядом и встаёт на место одним шагом: оборванный перенос не даст полупустую папку.
    private static func copyData() {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: newFolder.path), manager.fileExists(atPath: oldFolder.path) else { return }
        let draft = support.appendingPathComponent("Hourfox.migrating", isDirectory: true)
        do {
            try? manager.removeItem(at: draft)
            try manager.copyItem(at: oldFolder, to: draft)
            try manager.moveItem(at: draft, to: newFolder)
        } catch {
            NSLog("Hourfox: не удалось перенести данные: \(error.localizedDescription)")
        }
    }

    /// Если перенос не удался, работаем со старой папкой: человек не должен увидеть пустое приложение.
    static var dataFolder: URL {
        let manager = FileManager.default
        if !manager.fileExists(atPath: newFolder.path), manager.fileExists(atPath: oldFolder.path) { return oldFolder }
        return newFolder
    }
}
