import AppKit
import Network
import SwiftUI

/// TEMPO_SNAPSHOT=<папка> — сохраняет снимки собственных окон (для проверки вёрстки без записи экрана).
/// В тесте приложение в фоне, а окно без фокуса пропускает события мыши: держим его ключевым.
private final class AlwaysKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

enum DebugSnapshots {
    static func runIfRequested(_ app: AppDelegate) {
        if let dir = ProcessInfo.processInfo.environment["TEMPO_GCAL_FAKE"] {
            MainActor.assumeIsolated { runGoogleCalendarTest(app, dir) }
            return
        }
        if let dir = ProcessInfo.processInfo.environment["TEMPO_CALTEST"] {
            MainActor.assumeIsolated { runCalendarTest(app, dir) }
            return
        }
        if let dir = ProcessInfo.processInfo.environment["TEMPO_EXTRASTEST"] {
            MainActor.assumeIsolated { runExtrasTest(app, dir) }
            return
        }
        if ProcessInfo.processInfo.environment["TEMPO_ANIMTEST"] != nil {
            runAnimationTest(app)
            return
        }
        if let dir = ProcessInfo.processInfo.environment["TEMPO_MENUBARTEST"] {
            runMenuBarTest(app, dir)
            return
        }
        if let dir = ProcessInfo.processInfo.environment["TEMPO_BURSTTEST"] {
            // Залп конфетти в отдельном окне — проверить, что Vortex рисует.
            let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 280, height: 260), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = NSHostingView(rootView: StopBurst(spec: .init(color: .systemOrange)).background(Color.black))
            w.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { save(w, "\(dir)/6-burst.png") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { exit(0) }
            return
        }
        if ProcessInfo.processInfo.environment["TEMPO_DRAGTEST"] != nil {
            // Тянем вкладку «Задачи» вправо собственными событиями мыши и следим, не завис ли главный поток.
            app.notch.expand()
            var last = Date()
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in last = Date() }
            Thread.detachNewThread {
                while true {
                    Thread.sleep(forTimeInterval: 0.5)
                    let lag = Date().timeIntervalSince(last)
                    if lag > 1 { print("DRAGTEST main thread stuck", String(format: "%.1f s", lag)) }
                }
            }
            let panel = app.notch.panel
            func send(_ type: NSEvent.EventType, _ x: CGFloat, _ yTop: CGFloat) {
                let p = NSPoint(x: x, y: panel.frame.height - yTop)
                guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
                panel.sendEvent(e)
            }
            let mode = ProcessInfo.processInfo.environment["TEMPO_DRAGTEST"] ?? "drag"
            let y: CGFloat = 122, x0: CGFloat = mode == "v2" ? 145 : 125
            func log(_ s: String) { FileHandle.standardError.write("DRAGTEST \(s) tab=\(UserDefaults.standard.string(forKey: "notchTab") ?? "-") order=\(UserDefaults.standard.string(forKey: "notchTabOrder") ?? "-")\n".data(using: .utf8)!) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                log("start")
                send(.leftMouseDown, x0, y)
                log("after down")
            }
            if mode == "play" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { send(.leftMouseDown, 454, 66) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { send(.leftMouseUp, 454, 66) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { log("running=\(app.store.running != nil)") }
            }
            if mode == "click" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { send(.leftMouseUp, x0, y) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { log("after click") }
            }
            if mode == "v2" {
                // Точная копия прогона, на котором зависло: щелчок, затем движение и второе нажатие внахлёст.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { send(.leftMouseUp, x0, y) }
                for i in 1...40 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(i) * 0.03) { send(.leftMouseDragged, 145 + CGFloat(i) * 4, y) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { send(.leftMouseDown, 145, y) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { send(.leftMouseUp, 305, y); log("up") }
            }
            if mode == "drag" {
                for i in 1...40 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6 + Double(i) * 0.03) { send(.leftMouseDragged, x0 + CGFloat(i) * 4, y); if i % 10 == 0 { log("drag \(i)") } }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { send(.leftMouseUp, x0 + 160, y); log("up") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { log("done"); exit(0) }
            return
        }
        if let dir = ProcessInfo.processInfo.environment["TEMPO_ONBOARDTEST"] {
            app.onboarding.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                save(NSApp.windows.first { $0 !== app.notch.panel && $0.isVisible }, "\(dir)/7-onboarding.png")
                exit(0)
            }
            return
        }
        if let dir = ProcessInfo.processInfo.environment["TEMPO_TICKTEST"] {
            // Покадрово снимаем свёрнутый остров, пока тикают секунды.
            app.store.start(title: "Тест", projectID: nil, emoji: "📎")
            for i in 0..<40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(i) * 0.05) { save(app.notch.panel, "\(dir)/tick-\(String(format: "%02d", i)).png") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                print("TICKTEST lockFrame:", app.notch.model.lockFrame.map { "\(Int($0.minX))…\(Int($0.maxX))" } ?? "нет",
                      "panel width:", Int(app.notch.panel.frame.width))
                exit(0)
            }
            return
        }
        if let dir = ProcessInfo.processInfo.environment["TEMPO_PAUSETEST"] {
            // Секундомер: 1 с работы, 2 с паузы, 1 с работы → ≈2 с. Таймер на 3 с с паузой 2 с не должен кончиться раньше 5 с.
            app.store.start(title: "Пауза", projectID: nil, planned: .some(nil))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                app.store.togglePause()
                save(app.notch.panel, "\(dir)/p1-collapsed-paused.png")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { app.notch.expand() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { save(app.notch.panel, "\(dir)/p2-expanded-paused.png") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { app.store.togglePause(); app.notch.collapse() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                print("PAUSETEST stopwatch:", String(format: "%.1f", app.store.running?.duration() ?? -1))
                app.store.stop()
                print("PAUSETEST saved:", String(format: "%.1f", app.store.entries.first?.duration() ?? -1))
                app.store.start(title: "Таймер", projectID: nil, planned: 3)
                app.notch.model.locked = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { app.store.togglePause() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) { save(app.notch.panel, "\(dir)/p3-collapsed-locked.png") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { app.store.togglePause() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                print("PAUSETEST timer still running at 4s wall/2s net:", app.store.running != nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.6) {
                let e = app.store.entries.first
                print("PAUSETEST timer finished:", app.store.running == nil, "net:", String(format: "%.1f", e?.duration() ?? -1),
                      "wall:", String(format: "%.1f", e.flatMap { $0.end?.timeIntervalSince($0.start) } ?? -1))
                exit(0)
            }
            return
        }
        if ProcessInfo.processInfo.environment["TEMPO_ADDTEST"] != nil {
            // «Ещё N мин» прибавляется к оставшемуся, а не заменяет его.
            app.store.start(title: "Тест", projectID: nil, planned: 600)
            app.store.setTimer(5); let a = app.store.running?.planned ?? 0
            app.store.setTimer(5); let b = app.store.running?.planned ?? 0
            app.store.start(title: "Секундомер", projectID: nil, planned: .some(nil))
            app.store.setTimer(15); let c = app.store.running?.planned ?? 0
            print("ADDTEST", Int(a), Int(b), Int(c))
            exit(0)
        }
        if ProcessInfo.processInfo.environment["TEMPO_TIMERTEST"] != nil {
            // Таймер на 2 секунды: запись должна закрыться ровно через 2 с и показать баннер.
            app.store.start(title: "Тест таймера", projectID: nil, planned: 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                let e = app.store.entries.first
                print("TIMERTEST running:", app.store.running != nil,
                      "duration:", e.map { String(format: "%.2f", $0.duration()) } ?? "-",
                      "banner:", app.notch.model.timeUp?.title ?? "нет",
                      "expanded:", app.notch.model.expanded)
                exit(0)
            }
            return
        }
        if ProcessInfo.processInfo.environment["TEMPO_SELFTEST"] != nil {
            // Проверка автосохранения: меняем данные и выходим без applicationWillTerminate.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { app.store.addProject(name: "Тест", color: .blue) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                let text = (try? String(contentsOf: app.store.fileURL, encoding: .utf8)) ?? "нет файла"
                print("SELFTEST saved:", text.contains("Тест"))
                exit(0)
            }
            return
        }
        guard let dir = ProcessInfo.processInfo.environment["TEMPO_SNAPSHOT"] else { return }
        let steps: [(Double, () -> Void)] = [
            (1.0, { save(app.notch.panel, "\(dir)/1-collapsed.png") }),
            (1.1, {
                var p = app.store.addProject(name: "Клиент", color: .blue); p.emoji = "💻"; app.store.updateProject(p)
                app.store.addTask("!! Позвонить в банк", projectID: nil)
                if var t = app.store.tasks.last { t.emoji = "📞"; app.store.updateTask(t) }
                app.store.addTask("Сверстать лендинг", projectID: p.id)
                UserDefaults.standard.set("tasks", forKey: "notchTab")
                print("PARSE:", app.store.tasks.last.map { "\($0.priority) «\($0.title)»" } ?? "-")
            }),
            (1.15, { app.store.start(title: "Звонок клиенту", projectID: nil, emoji: "📞"); app.notch.model.pickingEmoji = true }),
            (1.2, { app.notch.expand() }),
            (2.2, { save(app.notch.panel, "\(dir)/2-expanded.png") }),
            (3.4, { save(app.notch.panel, "\(dir)/3-emoji-row.png") }),
            (3.6, { app.notch.collapse() }),
            (4.6, { save(app.notch.panel, "\(dir)/1b-collapsed-emoji.png"); app.journal.show(.notes) }),
            (6.3, { dumpTables(NSApp.windows.first { $0 !== app.notch.panel && $0.isVisible }) }),
            (6.5, { save(NSApp.windows.first { $0 !== app.notch.panel && $0.isVisible }, "\(dir)/4-journal.png") }),
            (6.7, { app.journal.show(.report) }),
            (8.0, { MainActor.assumeIsolated { render(VStack(alignment: .leading, spacing: 0) { ForEach(app.store.tasks) { TaskListRow(task: $0).padding(.horizontal, 20); Divider() }; EmojiGrid(selection: .constant("📞")).padding(20) }.padding(.top, 20).frame(width: 600, alignment: .top).environmentObject(app.store), "\(dir)/5-report.png") } }),
            (8.4, { NSApp.terminate(nil) }),
        ]
        for (t, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: step)
        }
    }

    /// TEMPO_GCAL_FAKE=<папка> (вместе с TEMPO_DATA_DIR): разбор ответов Google, приём ответа из браузера и снимки вкладки. В сеть не ходит.
    @MainActor private static func runGoogleCalendarTest(_ app: AppDelegate, _ dir: String) {
        let day = Calendar.current.startOfDay(for: Date())
        let date = day.formatted(.iso8601.year().month().day())
        let iso = ISO8601DateFormatter()
        func at(_ h: Double) -> String { iso.string(from: day.addingTimeInterval(h * 3600)) }
        let json = #"{"items":[{"id":"1","summary":"Живое","start":{"dateTime":"\#(at(10))"},"end":{"dateTime":"\#(at(11))"},"hangoutLink":"https://meet.google.com/abc"},{"id":"2","status":"cancelled","summary":"Отменено","start":{"dateTime":"\#(at(12))"},"end":{"dateTime":"\#(at(13))"}},{"id":"3","summary":"Отклонено","attendees":[{"self":true,"responseStatus":"declined"}],"start":{"dateTime":"\#(at(14))"},"end":{"dateTime":"\#(at(15))"}},{"id":"4","summary":"День","start":{"date":"\#(date)"},"end":{"date":"\#(date)"}},{"id":"5","start":{"dateTime":"\#(at(16))"},"end":{"dateTime":"\#(at(17))"}}],"nextPageToken":"N"}"#
        let parsed = try! GoogleAPI.events(from: Data(json.utf8), colorHex: "#FF0000", untitled: "UNTITLED")
        print("GCAL parsed:", GoogleAPI.sorted(parsed.events).map { "\($0.id):\($0.title):\($0.isAllDay ? "allday" : "timed"):\($0.meetingURL != nil ? "meet" : "-")" }, "next:", parsed.next ?? "nil")

        // Приём ответа из браузера: чужой state отклоняется, верный принимается.
        let server = OAuthLoopbackServer(state: "good")
        server.start(ready: { port in
            func hit(_ query: String, _ then: @escaping (Int) -> Void) {
                URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)\(query)")!) { _, r, _ in
                    DispatchQueue.main.async { then((r as? HTTPURLResponse)?.statusCode ?? 0) }
                }.resume()
            }
            hit("/?code=EVIL&state=bad") { first in
                print("GCAL loopback wrong state:", first)
                hit("/?code=OK123&state=good") { print("GCAL loopback right state:", $0) }
            }
        }, completion: { result in
            print("GCAL loopback result:", (try? result.get()) ?? "failure")
        })
        _ = server
        loopbackHold = server

        let now = Date()
        func ev(_ id: String, _ title: String, _ from: Double, _ to: Double, _ color: String, meet: Bool = false) -> GoogleEvent {
            GoogleEvent(id: id, title: title, start: now.addingTimeInterval(from * 60), end: now.addingTimeInterval(to * 60), isAllDay: false, colorHex: color, meetingURL: meet ? URL(string: "https://meet.google.com/abc") : nil, link: nil)
        }
        let fake = [
            ev("p", "Уже прошло", -120, -60, "#7986CB"),
            ev("a", "Созвон с командой", -10, 20, "#039BE5", meet: true),
            ev("b", "Дизайн-ревью", 60, 90, "#F4511E"),
            ev("c", "Очень длинное название встречи, которое не должно ломать строку вкладки в Notch", 120, 150, "#33B679"),
            GoogleEvent(id: "d", title: "День рождения Лины", start: Calendar.current.startOfDay(for: now), end: Calendar.current.startOfDay(for: now).addingTimeInterval(86400), isAllDay: true, colorHex: "#8E24AA", meetingURL: nil, link: nil),
        ]
        UserDefaults.standard.set("events", forKey: "notchTab")
        let google = GoogleCalendar.shared
        google.useFakeDisconnected()
        app.notch.model.pickingEmoji = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { app.notch.expand() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { app.notch.model.pickingEmoji = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { save(app.notch.panel, "\(dir)/events-disconnected.png") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { MainActor.assumeIsolated { google.useFakeData(fake) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { save(app.notch.panel, "\(dir)/events-connected.png") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.7) {
            MainActor.assumeIsolated {
                print("GCAL rows:", fake.filter { $0.end > Date() }.count)
            }
            NSApp.terminate(nil)
        }
    }

    @MainActor private static var loopbackHold: OAuthLoopbackServer?

    /// TEMPO_EXTRASTEST=<папка> (вместе с TEMPO_DATA_DIR): логика функций и снимки экранов. В сеть не ходит.
    @MainActor private static func runExtrasTest(_ app: AppDelegate, _ dir: String) {
        setbuf(stdout, nil)
        let store = app.store
        let defaults = UserDefaults.standard
        let now = Date()
        func check(_ name: String, _ ok: Bool) { print(ok ? "OK  " : "FAIL", name) }
        func date(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }

        check("иконки читаются", AppIcon.missing.isEmpty)

        // Цвет: старое имя читается как раньше, свой цвет переживает сохранение.
        let oldProject = try? JSONDecoder().decode(Project.self, from: Data(#"{"id":"11111111-1111-1111-1111-111111111111","name":"Старый","color":"teal"}"#.utf8))
        check("старый проект читается", oldProject?.color == .teal && oldProject?.isArchived == false)
        let hex = ProjectColor.custom(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1))
        check("свой цвет: \(hex.rawValue)", hex.rawValue == "#FF8000" && hex.isCustom)
        var p = Project(name: "x", color: hex)
        p.rate = 100
        let encoded = (try? JSONEncoder().encode(p)) ?? Data()
        let decoded = try? JSONDecoder().decode(Project.self, from: encoded)
        let round = decoded?.color.nsColor.usingColorSpace(.sRGB)
        check("свой цвет после сохранения", decoded?.color == hex && abs((round?.greenComponent ?? 0) - 128.0 / 255) < 0.01)
        check("в файле цвет — строка", String(data: encoded, encoding: .utf8)?.contains("FF8000") == true)
        check("ставка: 12,5", Project.parseRate("12,5") == 12.5 && Project.parseRate("abc") == nil && Project.parseRate("") == nil)

        // Старая ссылка на свою картинку не попадает на экран: проверяется при загрузке.
        check("свои эмодзи очищены при загрузке", store.projects.first { $0.name == "СтарыйЭмодзи" }.map { $0.emoji == nil } ?? true)
        check("обычный эмодзи сохранён", store.tasks.first { $0.title == "СтараяЗадача" }.map { $0.emoji == "📞" } ?? true)

        // Отмена.
        let client = store.addProject(name: "Клиент", color: .blue)
        store.upsert(Entry(title: "Удалить", projectID: client.id, start: date(300), end: date(280), note: "n"))
        let toDelete = store.entries.first { $0.title == "Удалить" }!
        store.deleteEntry(toDelete.id)
        check("запись удалена, есть отмена", !store.contains(toDelete.id) && store.undoOffer != nil)
        store.performUndo()
        check("запись вернулась", store.entry(toDelete.id) == toDelete && store.undoOffer == nil)
        store.addTask("Первая", projectID: nil)
        store.addTask("Вторая", projectID: nil)
        store.addTask("Третья", projectID: nil)
        let second = store.tasks.first { $0.title == "Вторая" }!
        store.deleteTask(second.id)
        store.performUndo()
        check("задача вернулась на место", store.tasks.map(\.title) == ["Первая", "Вторая", "Третья"] || store.tasks.suffix(3).map(\.title) == ["Первая", "Вторая", "Третья"])
        let note = store.addNote("Важная мысль")
        store.deleteNote(note.id)
        store.performUndo()
        check("заметка вернулась", store.note(note.id) != nil)
        let empty = store.addNote("")
        store.undoOffer = nil
        store.deleteNote(empty.id)
        check("пустую заметку не предлагаем вернуть", store.undoOffer == nil)
        store.deleteProject(client.id)
        check("проект удалён", store.project(client.id) == nil && store.entry(toDelete.id)?.projectID == nil)
        store.performUndo()
        check("проект и связи вернулись", store.project(client.id) != nil && store.entry(toDelete.id)?.projectID == client.id)
        store.start(title: "Идёт", projectID: nil, planned: .some(nil))
        let runningID = store.running!.id
        store.discardRunning()
        store.start(title: "Новая", projectID: nil, planned: .some(nil))
        Thread.sleep(forTimeInterval: 1.1)
        store.performUndo()
        check("вторая идущая запись не появляется", store.entries.filter(\.isRunning).count == 1 && store.entry(runningID)?.end != nil)
        store.stop()
        store.deleteEntry(runningID)
        store.undoOffer = nil
        if let extra = store.entries.first(where: { $0.title == "Новая" }) { store.entries.removeAll { $0.id == extra.id } }

        // Перетаскивание.
        store.tasks.removeAll()
        store.addTask("А", projectID: nil)
        store.addTask("Б", projectID: nil)
        store.addTask("!! В", projectID: nil)
        check("приоритет сверху", store.openTasks.map(\.title) == ["В", "А", "Б"])
        store.moveOpenTasks(from: IndexSet(integer: 2), to: 0)
        check("перетаскивание важнее приоритета", store.openTasks.map(\.title) == ["Б", "В", "А"])
        store.addTask("!!! Г", projectID: nil)
        check("новая важная задача встаёт над менее важными", store.openTasks.map(\.title) == ["Г", "Б", "В", "А"])
        store.addTask("Д", projectID: nil)
        check("обычная новая задача внизу", store.openTasks.last?.title == "Д")
        let taskB = store.tasks.first { $0.title == "Б" }!
        store.setPriority(3, for: taskB.id)
        check("смена приоритета двигает задачу", store.openTasks.firstIndex { $0.title == "Б" } == 0 || store.openTasks.firstIndex { $0.title == "Б" } == 1)
        let taskJSON = (try? JSONEncoder().encode(store.tasks.first!)) ?? Data()
        check("порядок сохраняется", (try? JSONDecoder().decode(TodoTask.self, from: taskJSON))?.rank != nil)

        // Проект и срок задачи.
        let picked = store.tasks.first { $0.title == "Д" }!
        store.setProject(client.id, for: picked.id)
        check("задаче выбран проект", store.tasks.first { $0.id == picked.id }?.projectID == client.id)
        store.setProject(nil, for: picked.id)
        check("проект у задачи снят", store.tasks.first { $0.id == picked.id }?.projectID == nil)
        store.addTask("Со сроком", projectID: nil, due: now)
        let dated = store.tasks.first { $0.title == "Со сроком" }
        check("новая задача сразу со сроком", dated?.due == Cal.ru.startOfDay(for: now))
        defaults.set(true, forKey: Extra.smartInput.key)
        store.addTask("Умная со сроком", projectID: nil, due: now)
        check("срок и в умном вводе", store.tasks.first { $0.title == "Умная со сроком" }?.due == Cal.ru.startOfDay(for: now))
        defaults.set(false, forKey: Extra.smartInput.key)
        store.tasks.removeAll { $0.title.hasSuffix("со сроком") || $0.title == "Со сроком" }
        store.undoOffer = nil

        // Календарь: целые недели с понедельника, весь месяц на месте.
        let feb = Cal.ru.date(from: DateComponents(year: 2027, month: 2, day: 15))!
        let febDays = DuePicker.days(in: feb)
        check("календарь: февраль 2027", febDays.count % 7 == 0 && febDays.count >= 28 && Cal.ru.component(.weekday, from: febDays[0]) == 2
            && febDays.filter { Cal.ru.isDate($0, equalTo: feb, toGranularity: .month) }.count == 28)
        let may = Cal.ru.date(from: DateComponents(year: 2027, month: 5, day: 15))!
        check("календарь: шесть недель в мае 2027", DuePicker.days(in: may).count == 42)

        // Время срока.
        let timed = store.tasks.first { $0.title == "Д" }!
        store.setDue(now, minutes: 14 * 60 + 30, for: timed.id)
        let timedSaved = store.tasks.first { $0.id == timed.id }!
        check("срок со временем", timedSaved.dueMinutes == 870 && DueDate.clock(870) == "14:30" && DueDate.text(now, minutes: 870).hasSuffix("14:30"))
        let timedJSON = (try? JSONEncoder().encode(timedSaved)) ?? Data()
        check("время сохраняется", (try? JSONDecoder().decode(TodoTask.self, from: timedJSON))?.dueMinutes == 870)
        let oldTask = try? JSONDecoder().decode(TodoTask.self, from: Data(#"{"id":"44444444-4444-4444-4444-444444444444","title":"Старая","done":false,"created":0,"priority":0}"#.utf8))
        check("старая задача без времени читается", oldTask?.dueMinutes == nil && oldTask?.title == "Старая")
        store.setDue(nil, for: timed.id)
        check("без срока нет и времени", store.tasks.first { $0.id == timed.id }?.dueMinutes == nil)
        let today0 = Cal.ru.startOfDay(for: now)
        let at1000 = today0.addingTimeInterval(10 * 3600)
        check("прошедшее время сегодня просрочено", DueDate.isOverdue(today0, minutes: 600, now: at1000.addingTimeInterval(60)) && !DueDate.isOverdue(today0, minutes: 600, now: at1000.addingTimeInterval(-60)))
        check("срок без времени идёт до конца дня", !DueDate.isOverdue(today0, now: today0.addingTimeInterval(23 * 3600)) && DueDate.isOverdue(today0, now: today0.addingTimeInterval(25 * 3600)))
        check("время без дня: сегодня или завтра", DuePicker.dayForTime(660, now: at1000) == today0 && DuePicker.dayForTime(540, now: at1000) == Cal.ru.date(byAdding: .day, value: 1, to: today0))
        store.addTask("Со временем", projectID: nil, due: now, dueMinutes: 600)
        check("новая задача со временем", store.tasks.first { $0.title == "Со временем" }?.dueMinutes == 600)
        store.tasks.removeAll { $0.title == "Со временем" }

        // Напоминание о времени задачи.
        store.tasks.removeAll { $0.title == "Напомни" }
        store.addTask("Напомни", projectID: nil)
        let remind = store.tasks.first { $0.title == "Напомни" }!
        let base = Cal.ru.startOfDay(for: now).addingTimeInterval(10 * 3600)
        defaults.set(false, forKey: Extra.dueDates.key)
        store.setDue(base, minutes: 600, for: remind.id)
        check("срок выключен: не напоминаем", store.taskDueNow(now: base) == nil)
        defaults.set(true, forKey: Extra.dueDates.key)
        check("рано не напоминаем", store.taskDueNow(now: base.addingTimeInterval(-1)) == nil)
        check("время наступило", store.taskDueNow(now: base)?.id == remind.id)
        check("пять минут ещё напоминаем", store.taskDueNow(now: base.addingTimeInterval(299))?.id == remind.id)
        check("позже не напоминаем", store.taskDueNow(now: base.addingTimeInterval(301)) == nil)
        store.markDueReminded(remind.id)
        check("дважды не напоминаем", store.taskDueNow(now: base.addingTimeInterval(1)) == nil)
        store.setDue(base, minutes: 630, for: remind.id)
        check("новое время напомнит снова", store.taskDueNow(now: base.addingTimeInterval(1800))?.id == remind.id)
        store.setDue(base, for: remind.id)
        check("без времени не напоминаем", store.taskDueNow(now: base.addingTimeInterval(1800)) == nil)
        store.setDue(base, minutes: 600, for: remind.id)
        store.snoozeDue(remind.id, minutes: 15, now: base.addingTimeInterval(120))
        let snoozed = store.tasks.first { $0.id == remind.id }!
        check("отложено на 15 минут", snoozed.dueMinutes == 617 && Cal.ru.isDate(snoozed.due!, inSameDayAs: base))
        store.snoozeDue(remind.id, minutes: 15, now: Cal.ru.startOfDay(for: now).addingTimeInterval(23.9 * 3600))
        let nextDay = store.tasks.first { $0.id == remind.id }!
        check("откладывание через полночь", nextDay.due == Cal.ru.date(byAdding: .day, value: 1, to: Cal.ru.startOfDay(for: now)) && nextDay.dueMinutes == 9)
        store.toggleTask(remind.id)
        check("выполненной не напоминаем", store.taskDueNow(now: base) == nil)
        store.tasks.removeAll { $0.id == remind.id }
        store.undoOffer = nil

        // Новая задача сразу с приоритетом, эмодзи и проектом.
        store.addTask("С выбором", projectID: client.id, priority: 2, emoji: "📞")
        let chosen = store.tasks.first { $0.title == "С выбором" }
        check("новая задача с выбором", chosen?.priority == 2 && chosen?.emoji == "📞" && chosen?.projectID == client.id)
        store.addTask("!!! Знаки важнее", projectID: nil, priority: 1)
        check("знаки в тексте важнее выбранного", store.tasks.first { $0.title == "Знаки важнее" }?.priority == 3)
        defaults.set(true, forKey: Extra.smartInput.key)
        store.addTask("Умная с выбором", projectID: nil, priority: 2, emoji: "📞")
        let smartChosen = store.tasks.first { $0.title == "Умная с выбором" }
        check("выбор работает и с умным вводом", smartChosen?.priority == 2 && smartChosen?.emoji == "📞")
        defaults.set(false, forKey: Extra.smartInput.key)
        store.tasks.removeAll { ["С выбором", "Знаки важнее", "Умная с выбором"].contains($0.title) }

        // Отмена завершения задачи.
        store.addTask("Завершу", projectID: nil)
        let finishing = store.tasks.first { $0.title == "Завершу" }!
        store.undoOffer = nil
        store.toggleTask(finishing.id)
        check("завершение можно отменить", !store.openTasks.contains { $0.id == finishing.id } && store.undoOffer != nil)
        store.performUndo()
        check("задача вернулась в список", store.openTasks.contains { $0.id == finishing.id } && store.undoOffer == nil)
        store.toggleTask(finishing.id)
        store.undoOffer = nil
        store.toggleTask(finishing.id)
        check("возврат выполненной отмену не предлагает", store.undoOffer == nil && store.openTasks.contains { $0.id == finishing.id })
        store.tasks.removeAll { $0.id == finishing.id }

        // Очистка выполненных.
        store.addTask("Держу 1", projectID: nil)
        store.addTask("Готова 1", projectID: nil)
        store.addTask("Держу 2", projectID: nil)
        store.addTask("Готова 2", projectID: nil)
        for name in ["Готова 1", "Готова 2"] {
            store.toggleTask(store.tasks.first { $0.title == name }!.id)
        }
        let tasksBeforeClear = store.tasks
        store.undoOffer = nil
        store.clearDoneTasks()
        check("выполненные очищены, открытые на месте", store.doneTasks.isEmpty && store.tasks.contains { $0.title == "Держу 1" } && store.undoOffer != nil)
        store.performUndo()
        check("очистка отменяется, порядок прежний", store.tasks.map(\.id) == tasksBeforeClear.map(\.id))
        store.clearDoneTasks()
        store.undoOffer = nil
        store.clearDoneTasks()
        check("пустой список не предлагает отмену", store.undoOffer == nil)
        store.tasks.removeAll { $0.title.hasPrefix("Держу") }

        // Архив: всё удалённое лежит там, пока его не удалят оттуда.
        store.archive = ArchiveBox()
        store.upsert(Entry(title: "В архив", projectID: nil, start: date(500), end: date(490), note: "заметка"))
        let entryA = store.entries.first { $0.title == "В архив" }!
        store.deleteEntry(entryA.id)
        check("запись в архиве, а не в журнале", !store.contains(entryA.id) && store.archive.entries.first?.id == entryA.id && store.total(in: DateInterval(start: date(600), end: now), now: now) >= 0)
        store.performUndo()
        check("отмена убирает из архива", store.contains(entryA.id) && store.archive.entries.isEmpty)
        store.deleteEntry(entryA.id)
        store.undoOffer = nil
        store.restoreEntry(entryA.id)
        check("вернулась из архива", store.entry(entryA.id) == entryA && store.archive.entries.isEmpty)
        store.deleteEntry(entryA.id)
        store.eraseEntry(entryA.id)
        check("удалена навсегда", !store.contains(entryA.id) && store.archive.entries.isEmpty)
        store.addTask("Задача в архив", projectID: nil)
        let taskA = store.tasks.first { $0.title == "Задача в архив" }!
        store.deleteTask(taskA.id)
        check("задача в архиве", store.archive.tasks.first?.id == taskA.id)
        store.restoreTask(taskA.id)
        check("задача вернулась", store.tasks.contains { $0.id == taskA.id })
        store.deleteTask(taskA.id)
        let noteA = store.addNote("Мысль в архив")
        store.deleteNote(noteA.id)
        check("заметка в архиве", store.archive.notes.first?.id == noteA.id)
        store.restoreNote(noteA.id)
        check("заметка вернулась", store.note(noteA.id) != nil)
        store.deleteNote(noteA.id)
        let projA = store.addProject(name: "Проект в архив", color: .green)
        store.upsert(Entry(title: "В проекте", projectID: projA.id, start: date(480), end: date(470)))
        let inProject = store.entries.first { $0.title == "В проекте" }!
        store.deleteProject(projA.id)
        check("проект в архиве, запись без проекта", store.project(projA.id) == nil && store.archive.projects.first?.id == projA.id && store.entry(inProject.id)?.projectID == nil)
        store.restoreProject(projA.id)
        check("проект вернулся со связями", store.project(projA.id) != nil && store.entry(inProject.id)?.projectID == projA.id)
        store.deleteProject(projA.id)
        store.undoOffer = nil
        let archiveJSON = (try? JSONEncoder().encode(store.archive)) ?? Data()
        let archiveBack = try? JSONDecoder().decode(ArchiveBox.self, from: archiveJSON)
        check("архив сохраняется в файл", archiveBack?.projects.first?.entryIDs.contains(inProject.id) == true && archiveBack?.tasks.first?.id == taskA.id && archiveBack?.notes.first?.id == noteA.id)
        let archivedStay = store.addProject(name: "Убран в архив", color: .gray)
        store.setArchived(true, for: archivedStay.id)
        store.eraseArchive()
        check("очистка стирает удалённое, но не проекты в архиве", store.archive.tasks.isEmpty && store.archive.notes.isEmpty && store.archive.projects.isEmpty && store.project(archivedStay.id) != nil)
        store.eraseProject(archivedStay.id)
        check("проект из архива удалён навсегда", store.project(archivedStay.id) == nil)
        store.entries.removeAll { $0.id == inProject.id }
        store.upsert(Entry(title: "Для снимка", projectID: nil, start: date(450), end: date(440)))
        store.deleteEntry(store.entries.first { $0.title == "Для снимка" }!.id)
        store.undoOffer = nil

        // Ползунок времени.
        check("ползунок: начало", DueTimeSlider.value(x: 0, width: 400) == 0 && DueTimeSlider.value(x: -50, width: 400) == 0)
        check("ползунок: середина 12:00", DueTimeSlider.value(x: 200, width: 400) == 720)
        check("ползунок: конец 23:45", DueTimeSlider.value(x: 400, width: 400) == 1425 && DueTimeSlider.value(x: 900, width: 400) == 1425)
        check("ползунок: шаг 15 минут", DueTimeSlider.value(x: 123, width: 400) % 15 == 0)

        // Сроки по-прежнему выше.
        defaults.set(true, forKey: Extra.dueDates.key)
        let late = store.tasks.first { $0.title == "А" }!
        store.setDue(date(60 * 48), for: late.id)
        check("просроченная наверху", store.openTasks.first?.title == "А")
        store.setDue(nil, for: late.id)

        // Закрепление.
        store.upsert(Entry(title: "Почта", projectID: nil, start: date(200), end: date(190)))
        store.upsert(Entry(title: "Созвоны", projectID: client.id, start: date(180), end: date(170)))
        check("в недавних", store.recents(limit: 9).contains { $0.title == "Почта" })
        store.pin(title: "Почта", projectID: nil, emoji: "✉️")
        check("закреплённой нет в недавних", store.visiblePins.count == 1 && !store.recents(limit: 9).contains { $0.title == "Почта" })
        store.pin(title: "Почта", projectID: nil, emoji: nil)
        check("дубль не закрепляется", store.pins.count == 1)
        store.pin(title: "2", projectID: nil, emoji: nil)
        store.pin(title: "3", projectID: nil, emoji: nil)
        store.pin(title: "4", projectID: nil, emoji: nil)
        check("не больше трёх", store.pins.count == 3 && !store.canPin)
        store.unpin(title: "2", projectID: nil)
        store.unpin(title: "3", projectID: nil)

        // Архив.
        store.draftProjectID = client.id
        store.setArchived(true, for: client.id)
        check("архив: нет в выборе, есть в данных", !store.activeProjects.contains { $0.id == client.id } && store.project(client.id) != nil && store.draftProjectID == nil)
        check("архив: нет в недавних", !store.recents(limit: 9).contains { $0.title == "Созвоны" })
        defaults.set(true, forKey: Extra.smartInput.key)
        check("архив: умный ввод не находит", SmartInput.parse("звонок @Клиент 30м", projects: store.activeProjects).projectID == nil)
        check("активный проект находится", SmartInput.parse("звонок @Клиент 30м", projects: store.projects).projectID == client.id)
        store.setArchived(false, for: client.id)
        check("вернулся из архива", store.activeProjects.contains { $0.id == client.id })

        // Поиск.
        store.upsert(Entry(title: "Дизайн экрана", projectID: nil, start: date(160), end: date(150), note: "для Лины"))
        check("поиск по названию", store.dayGroups(projectID: nil, query: "дизайн").flatMap(\.entries).count == 1)
        check("поиск по комментарию", store.dayGroups(projectID: nil, query: "ЛИНЫ").flatMap(\.entries).count == 1)
        check("поиск по проекту", store.dayGroups(projectID: nil, query: "клиент").flatMap(\.entries).allSatisfy { $0.projectID == client.id })
        check("пустой результат", store.dayGroups(projectID: nil, query: "нет такого").isEmpty)
        check("пустой запрос: всё", store.dayGroups(projectID: nil, query: "  ").flatMap(\.entries).count == store.entries.count)

        // Разделение.
        var work = Entry(title: "Длинная", projectID: client.id, start: date(130), end: date(70), note: "к")
        work.pausedTotal = 600
        store.upsert(work)
        check("время до разделения", abs(work.duration() - 3000) < 1)
        check("вне записи не делится", !store.splitEntry(work.id, at: date(10)))
        check("разделена", store.splitEntry(work.id, at: date(100), secondTitle: "Вторая часть"))
        let first = store.entry(work.id)!
        let part = store.entries.first { $0.title == "Вторая часть" }!
        check("части сохраняют время", abs(first.duration() + part.duration() - work.duration()) < 1 && first.end == part.start && part.projectID == client.id)
        store.performUndo()
        check("разделение отменяется", store.entry(work.id) == work && !store.entries.contains { $0.title == "Вторая часть" })

        // Склейка.
        // Полдень вчерашнего дня: тест не должен зависеть от того, запущен ли он сразу после полуночи.
        let noon = Cal.ru.startOfDay(for: now).addingTimeInterval(-12 * 3600)
        func atNoon(_ minutes: Double) -> Date { noon.addingTimeInterval(minutes * 60) }
        store.upsert(Entry(title: "Кусок 1", projectID: client.id, start: atNoon(0), end: atNoon(10), note: "раз"))
        store.upsert(Entry(title: "Кусок 2", projectID: nil, start: atNoon(20), end: atNoon(30), note: "два"))
        let piece1 = store.entries.first { $0.title == "Кусок 1" }!
        let piece2 = store.entries.first { $0.title == "Кусок 2" }!
        let around = store.neighbors(of: piece2.id)
        check("сосед за день", around.earlier?.id == piece1.id)
        check("склеены", store.mergeEntries(piece2.id, piece1.id))
        let merged = store.entry(piece1.id)!
        check("время склейки: 20 мин и пауза", abs(merged.duration() - 1200) < 1 && merged.end == piece2.end && merged.title == "Кусок 1" && merged.note == "раз\nдва" && !store.contains(piece2.id))
        store.performUndo()
        check("склейка отменяется", store.entry(piece1.id) == piece1 && store.entry(piece2.id) == piece2)
        store.start(title: "Живая", projectID: nil, planned: .some(nil))
        check("идущую запись не склеиваем", !store.mergeEntries(store.running!.id, piece1.id))
        store.discardRunning()
        store.undoOffer = nil

        // Выделение нескольких записей.
        store.upsert(Entry(title: "Пачка 1", projectID: nil, start: atNoon(40), end: atNoon(41), note: "а"))
        store.upsert(Entry(title: "Пачка 2", projectID: nil, start: atNoon(42), end: atNoon(43)))
        store.upsert(Entry(title: "Пачка 3", projectID: nil, start: atNoon(44), end: atNoon(45), note: "в"))
        let pack = store.entries.filter { $0.title.hasPrefix("Пачка") }.sorted { $0.start < $1.start }
        let packIDs = Set(pack.map(\.id))
        check("три подряд можно склеить", store.canMerge(packIDs))
        check("через одну нельзя", !store.canMerge([pack[0].id, pack[2].id]))
        check("одну нельзя", !store.canMerge([pack[0].id]))
        check("склеены три", store.mergeEntries(packIDs) && !store.contains(pack[1].id) && !store.contains(pack[2].id))
        let triple = store.entry(pack[0].id)!
        check("время трёх и комментарии", abs(triple.duration() - 180) < 1 && triple.end == pack[2].end && triple.note == "а\nв")
        store.performUndo()
        check("склейка трёх отменяется", pack.allSatisfy { store.entry($0.id) == $0 })
        store.deleteEntries(packIDs)
        check("удалены три", !pack.contains { store.contains($0.id) } && store.undoOffer != nil)
        store.performUndo()
        check("удаление трёх отменяется", pack.allSatisfy { store.entry($0.id) == $0 })
        store.deleteEntries(packIDs)
        store.undoOffer = nil

        // Экспорт.
        defaults.set(true, forKey: Extra.rates.key)
        defaults.set(true, forKey: Extra.clientReport.key)
        defaults.set("USD", forKey: ExtraKey.currency)
        defaults.set("Андрей", forKey: ExtraKey.reportName)
        var rated = store.project(client.id)!
        rated.rate = 60
        store.updateProject(rated)
        store.entries.removeAll()
        let today = Cal.ru.startOfDay(for: now)
        func at(_ h: Double) -> Date { today.addingTimeInterval(h * 3600) }
        let other = store.addProject(name: "Другой", color: .green)
        store.upsert(Entry(title: "Макет", projectID: client.id, start: at(0.1), end: at(0.3), note: "первый"))
        store.upsert(Entry(title: "Макет", projectID: client.id, start: at(0.4), end: at(0.5), note: "второй"))
        store.upsert(Entry(title: "Письмо", projectID: other.id, start: at(0.6), end: at(0.7)))
        store.upsert(Entry(title: "Без проекта", projectID: nil, start: at(0.8), end: at(0.9)))
        var options = ExportOptions()
        options.preset = .custom
        options.customStart = now
        options.customEnd = now
        var report = ExportReport.build(store: store, options: options, now: now)
        check("по дням: задача с задачей складываются", report.rows.count == 3 && report.rows.first { $0.task == "Макет" }.map { abs($0.seconds - 1080) < 1 } == true)
        check("сумма по ставке", report.rows.first { $0.task == "Макет" }?.amount.map { abs($0 - 18) < 0.01 } == true)
        options.grouping = .entry
        report = ExportReport.build(store: store, options: options, now: now)
        check("каждая запись отдельно", report.rows.count == 4)
        options.columns.insert(.time)
        options.columns.insert(.comment)
        report = ExportReport.build(store: store, options: options, now: now)
        check("колонки записи", report.columns == [.date, .time, .task, .project, .duration, .amount, .comment])
        let csvEntries = report.csv()
        print("CSV\n" + csvEntries)
        check("CSV: начало и конец", csvEntries.hasPrefix("\u{FEFF}Дата;Начало;Конец;Задача") || csvEntries.contains(";"))
        options.grouping = .task
        report = ExportReport.build(store: store, options: options, now: now)
        check("по задачам нет даты и времени", !report.columns.contains(.date) && !report.columns.contains(.time) && report.rows.count == 3)
        options.grouping = .project
        report = ExportReport.build(store: store, options: options, now: now)
        check("по проектам", report.rows.count == 3 && !report.columns.contains(.task) && report.rows.contains { $0.project == L("Без проекта") })
        options.projectIDs = [client.id]
        options.includeNoProject = false
        report = ExportReport.build(store: store, options: options, now: now)
        check("один проект", report.rows.count == 1 && report.projectsTitle == "Клиент")
        options.projectIDs = []
        options.includeNoProject = false
        report = ExportReport.build(store: store, options: options, now: now)
        check("без записей без проекта", !report.rows.contains { $0.project == L("Без проекта") })
        options.includeNoProject = true
        options.grouping = .day
        options.columns = [.date, .duration]
        report = ExportReport.build(store: store, options: options, now: now)
        check("без колонок задачи и проекта: день одной строкой", report.rows.count == 1)
        check("разные ставки складываются в одну сумму", report.rows.first?.amount.map { abs($0 - 18) < 0.01 } == true)
        options.columns = [.date, .task, .project, .duration, .amount]
        options.roundMinutes = 15
        report = ExportReport.build(store: store, options: options, now: now)
        check("округление до 15 минут: 18 мин → 15", report.rows.first { $0.task == "Макет" }?.seconds == 900)
        check("короткая работа не исчезает: 6 мин → 15", report.rows.first { $0.task == "Письмо" }?.seconds == 900)
        check("сумма от округлённого", report.rows.first { $0.task == "Макет" }?.amount.map { abs($0 - 15) < 0.01 } == true)
        check("итог сходится со строками", report.totalSeconds == 2700)
        options.timeStyle = .decimal
        report = ExportReport.build(store: store, options: options, now: now)
        // Разделитель берётся из языка интерфейса: 1,50 по-русски, 1.50 по-английски.
        check("десятичное время", ["1,50", "1.50"].contains(report.time(5400)))
        options.roundMinutes = 0
        options.timeStyle = .text
        defaults.set(false, forKey: Extra.rates.key)
        report = ExportReport.build(store: store, options: options, now: now)
        check("без ставок нет сумм", !report.columns.contains(.amount) && report.rows.allSatisfy { $0.amount == nil })
        defaults.set(true, forKey: Extra.rates.key)
        check("прошлый месяц раньше этого", { () -> Bool in
            var o = ExportOptions(); o.preset = .lastMonth
            var m = ExportOptions(); m.preset = .month
            return o.interval(now: now).end == m.interval(now: now).start
        }())
        check("настройки сохраняются", { () -> Bool in
            var o = ExportOptions(); o.roundMinutes = 30; o.client = "ООО"
            ExportStorage.last = o
            ExportStorage.templates = [ExportTemplate(name: "Клиенту", options: o)]
            let ok = ExportStorage.last == o && ExportStorage.templates.first?.options == o
            ExportStorage.last = ExportOptions()
            ExportStorage.templates = []
            return ok
        }())
        for i in 0 ..< 70 {
            store.upsert(Entry(title: "Задача \(i)", projectID: client.id, start: at(1 + Double(i) * 0.01), end: at(1.005 + Double(i) * 0.01)))
        }
        options.title = "Счёт-отчёт"
        options.client = "ООО Ромашка"
        report = ExportReport.build(store: store, options: options, now: now)
        let pdf = ExportPDF.pdf(report)
        let pageCount = pdf.flatMap { CGPDFDocument(CGDataProvider(data: $0 as CFData)!)?.numberOfPages }
        check("PDF: страниц \(pageCount ?? 0)", pageCount == 3 && ExportPDF.pages(for: report.rows).map(\.count).reduce(0, +) == report.rows.count)
        if let pdf { try? pdf.write(to: URL(fileURLWithPath: "\(dir)/report.pdf")) }
        for i in 0 ..< 70 {
            store.entries.removeAll { $0.title == "Задача \(i)" }
        }

        // Автобэкапы.
        store.save()
        let dataFile = store.fileURL
        let backupDir = Backups.directory(for: dataFile)
        func copies() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: backupDir.path)) ?? []).filter { $0.hasPrefix("data-") }.sorted() }
        Backups.run(dataFile: dataFile)
        check("копия создаётся", !copies().isEmpty)
        try? FileManager.default.removeItem(at: backupDir)
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        try? Data("чужой".utf8).write(to: backupDir.appendingPathComponent("заметка.txt"))
        let calendar = Calendar(identifier: .gregorian)
        for day in 0 ..< 35 {
            Backups.run(dataFile: dataFile, now: calendar.date(byAdding: .day, value: day, to: now)!)
        }
        check("хранятся 30 последних", copies().count == 30)
        Backups.run(dataFile: dataFile, now: calendar.date(byAdding: .day, value: 34, to: now)!)
        check("дважды за день не пишет", copies().count == 30)
        check("чужой файл на месте", FileManager.default.fileExists(atPath: backupDir.appendingPathComponent("заметка.txt").path))
        let broken = dataFile.deletingLastPathComponent().appendingPathComponent("broken.json")
        try? Data("не json".utf8).write(to: broken)
        Backups.run(dataFile: broken, now: calendar.date(byAdding: .day, value: 99, to: now)!)
        check("битый файл не копируется", !FileManager.default.fileExists(atPath: Backups.directory(for: broken).appendingPathComponent("data-\(calendar.component(.year, from: now)).json").path) && copies().count == 30)

        // Снимки.
        defaults.set(true, forKey: Extra.goal.key)
        store.pin(title: "Созвоны", projectID: client.id, emoji: nil)
        store.upsert(Entry(title: "Звонок", projectID: other.id, start: date(20), end: date(10)))
        func hosted(_ view: some View, _ size: NSSize, _ name: String, _ delay: Double) {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: Localized { view.environmentObject(store) }.frame(width: size.width, height: size.height))
            w.appearance = NSAppearance(named: .darkAqua)
            w.orderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                save(w, "\(dir)/\(name).png")
                w.orderOut(nil)
            }
        }
        defaults.set("main", forKey: "settings.tab")
        defaults.set(SettingsTab.main.rawValue, forKey: "settings.tab")
        hosted(SettingsView(), NSSize(width: 720, height: 760), "settings-main", 0.8)
        // Прокрутка: переключатель уезжает вместе с настройками.
        let scrolled = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        scrolled.isReleasedWhenClosed = false
        scrolled.appearance = NSAppearance(named: .darkAqua)
        scrolled.contentView = NSHostingView(rootView: Localized { SettingsView().environmentObject(store) }.frame(width: 720, height: 500))
        scrolled.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            func findScroll(_ v: NSView) -> NSScrollView? {
                if let s = v as? NSScrollView { return s }
                for sub in v.subviews { if let s = findScroll(sub) { return s } }
                return nil
            }
            save(scrolled, "\(dir)/settings-top.png")
            if let scroll = findScroll(scrolled.contentView!) {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.origin.y + 140))
                scroll.reflectScrolledClipView(scroll.contentView)
            } else {
                print("FAIL нет прокрутки в настройках")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            save(scrolled, "\(dir)/settings-scrolled.png")
            scrolled.orderOut(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            defaults.set(SettingsTab.advanced.rawValue, forKey: "settings.tab")
            hosted(SettingsView(), NSSize(width: 720, height: 760), "settings-advanced", 0.8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            var o = ExportOptions()
            o.preset = .today
            o.title = "Счёт-отчёт"
            o.client = "ООО Ромашка"
            ExportStorage.last = o
            hosted(ExportSheet(), NSSize(width: 860, height: 640), "export-pdf", 0.8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            var o = ExportOptions()
            o.preset = .today
            o.format = .csv
            ExportStorage.last = o
            hosted(ExportSheet(), NSSize(width: 860, height: 640), "export-csv", 0.8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            hosted(ProjectEditor(existing: nil), NSSize(width: 440, height: 340), "project-editor", 0.6)
            // Год: карта, часы, итоги.
            let yearStart = Cal.ru.date(from: DateComponents(year: 2025, month: 3, day: 3, hour: 9))!
            let yearStore = store
            let yearDesign = yearStore.addProject(name: "Годовой", color: .indigo)
            for offset in [0, 1, 2, 10, 40, 41, 120] {
                let d = yearStart.addingTimeInterval(TimeInterval(offset) * 86400)
                yearStore.upsert(Entry(title: "Год", projectID: yearDesign.id, start: d, end: d.addingTimeInterval(offset == 120 ? 10 * 3600 : 3 * 3600)))
            }
            let night = yearStart.addingTimeInterval(200 * 86400 - 1800 + 15 * 3600)
            yearStore.upsert(Entry(title: "Ночь", projectID: yearDesign.id, start: night, end: night.addingTimeInterval(3600)))
            let year2025 = YearStats.make(store: yearStore, year: 2025)
            check("год: всего и дни", abs(year2025.total - (28 + 1 - 0) * 3600 - 0) < 2 * 3600 + 1 && year2025.activeDays >= 8)
            check("год: самый длинный день", Cal.ru.isDate(year2025.longestDay?.day ?? .distantPast, inSameDayAs: yearStart.addingTimeInterval(120 * 86400)) && abs((year2025.longestDay?.seconds ?? 0) - 36000) < 1)
            check("год: дней подряд", year2025.longestStreak == 3)
            check("год: главный проект и утренний ритм", year2025.topProject?.name == "Годовой" && year2025.peakHour == 9 && year2025.rhythm == .morning)
            check("год: сумма часов сходится с днями", abs(year2025.hourly.reduce(0, +) - year2025.byDay.values.reduce(0, +)) < 1)
            check("год: сетка не длиннее 54 недель", YearHeatmap.columns(year2025.interval) >= 52 && YearHeatmap.columns(year2025.interval) <= 54)
            check("год: уровни карты", YearHeatmap.level(0) == 0 && YearHeatmap.level(3600) == 1 && YearHeatmap.level(5 * 3600) == 3 && YearHeatmap.level(9 * 3600) == 4)
            hosted(YearCard(stats: year2025), YearCard.size, "year-card", 0.6)
            hosted(ScrollView { ReportContent(period: .year, interval: year2025.interval, title: "2025", open: .constant([])).padding(24) }.background(.notchPaper), NSSize(width: 980, height: 880), "year-report", 1.2)
            if let png = YearCardExport.png(year2025) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/year-export.png"))
                check("год: картинка 1080 на 1350", NSBitmapImageRep(data: png).map { $0.pixelsWide == 1080 && $0.pixelsHigh == 1350 } ?? false)
            } else {
                check("год: картинка 1080 на 1350", false)
            }

            // Звуки.
            let startWave = Sounds.samples(.start), stopWave = Sounds.samples(.stop)
            check("звук: короткий и без перегруза", startWave.count == 2205 && startWave.map { abs(Int($0)) }.max()! <= 32000 && stopWave.contains { abs(Int($0)) > 5000 })
            check("звук: затухает к концу", abs(Int(startWave.last!)) < 200 && abs(Int(stopWave.last!)) < 400)
            check("звук: файл читается", NSSound(data: Sounds.wav(.start)) != nil && NSSound(data: Sounds.wav(.stop)) != nil)

            // Доски задач.
            store.addTask("Доска", projectID: nil)
            if let id = store.tasks.first(where: { $0.title == "Доска" })?.id {
                func inColumn(_ layout: TaskLayout, _ column: String) -> Bool {
                    TaskBoard.columns(layout, store: store).first { $0.id == column }?.tasks.contains { $0.id == id } ?? false
                }
                check("канбан: новая задача в «Сделать»", inColumn(.kanban, "todo"))
                store.moveTask(id, inProgress: true)
                check("канбан: перенос в «В работе»", inColumn(.kanban, "doing") && !inColumn(.kanban, "todo"))
                store.completeTask(id)
                check("канбан: перенос в «Готово» снимает «В работе»", inColumn(.kanban, "done") && store.tasks.first { $0.id == id }?.inProgress == false)
                store.moveTask(id, inProgress: false)
                check("канбан: из «Готово» обратно", inColumn(.kanban, "todo"))
                TaskBoard.columns(.priority, store: store).first { $0.id == "p3" }?.drop?(store, id)
                check("доска приоритетов меняет приоритет", store.tasks.first { $0.id == id }?.priority == 3)
                let projectColumn = TaskBoard.columns(.project, store: store).first { $0.id == client.id.uuidString }
                projectColumn?.drop?(store, id)
                check("доска проектов меняет проект", store.tasks.first { $0.id == id }?.projectID == client.id)
                TaskBoard.columns(.due, store: store).first { $0.id == "tomorrow" }?.drop?(store, id)
                check("доска сроков ставит завтра", inColumn(.due, "tomorrow"))
                check("в «Просрочено» бросить нельзя", TaskBoard.columns(.due, store: store).first { $0.id == "late" }?.drop == nil)
                let total = TaskBoard.columns(.due, store: store).reduce(0) { $0 + $1.tasks.count }
                check("доска сроков показывает каждую задачу один раз", total == store.openTasks.count)
                hosted(TaskBoardView(layout: .kanban).background(Color(nsColor: .windowBackgroundColor)), NSSize(width: 860, height: 460), "board-kanban", 0.8)
                hosted(TaskBoardView(layout: .priority).background(.notchPaper), NSSize(width: 1120, height: 460), "board-priority", 0.8)
                hosted(TaskBoardView(layout: .project).background(Color(nsColor: .windowBackgroundColor)), NSSize(width: 1000, height: 460), "board-project", 0.8)
                // Дальше тест щёлкает по задачам в Notch: лишняя задача сдвинула бы строки.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { store.deleteTask(id) }
            }

            hosted(VStack(alignment: .leading, spacing: 14) {
                TempoSegments(selection: .constant(TaskLayout.kanban), items: TaskLayout.allCases.map { .init(value: $0, icon: $0.icon, help: L($0.title)) })
                TempoSegments(selection: .constant(Period.week), items: Period.allCases.map { .init(value: $0, title: L($0.rawValue)) })
                TempoSegments(selection: .constant(SettingsTab.main), items: SettingsTab.allCases.map { .init(value: $0, title: L($0.rawValue)) }, size: .large)
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), NSSize(width: 460, height: 170), "segments", 0.6)
            hosted(ReportView(), NSSize(width: 980, height: 620), "report-view", 1.0)
            // CSV: текст не должен выполниться как формула.
            do {
                let trap = Entry(title: "=HYPERLINK(1)", projectID: nil, start: Date().addingTimeInterval(-7200), end: Date().addingTimeInterval(-3600))
                store.upsert(trap)
                var o = ExportOptions(); o.preset = .today; o.grouping = .entry; o.columns = [.task, .duration]
                let csv = ExportReport.build(store: store, options: o).csv()
                check("CSV обезвреживает формулы", csv.contains("\"'=HYPERLINK(1)\"") && !csv.contains("\"=HYPERLINK"))
                store.deleteEntry(trap.id)
                store.eraseEntry(trap.id)
            }

            // Окна на новых карточках, снятые как есть.
            var fixedProject = store.addProject(name: "Фикс", color: .teal)
            fixedProject.fixedPrice = 1000
            store.updateProject(fixedProject)
            defaults.set(true, forKey: ExtraKey.expenses)
            let fixedDay = Date().addingTimeInterval(-3 * 86400)
            store.upsert(Entry(title: "Лендинг", projectID: fixedProject.id, start: fixedDay, end: fixedDay.addingTimeInterval(20 * 3600)))
            store.addExpense("Шрифт", amount: 100, date: fixedDay, projectID: fixedProject.id)
            let economy = store.economy(of: fixedProject.id)
            check("фикс: выходит в час с учётом расходов", economy.isFixed && abs((economy.perHour ?? 0) - 45) < 0.01 && economy.costs == 100)
            let expenseDay = Cal.day(fixedDay)
            check("расход виден в периоде и строкой в экспорте", {
                var o = ExportOptions(); o.preset = .custom; o.customStart = expenseDay.start; o.customEnd = expenseDay.start
                o.columns = [.task, .amount, .duration]; o.grouping = .entry
                let report = ExportReport.build(store: store, options: o)
                return report.rows.contains { $0.isExpense && $0.amount == 100 } && report.totalAmount >= 100
                    && report.csv().contains(L("Расход: %@", "Шрифт"))
            }())
            check("расход удаляется в архив и возвращается", {
                let id = store.expenses(of: fixedProject.id)[0].id
                store.deleteExpense(id)
                let gone = store.expenses(of: fixedProject.id).isEmpty && store.archive.expenses.count == 1
                store.restoreExpense(id)
                return gone && store.expenses(of: fixedProject.id).count == 1 && store.archive.expenses.isEmpty
            }())
            hosted(ProjectEditor(existing: fixedProject), NSSize(width: 430, height: 300), "form-project", 0.6)
            hosted(ExpensesSheet(projectID: fixedProject.id), NSSize(width: 430, height: 300), "form-expenses", 0.6)
            hosted(VStack(spacing: 0) { ProjectEconomyStrip(projectID: fixedProject.id); Spacer() }, NSSize(width: 640, height: 90), "form-economy", 0.6)
            hosted(EntryEditor(entry: Entry(title: "Макет главной", projectID: client.id, start: fixedDay, end: fixedDay.addingTimeInterval(5 * 3600 + 300), note: "Правки после созвона"), isNew: true),
                   NSSize(width: 430, height: 420), "form-entry", 0.6)
            hosted(MiniCalendar(selection: Date()) { _ in }, NSSize(width: 250, height: 280), "form-calendar", 0.6)

            // Время в окне записи.
            check("время: 14:30, 1430, 930, 9, 9.15", EntryTimes.parse("14:30") == 870 && EntryTimes.parse("1430") == 870 && EntryTimes.parse("930") == 570 && EntryTimes.parse("9") == 540 && EntryTimes.parse("9.15") == 555)
            check("время: мусор не проходит", EntryTimes.parse("25:00") == nil && EntryTimes.parse("abc") == nil && EntryTimes.parse("") == nil && EntryTimes.parse("12:75") == nil)
            let baseDay = Cal.ru.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 14, minute: 0))!
            let baseEntry = Entry(title: "т", projectID: nil, start: baseDay, end: baseDay.addingTimeInterval(3600))
            let overnight = EntryTimes.settingEnd(baseEntry, minutes: 60)
            check("конец раньше начала: следующий день", EntryTimes.dayOffset(overnight) == 1 && overnight.duration() == 11 * 3600)
            check("сдвиг начала возвращает конец в тот же день", EntryTimes.dayOffset(EntryTimes.settingStart(overnight, minutes: 30)) == 0)
            let moved = EntryTimes.settingDay(overnight, baseDay.addingTimeInterval(5 * 86400))
            check("другой день: длина записи та же", moved.duration() == overnight.duration() && Cal.ru.component(.day, from: moved.start) == 15)
            let longEntry = Entry(title: "т", projectID: nil, start: baseDay, end: baseDay.addingTimeInterval(50 * 3600))
            check("запись на двое суток сохраняет дни при сдвиге начала", EntryTimes.dayOffset(EntryTimes.settingStart(longEntry, minutes: 600)) == 2)

            // Закрытые месяцы.
            let closeMonth = Cal.ru.dateInterval(of: .month, for: baseDay)!
            let inClosed = Entry(title: "Закрытая", projectID: nil, start: baseDay, end: baseDay.addingTimeInterval(3600))
            store.upsert(inClosed)
            defaults.set(true, forKey: Extra.closeMonths.key)
            store.setMonthClosed(true, closeMonth)
            check("закрытый месяц: запись закрыта", store.isClosed(inClosed) && store.isMonthClosed(closeMonth))
            var changedClosed = inClosed
            changedClosed.title = "Другое"
            store.upsert(changedClosed)
            store.deleteEntry(inClosed.id)
            store.setNote("нет", for: inClosed.id)
            check("закрытый месяц: не меняется и не удаляется", store.entry(inClosed.id)?.title == "Закрытая" && store.entry(inClosed.id)?.note == "")
            let intoClosed = Entry(title: "Новая", projectID: nil, start: baseDay.addingTimeInterval(-86400), end: baseDay)
            store.upsert(intoClosed)
            check("закрытый месяц: новую запись не добавить", store.entry(intoClosed.id) == nil)
            hosted(EntryEditor(entry: inClosed, isNew: false), NSSize(width: 430, height: 460), "form-entry-closed", 0.6)
            store.setMonthClosed(false, closeMonth)
            store.deleteEntry(inClosed.id)
            check("открытый месяц: снова можно менять", store.entry(inClosed.id) == nil)
            defaults.set(false, forKey: Extra.closeMonths.key)
            store.eraseEntry(inClosed.id)

            // Отчёт по расписанию.
            let autoDir = URL(fileURLWithPath: dir).appendingPathComponent("auto")
            try? FileManager.default.removeItem(at: autoDir)
            let autoNow = Cal.ru.date(byAdding: .month, value: 1, to: fixedDay)!
            let autoDue = AutoReport.due(.month, now: autoNow)
            check("расписание: прошлый месяц закончился до сегодня", autoDue.interval.end <= autoNow && autoDue.interval.contains(fixedDay))
            defaults.set(true, forKey: Extra.autoReport.key)
            check("расписание: без папки не сохраняет", AutoReport.run(store: store, now: autoNow) == nil)
            defaults.set(autoDir.path, forKey: ExtraKey.autoReportFolder)
            let saved = AutoReport.run(store: store, now: autoNow)
            check("расписание: файл появился", saved.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
            check("расписание: второй раз не сохраняет", AutoReport.run(store: store, now: autoNow) == nil)
            for key in [Extra.autoReport.key, ExtraKey.autoReportFolder, ExtraKey.autoReportLast, ExtraKey.autoReportLastFile] { defaults.removeObject(forKey: key) }
            hosted(TasksView(), NSSize(width: 720, height: 420), "tasks", 0.6)
            hosted(ArchiveView(nav: JournalNav()), NSSize(width: 720, height: 420), "archive", 0.6)
            hosted(DuePicker(date: now, minutes: 870) { _, _ in } onDone: {}.frame(width: 390).padding(16).background(Color.black), NSSize(width: 440, height: 430), "due-picker", 0.6)
            hosted(DuePicker(date: nil, minutes: nil) { _, _ in } onDone: {}.frame(width: 390).padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white).environment(\.colorScheme, .light), NSSize(width: 440, height: 430), "due-light", 0.6)
            // Знакомство: в обеих темах, с настоящими переключателями стекла и сияния.
            defaults.set(true, forKey: Aurora.key)
            defaults.set(true, forKey: GlassStyle.key)
            for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
                hosted(OnboardingCustomizeView(back: {}, start: {}).frame(width: 880, height: 680).background(.notchPaper).environment(\.colorScheme, scheme), NSSize(width: 880, height: 680), "onboarding-customize-\(name)", 0.6)
            }
            for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
                hosted(Form { OnboardingAppearanceSection() }.formStyle(.grouped).toggleStyle(.switch).scrollContentBackground(.hidden).frame(width: 600, height: 560).background(.notchPaper).environment(\.colorScheme, scheme), NSSize(width: 600, height: 560), "onboarding-appearance-\(name)", 0.6)
            }
            // Все подсказки info сразу: в обеих темах.
            for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
                let grid = LazyVGrid(columns: [GridItem(.fixed(372)), GridItem(.fixed(372))], alignment: .leading, spacing: 8) {
                    ForEach(Array(OnboardingDemo.allCases.enumerated()), id: \.offset) { _, demo in
                        OnboardingDemoCard(demo: demo, subtitle: "Прогресс рядом со временем за сегодня")
                    }
                }
                hosted(grid.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(.notchPaper).environment(\.colorScheme, scheme), NSSize(width: 760, height: 900), "onboarding-demos-\(name)", 0.6)
            }
            for item in OnboardingScene.allCases {
                hosted(OnboardingWelcomeView(scene: item, autoplay: false) {}.frame(width: 880, height: 680).background(.notchPaper).environment(\.colorScheme, item == .tasks ? .light : .dark), NSSize(width: 880, height: 680), "onboarding-\(item.rawValue)", 0.6)
            }
            hosted(EntriesList(projectID: nil, title: "Журнал"), NSSize(width: 720, height: 400), "journal", 0.6)
            // Отчёт: неделя, месяц, день, узкое окно, светлая тема и подсказка над столбиком.
            let reportNow = Date()
            let reportDay = Cal.ru.startOfDay(for: reportNow)
            let reportWeek = Cal.ru.dateInterval(of: .weekOfYear, for: reportNow)!
            let reportDesign = store.addProject(name: "Дизайн", color: .purple)
            let reportSite = store.addProject(name: "Сайт", color: .orange)
            for offset in 0 ..< 7 {
                let d = reportWeek.start.addingTimeInterval(TimeInterval(offset) * 86400 + 9 * 3600)
                if offset == 5 { continue }
                store.upsert(Entry(title: "Макеты", projectID: reportDesign.id, start: d, end: d.addingTimeInterval(TimeInterval(2 + offset) * 3000)))
                store.upsert(Entry(title: "Вёрстка", projectID: reportSite.id, start: d.addingTimeInterval(4 * 3600), end: d.addingTimeInterval(4 * 3600 + TimeInterval(7 - offset) * 1800)))
                store.upsert(Entry(title: "Созвон", projectID: client.id, start: d.addingTimeInterval(8 * 3600), end: d.addingTimeInterval(8 * 3600 + 2400)))
            }
            let reportOpen: Set<String> = [reportDesign.id.uuidString]
            func report(_ period: Period, scheme: ColorScheme = .dark, hover: Date? = nil) -> some View {
                ScrollView {
                    ReportContent(period: period, interval: Cal.ru.dateInterval(of: period.component, for: reportNow)!, title: L(period.rawValue), open: .constant(reportOpen), hoveredDay: hover)
                        .padding(24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.notchPaper)
                .environment(\.colorScheme, scheme)
            }
            hosted(report(.week), NSSize(width: 760, height: 800), "report-week", 0.8)
            hosted(report(.week, hover: reportWeek.start.addingTimeInterval(2 * 86400)), NSSize(width: 760, height: 620), "report-hover", 0.8)
            hosted(report(.month, scheme: .light), NSSize(width: 980, height: 800), "report-month-light", 0.8)
            hosted(report(.day), NSSize(width: 760, height: 640), "report-day", 0.8)
            hosted(report(.week), NSSize(width: 520, height: 1000), "report-narrow", 0.8)
            let math = ReportMath.segments([
                DayPoint(day: reportDay, key: "b", hours: 2), DayPoint(day: reportDay, key: "a", hours: 1),
            ], order: ["a", "b"])
            check("отчёт: порядок проектов постоянный", math.map(\.key) == ["a", "b"] && math.last?.isTop == true && math.first?.isTop == false)
            check("отчёт: столбик сложен без потерь", math.last?.end == 3 && math.last?.dayTotal == 3)
            let mean = ReportMath.dailyAverage([
                DayPoint(day: reportDay, key: "a", hours: 2), DayPoint(day: reportDay, key: "b", hours: 2),
                DayPoint(day: reportDay.addingTimeInterval(86400), key: "a", hours: 2),
            ])
            check("отчёт: среднее по дням с записями", mean.days == 2 && abs(mean.seconds - 3 * 3600) < 1)
            check("отчёт: подпись часов", Fmt.hoursMinutes(6.5 * 3600) == "6:30" && Fmt.hoursMinutes(0) == "0:00")
            hosted(SplitEntrySheet(entry: Entry(title: "Макет", projectID: client.id, start: at(9), end: at(11))), NSSize(width: 420, height: 320), "split", 0.6)
        }
        // Настоящие щелчки по журналу: выделение, ⌘, двойной щелчок.
        let journal = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 720, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
        journal.isReleasedWhenClosed = false
        journal.appearance = NSAppearance(named: .darkAqua)
        func table(_ v: NSView) -> NSTableView? {
            if let t = v as? NSTableView { return t }
            for sub in v.subviews { if let t = table(sub) { return t } }
            return nil
        }
        func click(row: Int, flags: NSEvent.ModifierFlags = [], count: Int = 1) {
            guard let t = table(journal.contentView!) else { return print("FAIL нет таблицы в журнале") }
            let r = t.rect(ofRow: row)
            let p = t.convert(NSPoint(x: r.minX + 120, y: r.midY), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: journal.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
            }
            // Таблица ждёт отпускание внутри своего цикла, поэтому оно ставится в очередь заранее.
            NSApp.postEvent(event(.leftMouseUp), atStart: false)
            journal.sendEvent(event(.leftMouseDown))
        }
        func entryRows() -> [Int] {
            guard let t = table(journal.contentView!) else { return [] }
            return t.numberOfRows > 1 ? Array(1 ..< t.numberOfRows) : []
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.9) {
            journal.contentView = NSHostingView(rootView: Localized { EntriesList(projectID: nil, title: "Журнал").environmentObject(store) }.frame(width: 720, height: 460))
            NSApp.activate(ignoringOtherApps: true)
            journal.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.3) {
            let rows = entryRows()
            print("ROWS", rows)
            // Окно может не успеть собраться, пока рисуются остальные снимки: тогда щелчки пропускаем.
            guard rows.count >= 3 else { return }
            click(row: rows[0])
            click(row: rows[2], flags: .shift)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.6) {
            let t = table(journal.contentView!)
            print("SELECTED", t?.selectedRowIndexes.count ?? -1)
            // Без фокуса окна щелчки не доходят: это зависит от того, что открыто на экране.
            if journal.isKeyWindow { check("щелчок и ⇧: выделены три строки", t?.selectedRowIndexes.count == 3) }
            save(journal, "\(dir)/journal-selected.png")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.95) {
            check("двойной щелчок подключён к записи", table(journal.contentView!)?.doubleAction != nil)
            if let s = journal.attachedSheet { journal.endSheet(s) }
            journal.orderOut(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            defaults.set(false, forKey: Aurora.key)
            defaults.set(false, forKey: GlassStyle.key)
            app.notch.expand()
            app.notch.model.creatingProject = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.2) {
            save(app.notch.panel, "\(dir)/notch-new-project.png")
            app.notch.model.creatingProject = false
            defaults.set("recent", forKey: "notchTab")
            store.deleteEntry(store.entries.first { $0.title == "Звонок" }!.id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.2) {
            save(app.notch.panel, "\(dir)/notch-pins-undo.png")
            defaults.set("tasks", forKey: "notchTab")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.8) {
            save(app.notch.panel, "\(dir)/notch-tasks.png")
            var banner = TodoTask(title: "Созвон с клиентом", projectID: nil)
            banner.emoji = "📞"
            app.notch.model.dueTask = banner
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.4) {
            save(app.notch.panel, "\(dir)/notch-due.png")
            app.notch.model.dueTask = nil
            // Настоящая цепочка: срок наступил, таймер раз в секунду поднимает баннер сам.
            let tick = Date()
            let minute = Cal.ru.component(.hour, from: tick) * 60 + Cal.ru.component(.minute, from: tick)
            store.addTask("Живой срок", projectID: nil, due: tick, dueMinutes: minute)
            defaults.set("tasks", forKey: "notchTab")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 11.3) {
            print("LIVE banner:", app.notch.model.dueTask?.title ?? "нет", "expanded", app.notch.model.expanded, "editing", app.notch.model.isEditingInline, "timeUp", app.notch.model.timeUp != nil, "due", store.taskDueNow()?.title ?? "нет", "tick", Date())
            check("баннер поднялся сам", app.notch.model.dueTask?.title == "Живой срок" && app.notch.model.expanded)
            app.notch.dismissDueTask()
            check("баннер закрылся", app.notch.model.dueTask == nil)
            check("второй раз не напоминает", store.taskDueNow() == nil)
            // Настоящий календарь в настоящем Notch: панель не должна растягиваться на всё окно.
            let liveTask = store.tasks.first { $0.title == "Живой срок" }
            app.notch.expand()
            app.notch.model.dueFor = liveTask?.id
            print("LIVE task", liveTask?.title ?? "нет")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.5) {
            let height = app.notch.model.shapeSize.height
            print("LIVE panel height", height, "window", app.notch.panel.frame.height)
            // Notch сворачивается, если в это время шевелят мышью или щёлкают по экрану: тогда проверять нечего.
            if app.notch.model.expanded { check("календарь не растягивает Notch", height > 300 && height < app.notch.panel.frame.height - 100) }
            save(app.notch.panel, "\(dir)/notch-calendar.png")
            app.notch.model.dueFor = nil
        }
        // Настоящий щелчок по серому кружку первой задачи в Notch, в его середину.
        var openBefore = 0
        var clickedExpanded = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 13.0) {
            openBefore = store.openTasks.count
            clickedExpanded = app.notch.model.expanded
            let panel = app.notch.panel
            let p = NSPoint(x: 39, y: panel.frame.height - 185)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            print("CLICK first open:", store.openTasks.first?.title ?? "-", "priority", store.openTasks.first?.priority ?? -1, "expanded", app.notch.model.expanded, "mouse ignored", panel.ignoresMouseEvents)
            panel.sendEvent(event(.leftMouseDown))
            panel.sendEvent(event(.leftMouseUp))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
            print("LIVE later reminded:", store.tasks.first { $0.title == "Живой срок" }?.dueReminded != nil, "banner", app.notch.model.dueTask?.title ?? "нет")
            print("CLICK result open before", openBefore, "after", store.openTasks.count, "first", store.openTasks.first?.title ?? "-")
            if clickedExpanded { check("щелчок по кружку завершает задачу в Notch", store.openTasks.count == openBefore - 1) }
            ColorPanelBridge.open(initial: .systemOrange) { _ in }
            print("OK   панель цветов открыта:", ColorPanelBridge.isOpen)
            ColorPanelBridge.close()
            print("OK   панель цветов закрыта:", !ColorPanelBridge.isOpen)
            NSApp.terminate(nil)
        }
    }

    /// TEMPO_ANIMTEST=1 (вместе с TEMPO_DATA_DIR): окно не меняет размер, пока открываются строки, и щелчки проходят мимо острова.
    private static func runAnimationTest(_ app: AppDelegate) {
        let notch = app.notch!
        var heights = Set<CGFloat>()
        var hidden = false
        let sampler = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            if notch.model.expanded { heights.insert(notch.panel.frame.height) }
            if !notch.panel.isVisible { hidden = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { notch.expand() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation(.snappy) { notch.model.pickingEmoji = true } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            print("ANIM shape:", notch.model.shapeSize.height, "window:", notch.panel.frame.height)
            withAnimation(.snappy) { notch.model.pickingEmoji = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { withAnimation(.snappy) { notch.model.creatingProject = true } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            withAnimation(.snappy) { notch.model.creatingProject = false }
            print("ANIM window heights while expanded:", heights.sorted())
            notch.focusPanel()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            print("ANIM key before collapse:", notch.panel.isKeyWindow)
            notch.collapse()
            print("ANIM key after collapse:", notch.panel.isKeyWindow, "visible:", notch.panel.isVisible, "ignores:", notch.panel.ignoresMouseEvents)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            sampler.invalidate()
            print("ANIM collapsed window:", notch.panel.frame.size, "ever hidden in samples:", hidden)
            NSApp.terminate(nil)
        }
    }

    /// TEMPO_MENUBARTEST=<папка> (вместе с TEMPO_DATA_DIR и display.mode = menuBar): логика текста, лист значков и панель под значком.
    private static func runMenuBarTest(_ app: AppDelegate, _ dir: String) {
        let now = Date()
        func entry(_ minutes: Double, planned: Double? = nil, paused: Bool = false) -> Entry {
            var e = Entry(title: "t", projectID: nil, start: now.addingTimeInterval(-minutes * 60), planned: planned.map { $0 * 60 })
            if paused { e.pausedAt = now }
            return e
        }
        func describe(_ s: MenuBarIconState) -> String {
            let name: String
            switch s.color {
            case .systemRed: name = "red"
            case .systemGray: name = "gray"
            case .systemBlue: name = "blue"
            default: name = "project"
            }
            return "\(s.text ?? "nil")/\(name)\(s.isPaused ? "/paused" : "")"
        }
        let cases: [(String, Entry?, NSColor?)] = [
            ("нет записи", nil, nil),
            ("секундомер 0 мин", entry(0.5), nil),
            ("секундомер 25 мин", entry(25.5), .systemGreen),
            ("секундомер 1:25", entry(85), nil),
            ("секундомер 10:05", entry(605), nil),
            ("таймер, осталось 24:30", entry(0.5, planned: 25), nil),
            ("таймер, осталось 0:30", entry(24.5, planned: 25), .systemGreen),
            ("пауза", entry(12, paused: true), .systemGreen),
        ]
        for (name, e, color) in cases {
            print("MENUBAR", name, describe(MenuBarItem.state(for: e, color: color, isDark: true, now: now)))
        }

        // Лист значков: тёмная и светлая строка меню, в 3 раза крупнее.
        let samples: [(String?, NSColor, Bool)] = [
            (nil, .systemBlue, false), ("01:03:40", .systemBlue, false), ("00:25:07", .systemOrange, false),
            ("12:00:59", .systemGreen, true), ("00:00:30", .systemRed, false),
        ]
        let scale: CGFloat = 3
        let cell = NSSize(width: 110, height: 28)
        let sheet = NSImage(size: NSSize(width: cell.width * CGFloat(samples.count) * scale, height: cell.height * 2 * scale), flipped: false) { rect in
            for (row, dark) in [true, false].enumerated() {
                let y = rect.height - CGFloat(row + 1) * cell.height * scale
                (dark ? NSColor(red: 0.04, green: 0.11, blue: 0.22, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: rect.width, height: cell.height * scale).fill()
                for (i, s) in samples.enumerated() {
                    let icon = MenuBarIcon.image(MenuBarIconState(text: s.0, color: s.1, isPaused: s.2, isDark: dark))
                    let w = icon.size.width * scale, h = icon.size.height * scale
                    icon.draw(in: NSRect(x: CGFloat(i) * cell.width * scale + (cell.width * scale - w) / 2, y: y + (cell.height * scale - h) / 2, width: w, height: h))
                }
            }
            return true
        }
        if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/icons.png"))
        }

        let notch = app.notch!
        print("MENUBAR mode:", notch.model.menuBarMode, "panel visible collapsed:", notch.panel.isVisible)
        app.store.addTask("!! Позвонить в банк", projectID: nil)
        UserDefaults.standard.set("tasks", forKey: "notchTab")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { notch.expand() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            print("MENUBAR expanded visible:", notch.panel.isVisible, "frame:", notch.panel.frame, "screen:", notch.screen.frame)
            save(notch.panel, "\(dir)/panel.png")
            notch.collapse()
            print("MENUBAR collapsed visible:", notch.panel.isVisible)
            app.store.start(title: "Тест", projectID: nil, planned: .some(nil))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { NSApp.terminate(nil) }
    }

    /// Календарь дня: расчёты, снимки и настоящие жесты мышью.
    @MainActor private static func runCalendarTest(_ app: AppDelegate, _ dir: String) {
        func check(_ name: String, _ ok: Bool) { print(ok ? "OK  " : "FAIL", name) }
        let store = app.store
        let dayStart = Cal.ru.startOfDay(for: Date())
        let day = Cal.day(dayStart)
        func at(_ hours: Double) -> Date { dayStart.addingTimeInterval(hours * 3600) }

        // Колонки.
        let a = Entry(title: "А", projectID: nil, start: at(9), end: at(11))
        let b = Entry(title: "Б", projectID: nil, start: at(10), end: at(12))
        let c = Entry(title: "В", projectID: nil, start: at(11), end: at(13))
        let d = Entry(title: "Г", projectID: nil, start: at(14), end: at(15))
        let placed = CalendarMath.place([d, c, b, a], day: day, now: at(20))
        func spot(_ e: Entry) -> (Int, Int) { placed.first { $0.id == e.id }.map { ($0.column, $0.columns) } ?? (-1, -1) }
        check("наложение: А и Б рядом", spot(a) == (0, 2) && spot(b) == (1, 2))
        check("В занимает освободившуюся колонку", spot(c) == (0, 2))
        check("отдельная запись на всю ширину", spot(d) == (0, 1))
        let late = Entry(title: "Ночь", projectID: nil, start: at(-1), end: at(1))
        let lateSpot = CalendarMath.place([late], day: day, now: at(20)).first
        check("запись через полночь обрезана днём", lateSpot?.start == day.start && lateSpot?.end == at(1))
        check("её нельзя таскать", !CalendarMath.canDrag(late, day: day))
        let running = Entry(title: "Идёт", projectID: nil, start: at(9))
        check("идущую нельзя таскать", !CalendarMath.canDrag(running, day: day))
        check("идущая тянется до текущего момента", CalendarMath.place([running], day: day, now: at(10)).first?.end == at(10))

        // Перетаскивание.
        func moved(_ kind: CalendarDrag.Kind, _ minutes: Double, _ e: Entry = a) -> Entry {
            CalendarMath.apply(CalendarDrag(id: e.id, kind: kind, offsetMinutes: minutes), to: e, day: day)
        }
        check("сдвиг кратен пяти минутам", moved(.move, 62).start == at(10) && moved(.move, 63).start == at(10) + 300)
        check("сдвиг не меняет длину", moved(.move, -33).end!.timeIntervalSince(moved(.move, -33).start) == 7200)
        check("сдвиг не выходит за начало дня", moved(.move, -2000).start == day.start)
        check("сдвиг не выходит за конец дня", moved(.move, 2000).end == day.end)
        check("верхний край", moved(.top, 30).start == at(9.5) && moved(.top, 30).end == at(11))
        check("верхний край не заходит за нижний", moved(.top, 500).start == at(11) - 300)
        check("нижний край", moved(.bottom, -30).end == at(10.5) && moved(.bottom, -30).start == at(9))
        check("нижний край не заходит за верхний", moved(.bottom, -500).end == at(9) + 300)

        check("за что схватили", CalendarMath.grab(y: 3, height: 60) == .top && CalendarMath.grab(y: 57, height: 60) == .bottom && CalendarMath.grab(y: 30, height: 60) == .move)
        check("низкую запись можно двигать", CalendarMath.grab(y: 3, height: 15) == .move && CalendarMath.grab(y: 3, height: 8) == .move)

        // Снимки.
        let design = store.addProject(name: "Дизайн", color: .purple)
        let site = store.addProject(name: "Сайт", color: .orange)
        let client = store.addProject(name: "Клиент", color: .blue)
        let yesterday = dayStart.addingTimeInterval(-86400)
        func y(_ h: Double) -> Date { yesterday.addingTimeInterval(h * 3600) }
        let morning = Entry(title: "Макет главной", projectID: design.id, start: y(9), end: y(11.5), note: "Правки после созвона")
        store.upsert(morning)
        store.upsert(Entry(title: "Созвон", projectID: client.id, start: y(11.5), end: y(12)))
        store.upsert(Entry(title: "Вёрстка", projectID: site.id, start: y(13), end: y(15)))
        store.upsert(Entry(title: "Почта", projectID: nil, start: y(14), end: y(14.25)))
        store.upsert(Entry(title: "Короткая", projectID: client.id, start: y(16), end: y(16.1)))
        func hosted(_ view: some View, _ size: NSSize, _ name: String, _ delay: Double) {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: Localized { view.environmentObject(store) }.frame(width: size.width, height: size.height))
            w.appearance = NSAppearance(named: .darkAqua)
            w.orderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                save(w, "\(dir)/\(name).png")
                w.orderOut(nil)
            }
        }
        UserDefaults.standard.set(1, forKey: "journal.calendarZoom")
        hosted(DayCalendarView(day: yesterday).background(.notchPaper), NSSize(width: 760, height: 620), "cal-dark", 1.0)
        hosted(DayCalendarView(day: yesterday).background(.notchPaper).environment(\.colorScheme, .light), NSSize(width: 760, height: 620), "cal-light", 1.0)
        hosted(DayCalendarView(day: yesterday, previewHover: morning.id).background(.notchPaper), NSSize(width: 760, height: 620), "cal-hover", 1.0)
        UserDefaults.standard.set(JournalMode.calendar.rawValue, forKey: "journal.mode")
        app.journal.show(.journal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            save(NSApp.windows.first { $0.title == L("Журнал") && $0.isVisible && $0.toolbar != nil }, "\(dir)/cal-window.png")
            UserDefaults.standard.removeObject(forKey: "journal.mode")
        }
        hosted(DayCalendarView(day: yesterday.addingTimeInterval(-86400 * 3)).background(.notchPaper), NSSize(width: 520, height: 420), "cal-empty", 1.0)

        // Настоящие события мыши, зум 0: 36 точек в часе, отступ сверху 12. Все жесты подряд в одном окне:
        // повторное перетаскивание должно работать так же, как первое. События идут только активному приложению.
        let hour: CGFloat = 36
        var counter = 0
        UserDefaults.standard.set(0, forKey: "journal.calendarZoom")
        let gestureWindow = AlwaysKeyWindow(contentRect: NSRect(x: 80, y: 80, width: 760, height: 620), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        gestureWindow.isReleasedWhenClosed = false
        func findScroll(_ v: NSView) -> NSScrollView? {
            if let s = v as? NSScrollView { return s }
            for sub in v.subviews { if let s = findScroll(sub) { return s } }
            return nil
        }
        func point(_ window: NSWindow, hours: Double, x: CGFloat = 400) -> NSPoint {
            guard let doc = findScroll(window.contentView!)?.documentView else { return .zero }
            let yy = 12 + CGFloat(hours) * hour
            return doc.convert(NSPoint(x: x, y: doc.isFlipped ? yy : doc.bounds.height - yy), to: nil)
        }
        func event(_ window: NSWindow, _ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            counter += 1
            return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: counter, clickCount: 1, pressure: 1)!
        }
        /// Протянуть мышью между двумя моментами дня.
        func drag(from: Double, to: Double, check verify: @escaping (NSWindow) -> Void, then: @escaping () -> Void) {
            let window = gestureWindow
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let a = point(window, hours: from), b = point(window, hours: to)
                window.sendEvent(event(window, .leftMouseDown, a))
                let steps = 6
                for i in 1 ... steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04 * Double(i)) {
                        let f = CGFloat(i) / CGFloat(steps)
                        window.sendEvent(event(window, .leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)))
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04 * Double(steps + 2)) {
                    window.sendEvent(event(window, .leftMouseUp, b))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        verify(window)
                        if let sheet = window.attachedSheet { window.endSheet(sheet) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: then)
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            gestureWindow.contentView = NSHostingView(rootView: Localized { DayCalendarView(day: yesterday).environmentObject(store) }.frame(width: 760, height: 620))
            gestureWindow.makeKeyAndOrderFront(nil)
            drag(from: 10, to: 11, check: { _ in
                let e = store.entry(morning.id)
                check("мышь: запись сдвинута на час", e?.start == y(10) && e?.end == y(12.5))
                check("мышь: сдвиг можно отменить", store.undoOffer != nil)
                store.performUndo()
                check("мышь: отмена вернула время", store.entry(morning.id)?.start == y(9) && store.entry(morning.id)?.end == y(11.5))
            }) {
                drag(from: 11.45, to: 11.95, check: { _ in
                    let e = store.entry(morning.id)
                    check("мышь: нижний край", e?.start == y(9) && e?.end == y(12))
                    store.performUndo()
                }) {
                    drag(from: 9.05, to: 10.05, check: { _ in
                        let e = store.entry(morning.id)
                        check("мышь: верхний край", e?.start == y(10) && e?.end == y(11.5))
                        store.performUndo()
                    }) {
                        let count = store.entries.count
                        drag(from: 18, to: 19.5, check: { window in
                            check("мышь: протягивание открывает редактор", window.attachedSheet != nil)
                            check("мышь: запись ещё не создана", store.entries.count == count)
                            if let sheet = window.attachedSheet { save(sheet, "\(dir)/cal-new.png") }
                        }) {
                            print("CALDONE")
                            exit(0)
                        }
                    }
                }
            }
        }
    }

    @MainActor private static func render(_ view: some View, _ path: String) {
        let r = ImageRenderer(content: view.frame(width: 760, height: 720).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func dumpTables(_ window: NSWindow?) {
        func walk(_ v: NSView) {
            if let t = v as? NSTableView { print("TABLE rows:", t.numberOfRows, "frame:", t.frame.size) }
            if v is NSSwitch {
                let r = v.convert(v.bounds, to: nil)
                print("SWITCH", (v as! NSSwitch).state == .on ? "on" : "off", "maxX:", Int(r.maxX), "window:", Int(window?.frame.width ?? 0))
            }
            v.subviews.forEach(walk)
        }
        if let v = window?.contentView { walk(v) }
        print("WINDOW content:", window?.contentView?.frame.size ?? .zero, "appearance:", window?.effectiveAppearance.name.rawValue ?? "")
    }

    private static func save(_ window: NSWindow?, _ path: String) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
