import AppKit
import Combine
import ServiceManagement
import SwiftUI

// MARK: - Окно поверх Notch

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        // Без системного затухания: иначе при возврате клавиатуры остров мигает.
        animationBehavior = .none
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Разрешаем окну стоять поверх строки меню.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    // Приложение не активируется, поэтому ⌘C/⌘V/⌘A/⌘Z прокидываем руками.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command || flags == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() {
            let selector: Selector? = switch (key, flags.contains(.shift)) {
            case ("x", false): #selector(NSText.cut(_:))
            case ("c", false): #selector(NSText.copy(_:))
            case ("v", false): #selector(NSText.paste(_:))
            case ("a", false): #selector(NSText.selectAll(_:))
            case ("z", false): Selector(("undo:"))
            case ("z", true): Selector(("redo:"))
            default: nil
            }
            if let selector, NSApp.sendAction(selector, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class NotchModel: ObservableObject {
    @Published var expanded = false
    @Published var creatingProject = false
    /// Запись, к которой сейчас пишут комментарий прямо в Notch.
    @Published var commentingEntryID: UUID?
    /// Заметка, которую сейчас правят прямо в Notch.
    @Published var editingNoteID: UUID?
    /// Ввод своего времени таймера.
    @Published var customTimer = false
    @Published var pickingEmoji = false
    /// Задача, у которой открыт календарь срока.
    @Published var dueFor: UUID?
    /// Календарь срока для новой задачи.
    @Published var pickingNewDue = false
    /// Эмодзи для новой задачи.
    @Published var pickingNewEmoji = false
    /// Замок для фокусной работы: Notch не раскрывается при наведении, только по щелчку.
    @Published var locked = UserDefaults.standard.bool(forKey: "notchLocked") {
        didSet { UserDefaults.standard.set(locked, forKey: "notchLocked") }
    }
    /// Где замок в окне (по горизонтали): наведение на него не раскрывает Notch, чтобы по нему можно было попасть.
    /// Не @Published — меняется при раскладке и не должен перерисовывать вид.
    var lockFrame: CGRect?
    @Published var notchSize = CGSize(width: 185, height: 32)
    @Published var hasNotch = true
    /// Hourfox живёт значком в строке меню, а панель открывается под ним.
    @Published var menuBarMode = false
    /// Панель посередине экрана, как Spotlight: открывается сочетанием клавиш или щелчком по значку.
    @Published var centered = false
    /// Открыли сочетанием клавиш: сразу ставим курсор в «Чем вы заняты?».
    @Published var focusTitle = 0

    /// Под вырезом экрана нет пикселей: край, совпадающий с вырезом, не виден.
    /// Поэтому с сиянием свёрнутый остров опускается чуть ниже выреза — кромку видно на любом Mac.
    static let glowLip: CGFloat = 4

    func collapsedHeight(running: Bool) -> CGFloat {
        let glow = running && hasNotch && UserDefaults.standard.bool(forKey: Aurora.key)
        return notchSize.height + (glow ? Self.glowLip : 0)
    }
    @Published var shapeSize: CGSize = .zero

    /// Счётчик для блика по острову после старта таймера.
    @Published var startPulse = 0
    /// Запись, у которой только что вышло время таймера, — показываем баннер.
    @Published var timeUp: Entry?
    /// Задача, время которой наступило.
    @Published var dueTask: TodoTask?

    var isEditingInline: Bool { creatingProject || commentingEntryID != nil || editingNoteID != nil || customTimer || pickingEmoji || dueFor != nil || pickingNewDue || pickingNewEmoji }

    let wingWidth: CGFloat = 74
    let expandedWidth: CGFloat = 500
}

// MARK: - Контроллер

final class NotchController {
    let panel = NotchPanel()
    let model = NotchModel()
    let store: Store

    private var cancellables = Set<AnyCancellable>()
    private var monitors: [Any] = []
    private var pointerInside = false
    private var menuOpen = false
    private var expandWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?
    private var timeUpWork: DispatchWorkItem?
    private var dueWork: DispatchWorkItem?
    private lazy var menuBarItem = MenuBarItem(store: store, onClick: { [weak self] in self?.toggleFromMenuBar() },
                                               onRightClick: { [weak self] in self?.showMoreMenu() })

    init(store: Store) {
        self.store = store

        let root = Localized {
            NotchRootView(model: model, controller: self)
                .environmentObject(store)
        }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host

        applyDisplayMode()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.applyDisplayMode()
            }
            .store(in: &cancellables)

        store.$entries
            .map { $0.contains { $0.end == nil } }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] running in
                // Значение приходит до перерисовки, поэтому окно расширяем сразу.
                guard let self else { return }
                fit(targetSize(running: running))
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in
                guard let self, model.expanded, !pointerInside, !menuOpen, !ColorPanelBridge.isOpen else { return }
                collapse()
            }
            .store(in: &cancellables)

        // Любое меню приложения (в том числе по правому клику) не должно сворачивать Notch.
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] _ in self?.menuOpen = true }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .sink { [weak self] _ in self?.menuDidClose() }
            .store(in: &cancellables)

        // Раз в секунду проверяем, не вышло ли время таймера.
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.checkTimer() }
            .store(in: &cancellables)

        installMouseMonitors()
    }

    // MARK: Таймер обратного отсчёта

    /// Срок задачи: звук и баннер, как у таймера. Пока человек что-то вводит или висит другой баннер, ждём.
    private func checkDueTasks() {
        guard model.dueTask == nil, model.timeUp == nil, !model.isEditingInline, !menuOpen,
              let task = store.taskDueNow() else { return }
        store.markDueReminded(task.id)
        NSSound(named: "Glass")?.play()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        model.dueTask = task
        expand()
        dueWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, model.dueTask?.id == task.id else { return }
            model.dueTask = nil
            if !pointerInside, !panel.isKeyWindow { collapse() }
        }
        dueWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    func dismissDueTask() {
        dueWork?.cancel()
        model.dueTask = nil
        collapse()
    }

    private func checkTimer() {
        checkDueTasks()
        guard let entry = store.finishIfDue() else { return }
        // Если время вышло, пока приложение было закрыто, — без звука.
        let late = Date().timeIntervalSince(entry.end ?? Date()) > 60
        if !late {
            NSSound(named: "Glass")?.play()
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        model.timeUp = entry
        expand()
        timeUpWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, model.timeUp?.id == entry.id else { return }
            model.timeUp = nil
            if !pointerInside, !panel.isKeyWindow { collapse() }
        }
        timeUpWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    func dismissTimeUp() {
        timeUpWork?.cancel()
        model.timeUp = nil
        collapse()
    }

    func showTimerMenu() {
        let menu = NSMenu()
        let presets = store.running == nil ? [15, 25, 45, 60, 90, 120] : [5, 15, 25, 45, 60]
        if let r = store.running {
            let off = NSMenuItem(title: L("Без ограничения")) { [weak self] in self?.store.setTimer(nil) }
            off.state = r.planned == nil ? .on : .off
            menu.addItem(off)
            menu.addItem(.separator())
            for m in presets {
                menu.addItem(NSMenuItem(title: L("Ещё %@", Fmt.minutes(m))) { [weak self] in self?.store.setTimer(m) })
            }
        } else {
            let current = store.draftDuration.map { Int($0 / 60) }
            let off = NSMenuItem(title: L("Секундомер")) { [weak self] in self?.store.setTimer(nil) }
            off.state = current == nil ? .on : .off
            menu.addItem(off)
            menu.addItem(.separator())
            for m in presets {
                let item = NSMenuItem(title: Fmt.minutes(m)) { [weak self] in self?.store.setTimer(m) }
                item.state = current == m ? .on : .off
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Другое время")) { [weak self] in self?.model.customTimer = true })
        popUp(menu)
    }

    private func menuDidClose() {
        menuOpen = false
        // Даём выполниться действию пункта меню, потом решаем, сворачиваться ли.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, model.expanded, !menuOpen else { return }
            pointerInside = hotRect.contains(NSEvent.mouseLocation)
            if !pointerInside, !panel.isKeyWindow, !model.isEditingInline { collapse() }
        }
    }

    // MARK: Геометрия

    var screen: NSScreen {
        // Посередине того экрана, где сейчас мышь.
        if model.centered, let s = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) { return s }
        if model.menuBarMode, let s = menuBarItem.buttonWindow?.screen { return s }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Выбирает остров или значок: при запуске, при смене экранов и в настройке «Вид».
    func applyDisplayMode() {
        let menuBar = DisplayMode.current.usesMenuBar
        if menuBar != model.menuBarMode {
            if model.expanded { collapse() }
            model.menuBarMode = menuBar
        }
        model.centered = DisplayMode.current.centered
        menuBarItem.setShown(menuBar)
        measureNotch()
        setFrame(targetSize())
        if menuBar && !model.expanded {
            panel.orderOut(nil)
        } else {
            panel.hasShadow = menuBar
            panel.orderFrontRegardless()
        }
    }

    private func toggleFromMenuBar() {
        if model.expanded { collapse() } else { expand() }
    }

    /// Сочетание клавиш: открывает панель с курсором в поле ввода, повторное нажатие закрывает.
    func toggleFromHotKey() {
        if model.expanded {
            collapse()
            return
        }
        expand()
        panel.makeKeyAndOrderFront(nil)
        model.focusTitle += 1
    }

    private func measureNotch() {
        let s = screen
        if model.menuBarMode {
            // Выреза нет: шапка панели просто идёт сверху, без пустого места посередине.
            model.hasNotch = false
            model.notchSize = CGSize(width: 0, height: 34)
        } else if s.safeAreaInsets.top > 0, let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
            model.hasNotch = true
            model.notchSize = CGSize(width: s.frame.width - left.width - right.width, height: s.safeAreaInsets.top)
        } else {
            // Внешний монитор без выреза — рисуем аккуратную «пилюлю» в строке меню.
            model.hasNotch = false
            let menuBar = max(24, s.frame.maxY - s.visibleFrame.maxY)
            model.notchSize = CGSize(width: 150, height: menuBar)
        }
    }

    private func targetSize(running: Bool? = nil) -> CGSize {
        let n = model.notchSize
        // Раскрытое окно не меняет размер: рост окна внутри анимации сбрасывал весь остров вниз.
        if model.expanded {
            return CGSize(width: model.expandedWidth, height: expandedWindowHeight)
        }
        let isRunning = running ?? (store.running != nil)
        return CGSize(width: n.width + (isRunning ? model.wingWidth * 2 : 0), height: model.collapsedHeight(running: isRunning))
    }

    private var expandedWindowHeight: CGFloat {
        max(420, min(900, screen.visibleFrame.height - 8))
    }

    /// Пустая часть большого окна не должна перехватывать щелчки по тому, что под ним.
    private func updateClickThrough() {
        let through = model.expanded && !hotRect.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents != through { panel.ignoresMouseEvents = through }
    }

    private func setFrame(_ size: CGSize) {
        let f = screen.frame
        var rect = NSRect(x: (f.midX - size.width / 2).rounded(), y: f.maxY - size.height,
                          width: size.width.rounded(), height: size.height.rounded())
        if model.centered {
            // Верх панели на шестой части экрана сверху, как у Spotlight; окно не выходит за низ экрана.
            let v = screen.visibleFrame
            let top = (v.maxY - v.height * 0.16).rounded()
            rect.size.height = min(rect.height, top - v.minY - 8).rounded()
            rect.origin.y = top - rect.height
        } else if model.menuBarMode, let bar = menuBarItem.buttonWindow?.frame {
            rect.origin.x = (bar.midX - size.width / 2).rounded()
            rect.origin.x = min(max(rect.minX, f.minX + 8), f.maxX - size.width - 8).rounded()
            rect.origin.y = bar.minY - 6 - size.height
        }
        if panel.frame != rect { panel.setFrame(rect, display: true) }
    }

    /// Растём сразу, сжимаемся после анимации — так содержимое не обрезается.
    private func fit(_ size: CGSize) {
        let cur = panel.frame.size
        let grow = CGSize(width: max(cur.width, size.width), height: max(cur.height, size.height))
        setFrame(grow)
        shrinkWork?.cancel()
        if grow != size {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                setFrame(targetSize())
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    func shapeSizeChanged(_ size: CGSize) {
        model.shapeSize = size
        fit(targetSize())
        if panel.hasShadow { panel.invalidateShadow() }
        updateClickThrough()
    }

    private var hotRect: NSRect {
        let f = panel.frame
        if model.menuBarMode && !model.expanded { return .zero }
        let w = model.expanded ? model.expandedWidth : (model.shapeSize.width > 0 ? model.shapeSize.width : f.width)
        let h = model.expanded ? max(model.shapeSize.height, model.notchSize.height) : model.collapsedHeight(running: store.running != nil)
        let margin: CGFloat = model.expanded ? 8 : 2
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h).insetBy(dx: -margin, dy: -margin)
    }

    // MARK: Наведение и клики

    private func installMouseMonitors() {
        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moved, handler: { [weak self] _ in self?.mouseMoved() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moved, handler: { [weak self] e in self?.mouseMoved(); return e }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.clickOutside()
        }) {
            monitors.append(m)
        }
        // Esc закрывает панель, если сейчас ничего не вводится в строке (там Esc отменяет ввод).
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            guard let self, e.keyCode == 53, e.window === panel, model.expanded, !model.isEditingInline else { return e }
            collapse()
            return nil
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] e in
            if let self, e.window !== panel, !(e.window is NSColorPanel) { clickOutside() }
            return e
        }) {
            monitors.append(m)
        }
    }

    private func mouseMoved() {
        updateClickThrough()
        let p = NSEvent.mouseLocation
        var inside = hotRect.contains(p)
        // Над замком — «тихая зона»: свёрнутый Notch не раскрывается, иначе по замку не попасть.
        if inside, !model.expanded, let r = model.lockFrame {
            let x = p.x - panel.frame.minX
            if x >= r.minX - 6 && x <= r.maxX + 6 { inside = false }
        }
        guard inside != pointerInside else { return }
        pointerInside = inside
        // Панель под значком открывается и закрывается только по щелчку: мышь просто идёт через строку меню.
        guard !model.menuBarMode else { return }
        if inside {
            collapseWork?.cancel()
            guard !model.expanded, !model.locked else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, pointerInside else { return }
                expand()
            }
            expandWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else {
            expandWork?.cancel()
            // Пока пользователь печатает — не прячемся от случайного движения мыши.
            guard model.expanded, !panel.isKeyWindow, !menuOpen, !ColorPanelBridge.isOpen else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, !pointerInside, !menuOpen, !ColorPanelBridge.isOpen else { return }
                collapse()
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    private func clickOutside() {
        guard model.expanded, !menuOpen, !hotRect.contains(NSEvent.mouseLocation) else { return }
        // Щелчок по самому значку обработает он сам, иначе панель закроется и тут же откроется.
        if model.menuBarMode, menuBarItem.buttonWindow?.frame.contains(NSEvent.mouseLocation) == true { return }
        collapse()
    }

    // MARK: Состояния

    func expand() {
        guard !model.expanded else { return }
        collapseWork?.cancel()
        setFrame(CGSize(width: model.expandedWidth, height: expandedWindowHeight))
        // На светлом фоне светлому острову нужна тень, иначе он сливается с окнами под ним.
        panel.hasShadow = model.menuBarMode || panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        if model.menuBarMode { panel.orderFrontRegardless() }
        model.expanded = true
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    func collapse() {
        guard model.expanded else { return }
        expandWork?.cancel()
        collapseWork?.cancel()
        model.creatingProject = false
        model.commentingEntryID = nil
        model.editingNoteID = nil
        model.customTimer = false
        model.pickingEmoji = false
        model.dueFor = nil
        model.pickingNewDue = false
        model.pickingNewEmoji = false
        store.dropEmptyNotes()
        model.timeUp = nil
        model.dueTask = nil
        model.expanded = false
        panel.hasShadow = model.menuBarMode
        updateClickThrough()
        if model.menuBarMode {
            // Панель просто исчезает, как обычное меню; клавиатура возвращается приложению.
            panel.orderOut(nil)
            return
        }
        if panel.isKeyWindow {
            panel.makeFirstResponder(nil)
            // Возвращаем клавиатуру приложению, в котором работали.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        fit(targetSize())
    }

    /// Сворачиваемся и, когда «крылья» встанут на место, пускаем по острову блик.
    func didStart() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        collapse()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.model.startPulse += 1
        }
    }

    /// Показать Notch на пару секунд — после знакомства, чтобы было видно, где живёт Hourfox.
    func peek() {
        expand()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, !pointerInside, !panel.isKeyWindow, model.timeUp == nil else { return }
            collapse()
        }
    }

    func focusPanel() {
        panel.makeKey()
    }

    func openJournal(_ item: SidebarItem? = nil) {
        collapse()
        AppDelegate.shared.journal.show(item)
    }

    // MARK: Меню

    private func popUp(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func showProjectMenu() {
        let menu = NSMenu()
        let current = store.currentProjectID
        for p in store.activeProjects {
            let item = NSMenuItem(title: p.label) { [weak self] in self?.store.currentProjectID = p.id }
            item.image = dotImage(p.color.nsColor)
            item.state = p.id == current ? .on : .off
            menu.addItem(item)
        }
        if !store.activeProjects.isEmpty { menu.addItem(.separator()) }
        let none = NSMenuItem(title: L("Без проекта")) { [weak self] in self?.store.currentProjectID = nil }
        none.state = current == nil ? .on : .off
        menu.addItem(none)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Новый проект…")) { [weak self] in
            self?.model.creatingProject = true
        })
        popUp(menu)
    }

    /// Проект задачи: те же пункты и те же цветные точки, что у записи.
    func showProjectMenu(for task: TodoTask) {
        showProjectMenu(current: task.projectID) { [weak self] in self?.store.setProject($0, for: task.id) }
    }

    func showProjectMenu(current: UUID?, select: @escaping (UUID?) -> Void) {
        let menu = NSMenu()
        for p in store.activeProjects {
            let item = NSMenuItem(title: p.label) { select(p.id) }
            item.image = dotImage(p.color.nsColor)
            item.state = p.id == current ? .on : .off
            menu.addItem(item)
        }
        if !store.activeProjects.isEmpty { menu.addItem(.separator()) }
        let none = NSMenuItem(title: L("Без проекта")) { select(nil) }
        none.state = current == nil ? .on : .off
        menu.addItem(none)
        popUp(menu)
    }

    func showPriorityMenu(current: Int, select: @escaping (Int) -> Void) {
        let menu = NSMenu()
        for p in [3, 2, 1, 0] {
            let item = NSMenuItem(title: L(Priority.titles[p] ?? "")) { select(p) }
            item.image = Priority.menuImage(p)
            item.state = p == current ? .on : .off
            menu.addItem(item)
        }
        popUp(menu)
    }

    func showMoreMenu() {
        let menu = NSMenu()
        if let release = UpdateChecker.shared.available {
            menu.addItem(NSMenuItem(title: L("Скачать версию %@", release.version)) { UpdateChecker.shared.download() })
            menu.addItem(.separator())
        }
        menu.addItem(NSMenuItem(title: L("Журнал")) { [weak self] in self?.openJournal(.journal) })
        menu.addItem(NSMenuItem(title: L("Отчёт")) { [weak self] in self?.openJournal(.report) })
        menu.addItem(NSMenuItem(title: L("Настройки…")) { [weak self] in self?.openJournal(.settings) })
        menu.addItem(.separator())
        let login = NSMenuItem(title: L("Открывать при входе в систему")) {
            let service = SMAppService.mainApp
            if service.status == .enabled { try? service.unregister() } else { try? service.register() }
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let calendar = CalendarSync.shared
        let sync = NSMenuItem(title: L("Показывать в Календаре")) { calendar.setEnabled(!calendar.isEnabled) }
        sync.state = calendar.isEnabled ? .on : .off
        menu.addItem(sync)
        if calendar.isEnabled {
            menu.addItem(NSMenuItem(title: L("Открыть Календарь")) { calendar.openCalendarApp() })
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Знакомство с Hourfox")) { AppDelegate.shared.onboarding.show() })
        // Опасное действие — красным текстом, как в системных меню macOS.
        let quit = NSMenuItem(title: L("Завершить Hourfox")) { NSApp.terminate(nil) }
        quit.attributedTitle = NSAttributedString(string: quit.title, attributes: [
            .foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0),
        ])
        menu.addItem(quit)
        popUp(menu)
    }
}

// MARK: - Мелочи для NSMenu

final class MenuHandler: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

extension NSMenuItem {
    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(MenuHandler.run), keyEquivalent: "")
        let h = MenuHandler(handler)
        representedObject = h
        target = h
    }
}

func dotImage(_ color: NSColor, size: CGFloat = 12) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
        color.setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).fill()
        return true
    }
    img.isTemplate = false
    return img
}
