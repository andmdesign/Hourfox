import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!

    let store = Store.shared
    private(set) var notch: NotchController!
    private var languageObserver: AnyCancellable?
    private(set) lazy var journal = JournalWindowController(store: store)
    private(set) lazy var onboarding = OnboardingWindowController { [weak self] in self?.notch.peek() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Отчёт за прошедший период, если Mac был выключен, когда он настал.
        AutoReport.run(store: store)
        AppDelegate.shared = self
        AppTheme.current.apply()
        NSApp.mainMenu = buildMainMenu()
        languageObserver = AppLanguage.shared.$code.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { NSApp.mainMenu = self?.buildMainMenu() }
        }
        notch = NotchController(store: store)
        CalendarSync.shared.start(store: store)
        GoogleCalendar.shared.start()
        if store.isFirstLaunch && !OnboardingWindowController.isDone { onboarding.show() }
        DebugSnapshots.runIfRequested(self)
        if let copy = store.damagedDataCopy {
            let alert = NSAlert()
            alert.messageText = L("Не удалось прочитать данные Tempo")
            alert.informativeText = L("Копия файла сохранена, ничего не потеряно: %@", copy.path)
            alert.runModal()
        }
    }

    // Повторный запуск из Finder или Spotlight открывает журнал.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        journal.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        store.save()
    }

    @objc func toggleTimer() { store.toggle() }
    @objc func openSettings() { journal.show(.settings) }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: L("О программе Tempo"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L("Настройки…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: L("Скрыть Tempo"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: L("Завершить Tempo"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "Tempo")

        let timer = NSMenu(title: L("Таймер"))
        let toggle = timer.addItem(withTitle: L("Старт / Стоп"), action: #selector(toggleTimer), keyEquivalent: "t")
        toggle.target = self
        main.addItem(submenu: timer, title: L("Таймер"))

        let edit = NSMenu(title: L("Правка"))
        edit.addItem(withTitle: L("Отменить"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("Повторить"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Вырезать"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Скопировать"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Вставить"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Выбрать все"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: L("Правка"))

        let window = NSMenu(title: L("Окно"))
        window.addItem(withTitle: L("Свернуть"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: L("Закрыть"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: window, title: L("Окно"))
        NSApp.windowsMenu = window

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
