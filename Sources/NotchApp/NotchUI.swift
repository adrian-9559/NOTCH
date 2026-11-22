#if os(macOS)
import AppKit
import Combine
import NotchCore
import SwiftUI
import UserNotifications

/// App mínima: icono en menu bar + ventana notch + polling cada 2s.
/// Shelf / mini-features cuelgan de `sessions` aquí.
final class NotchAppMain: NSObject {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var store = SessionStore()
    private var windowController: NotchWindowController?
    private var lights = NotchLightsController()
    private var aura = NotchAuraController()
    private var toast = MusicToastController()
    private var agentToast = AgentToastController()
    /// Último estado visto por agente: para avisar al terminar.
    private var lastAgentStatus: [AgentID: AgentStatus] = [:]
    /// Cuándo empezó a trabajar (para ignorar parpadeos cortos).
    private var workingSince: [AgentID: Date] = [:]
    /// Generación por agente: un aviso viejo no pisa a uno nuevo.
    private var doneGen: [AgentID: Int] = [:]
    /// Generación de espera: la pregunta solo avisa una vez por episodio.
    private var waitGen: [AgentID: Int] = [:]
    /// Cuándo se avisó el último done: si vuelve a trabajar sin quietud
    /// de por medio es el MISMO request (subagente) → no re-avisar.
    private var lastDoneToast: [AgentID: Date] = [:]
    /// Hubo quietud (idle/crash/desapareció) desde el último done.
    private var quietSinceToast: [AgentID: Bool] = [:]
    /// Cola del aviso de agente: sale cuando ningún otro aviso está fuera.
    private var toastQueueGen = 0
    /// Cola del aviso de espera: igual, con su generación.
    private var waitQueueGen = 0
    private var waitToast = WaitingToastController()
    /// Píldora de recordatorios + planificador.
    private var reminderToast = ReminderToastController()
    private var reminderScheduler = ReminderScheduler()
    private var cancellables = Set<AnyCancellable>()
    private var hover = NotchHoverController()
    /// Poll del bocadillo de navbar (las tracking areas no llegan aquí).
    private var navPoll: Timer?
    /// Atajo global del portapapeles (doble ⌘ derecho).
    private var clipHotKey = ClipHotKey()
    private var notchAnchorX: CGFloat?
    private var notchTopY: CGFloat?
    private var notchWidth: CGFloat?
    private var notchRect: CGRect?
    private var timer: Timer?
    /// Marcas de agentes ya avisadas por la auditoría (dedupe).
    private var unmappedLogged = Set<String>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "● NOTCH"
        buildMenu()
        // El menú sigue al idioma.
        NotchSettings.shared.$langCode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.buildMenu() }
            .store(in: &cancellables)

        NotchContext.shared.store = store
        store.onChange = { [weak self] fresh in
            HistoryStore.shared.record(fresh)
            self?.announceWaiting(fresh)
            self?.announceFinished(fresh)
        }
        // Auditoría: marcas de agentes que ningún detector reclama →
        // stderr una vez cada una (para añadirlas a la tabla).
        store.onSnapshot = { [weak self] snap in
            guard let self else { return }
            for line in ProcessMonitor.unmappedAgents(in: snap)
            where self.unmappedLogged.insert(line).inserted {
                fputs("NOTCH-UNMAPPED \(line)\n", stderr)
            }
        }
        AppFonts.register()
        MiniTabs.register()
        configureScreens()
        rebuildWindow()
        installOfficeHotKey()
        installHover()
        installNavHover()
        installClipboard()
        installReminders()

        // Precargas fuera del hilo principal: el historial (JSONL) y el
        // clima con ciudad guardada. Así entrar en Actividad, Mac o el
        // notch no espera lecturas de disco (lag al cambiar de pestaña).
        DispatchQueue.global(qos: .utility).async { HistoryStore.shared.load() }
        WeatherStore.shared.silentRefresh()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
        refreshNow()
        // Tocar una notificación del sistema abre el panel en Tareas.
        // (Solo empaquetada: sin bundle revienta, ver ReminderSystem.)
        if ReminderSystem.available {
            UNUserNotificationCenter.current().delegate = self
        }

        // Depuración/atajos de lanzamiento: --settings abre el modal de
        // ajustes al arrancar (útil para capturas y para usuarios).
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.openSettings()
            }
        }
    }

    private func rebuildWindow() {
        let root = NotchRootView(
            store: store,
            extraTabs: Self.extraTabs(),
            notchWidth: notchWidth,
            onAllow: { [weak self] s in self?.allow(session: s) },
            onReply: { [weak self] s, text in self?.reply(session: s, text: text) },
            onOpen: { [weak self] s in self?.open(session: s) }
        )
        windowController = NotchWindowController(content: root)
    }

    /// Los lotes 2-5 registran aquí sus vistas sin tocar NotchRootView.
    /// ExtraTabsProvider se define en archivos posteriores (todos compilan juntos).
    static func extraTabs() -> [(title: String, view: AnyView)] {
        ExtraTabsProvider.tabs()
    }

    @objc private func toggleNotch() {
        if windowController?.isVisible == true {
            hidePanel()
        } else {
            hover.disarm()
            showPanel()
        }
    }

    private func showPanel() {
        toast.hide()
        agentToast.hide()
        waitToast.hide()
        reminderToast.hide()
        lights.setPanelOpen(true)
        windowController?.show(anchorX: notchAnchorX, topY: notchTopY)
    }

    /// Avisa con píldora (como la de música) cuando un agente termina
    /// DE VERDAD. Endurecido contra subagentes: el done debe durar 45 s
    /// y, si ya se avisó sin quietud de por medio (mismo request),
    /// se suprime en vez de spamear.
    private func announceFinished(_ fresh: [AgentSession]) {
        let present = Set(fresh.map(\.agent))
        // Quietud o desaparición = fin del request: el próximo done avisa.
        for a in lastAgentStatus.keys where !present.contains(a) {
            quietSinceToast[a] = true
            lastAgentStatus.removeValue(forKey: a)
        }
        for s in fresh {
            let prev = lastAgentStatus[s.agent]
            lastAgentStatus[s.agent] = s.status
            if s.status == .working || s.status == .waiting {
                if prev != .working, prev != .waiting {
                    workingSince[s.agent] = Date()
                }
                continue
            }
            if s.status == .idle || s.status == .crashed {
                quietSinceToast[s.agent] = true
                continue
            }
            let worked = Date().timeIntervalSince(workingSince[s.agent] ?? Date())
            guard EpisodeJudge.shouldStartDoneClock(prev: prev, current: s.status, worked: worked) else { continue }
            if lastDoneToast[s.agent] != nil, quietSinceToast[s.agent] != true {
                fputs("NOTCH-EPISODE agent=\(s.agent.rawValue) done-suppressed (mismo request)\n", stderr)
                continue
            }
            doneGen[s.agent, default: 0] += 1
            let gen = doneGen[s.agent]!
            DispatchQueue.main.asyncAfter(deadline: .now() + EpisodeJudge.donePersistence) { [weak self] in
                guard let self,
                      self.doneGen[s.agent] == gen,
                      self.lastAgentStatus[s.agent] == .done else { return }
                self.lastDoneToast[s.agent] = Date()
                self.quietSinceToast[s.agent] = false
                fputs("NOTCH-EPISODE agent=\(s.agent.rawValue) done-toast\n", stderr)
                self.requestAgentToast(s)
            }
        }
    }

    /// Avisa con píldora clicable cuando un agente PREGUNTA algo: una vez
    /// por episodio (entrar en waiting), si la pregunta persiste 5 s.
    private func announceWaiting(_ fresh: [AgentSession]) {
        for s in fresh where EpisodeJudge.shouldStartWaitClock(prev: lastAgentStatus[s.agent], current: s.status) {
            waitGen[s.agent, default: 0] += 1
            let gen = waitGen[s.agent]!
            DispatchQueue.main.asyncAfter(deadline: .now() + EpisodeJudge.waitPersistence) { [weak self] in
                guard let self,
                      self.waitGen[s.agent] == gen,
                      self.lastAgentStatus[s.agent] == .waiting else { return }
                fputs("NOTCH-EPISODE agent=\(s.agent.rawValue) wait-toast\n", stderr)
                self.requestWaitToast(s)
            }
        }
    }

    /// Cola: el aviso de agente espera a que no haya otro aviso fuera
    /// (el de música dura 4.5 s, el de agente 5 s): salen uno detrás de otro.
    private func requestAgentToast(_ s: AgentSession) {
        toastQueueGen += 1
        pumpAgentToast(s, gen: toastQueueGen, attempt: 0)
    }

    private func pumpAgentToast(_ s: AgentSession, gen: Int, attempt: Int) {
        guard gen == toastQueueGen, attempt < 12 else { return }
        if toast.state.visible || agentToast.state.visible || waitToast.state.visible || reminderToast.state.visible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.pumpAgentToast(s, gen: gen, attempt: attempt + 1)
            }
            return
        }
        agentToast.show(session: s)
    }

    /// Cola del aviso de espera: igual que la de fin, con su generación.
    private func requestWaitToast(_ s: AgentSession) {
        waitQueueGen += 1
        pumpWaitToast(s, gen: waitQueueGen, attempt: 0)
    }

    private func pumpWaitToast(_ s: AgentSession, gen: Int, attempt: Int) {
        guard gen == waitQueueGen, attempt < 12 else { return }
        if toast.state.visible || agentToast.state.visible || waitToast.state.visible || reminderToast.state.visible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.pumpWaitToast(s, gen: gen, attempt: attempt + 1)
            }
            return
        }
        waitToast.show(session: s)
    }

    private func hidePanel() {
        lights.setPanelOpen(false)
        windowController?.hide()
    }

    @objc private func refreshNow() {
        store.refresh()
        let n = store.active.count
        statusItem.button?.title = n > 0 ? tr("menu.statusOn", n) : tr("menu.statusOff")
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    // MARK: - Acciones (lote reply-in-notch las enriquece)

    private func allow(session: AgentSession) {
        ReplyService.shared.allow(session: session)
    }

    private func reply(session: AgentSession, text: String) {
        guard !text.isEmpty else { return }
        ReplyService.shared.reply(session: session, text: text)
    }

    private func open(session: AgentSession) {
        ReplyService.shared.open(session: session)
    }

    // MARK: - Integración 100% notch (físico o nada)

    /// Recalcula ancla + pestaña + luces para las pantallas actuales.
    @objc private func screensChanged() {
        configureScreens()
        rebuildWindow()
    }

    private func configureScreens() {
        let notches = currentScreenNotches()
        let main = notches.first(where: { $0.screen == NSScreen.main }) ?? notches.first
        if let m = main, m.layout.hasNotch {
            let n = m.layout.notchRect
            notchRect = n
            notchAnchorX = n.midX
            // 8px por debajo del filo.
            notchTopY = m.screen.frame.maxY - 8
            notchWidth = n.width
        } else {
            notchRect = nil
            notchAnchorX = nil
            notchTopY = nil
            notchWidth = nil
        }
        lights.rebuild(notches: notches) { [weak self] in
            self?.toggleNotch()
        }
        // El aura va detrás: se ordena primero y el panel queda delante.
        aura.rebuild(notches: notches)
        // El aviso de canción nueva sale del notch si el panel no está abierto.
        toast.isPanelVisible = { [weak self] in self?.windowController?.isVisible == true }
        toast.rebuild(notches: notches)
        agentToast.isPanelVisible = { [weak self] in self?.windowController?.isVisible == true }
        agentToast.rebuild(notches: notches)
        // La espera entra en la misma cola; al pulsarla se abre el panel
        // en el apartado Agentes, con la pregunta expandida.
        waitToast.isPanelVisible = { [weak self] in self?.windowController?.isVisible == true }
        waitToast.rebuild(notches: notches)
        waitToast.onTap = { [weak self] in
            self?.waitToast.hide()
            self?.hover.disarm()
            self?.showPanel()
            NotificationCenter.default.post(name: .notchShowAgents, object: nil)
        }
        // El recordatorio abre el panel en Tareas.
        reminderToast.isPanelVisible = { [weak self] in self?.windowController?.isVisible == true }
        reminderToast.rebuild(notches: notches)
        reminderToast.onTap = { [weak self] in
            self?.reminderToast.hide()
            self?.hover.disarm()
            self?.showPanel()
            NotificationCenter.default.post(name: .notchShowTasks, object: nil)
        }
        // Mientras sale el aviso de canción, la píldora se quita y vuelve al irse.
        toast.state.$visible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.lights.setToastShowing($0) }
            .store(in: &cancellables)
        // La música espera si algún aviso está fuera (y viceversa).
        toast.isBlocked = { [weak self] in
            self?.agentToast.state.visible == true
                || self?.waitToast.state.visible == true
                || self?.reminderToast.state.visible == true
        }
    }

    // MARK: - Hover: abrir al subir el ratón, cerrar al sacarlo

    private func installHover() {
        hover.zoneProvider = { [weak self] in
            // La zona incluye la píldora de música (más ancha que el
            // notch): pasar por la carátula o el EQ también abre.
            var nz = self?.notchRect
            for pill in self?.lights.visiblePillFrames ?? [] {
                nz = nz?.union(pill) ?? pill
            }
            return (notch: nz,
                    panel: self?.windowController?.isVisible == true ? self?.windowController?.frame : nil,
                    visible: self?.windowController?.isVisible ?? false)
        }
        hover.onEnter = { [weak self] in self?.showPanel() }
        hover.onLeave = { [weak self] in self?.hidePanel() }
        hover.start()
    }

    /// Bocadillo de navbar por polling (A): hit-test del ratón contra
    /// los frames de las píldoras (coords de pantalla, como el ratón).
    private func installNavHover() {
        navPoll?.invalidate()
        navPoll = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self else { return }
            let store = NotchContext.shared.navHover
            guard let win = self.windowController, win.isVisible else {
                if store.tab != nil { store.tab = nil }
                return
            }
            let m = NSEvent.mouseLocation
            var hit: String?
            if let win = self.windowController, win.isVisible {
                // Frames SwiftUI (origen: esq. sup-izq del VStack, que
                // coincide con la ventana) → coords de pantalla.
                let f = win.frame
                for (id, r) in store.frames {
                    let pill = NSRect(x: f.minX + r.minX, y: f.maxY - r.maxY,
                                      width: r.width, height: r.height)
                    if pill.insetBy(dx: -4, dy: -6).contains(m) { hit = id; break }
                }
            }
            if store.tab != hit {
                store.tab = hit
            }
        }
    }

    /// Portapapeles: vigila en memoria + atajo global Win+V.
    private func installClipboard() {
        NotchContext.shared.clips.start()
        clipHotKey.onFire = { [weak self] in
            guard NotchSettings.shared.clipHotkeyEnabled else { return }
            self?.toggleClipboard()
        }
        clipHotKey.start()
    }

    private func toggleClipboard() {
        ClipPopupCenter.shared.toggle(store: NotchContext.shared.clips)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier.hasPrefix("notch-reminder-") {
            hover.disarm()
            showPanel()
            NotificationCenter.default.post(name: .notchShowTasks, object: nil)
        }
        completionHandler()
    }

    // MARK: - Recordatorios de tareas (píldora + sistema por evento)

    private func installReminders() {
        // Carga ya (la pestaña carga perezosa y el planificador no la abre).
        NotchContext.shared.tasks.load()
        reminderScheduler.start(tasks: NotchContext.shared.tasks) { [weak self] due in
            self?.fireReminders(due)
        }
    }

    private func fireReminders(_ due: [AgentTask]) {
        guard NotchSettings.shared.remindersEnabled else { return }
        let panelOpen = windowController?.isVisible == true
        var notified: [UUID] = []
        for t in due {
            // Con el panel abierto ya ves las tareas: sin píldora (pero el
            // sistema sí suena) y no se marca hasta avisar de verdad.
            let pill = (t.notifyMode == .pill || t.notifyMode == .both) && !panelOpen
            let system = t.notifyMode == .system || t.notifyMode == .both
            if pill {
                reminderToast.show(title: t.title, subtitle: ReminderText.subtitle(for: t))
                notified.append(t.id)
            }
            if system && ReminderSystem.available {
                ReminderSystem.send(t)
                if !notified.contains(t.id) { notified.append(t.id) }
            }
            if pill || system {
                fputs("NOTCH-EPISODE reminder task=\(t.title.prefix(40)) mode=\(t.notifyMode.rawValue)\n", stderr)
            }
        }
        // pill-only con panel abierto: reintenta en 30 s (no se marca).
        NotchContext.shared.tasks.markReminded(notified)
    }

    /// Menú del icono (se reconstruye al cambiar el idioma).
    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: tr("menu.open"), action: #selector(toggleNotch), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: tr("menu.settings"), action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: tr("menu.refresh"), action: #selector(refreshNow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: tr("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        installMenuHoverToggle()
        installOfficeHotKeyHint()
    }

    private func installMenuHoverToggle() {
        let item = NSMenuItem(
            title: tr("menu.hover"),
            action: #selector(toggleHover),
            keyEquivalent: ""
        )
        item.state = hover.isEnabled ? .on : .off
        item.tag = 99
        statusItem.menu?.insertItem(item, at: 0)
    }

    private func installOfficeHotKeyHint() {
        if OfficeHotKey.shared.isAvailable {
            let item = NSMenuItem(title: tr("menu.hotkey"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            statusItem.menu?.insertItem(item, at: 0)
        }
    }

    @objc private func toggleHover(_ sender: NSMenuItem) {
        hover.isEnabled.toggle()
        sender.state = hover.isEnabled ? .on : .off
    }

    // MARK: - Notch: doble-tap de ⌘ derecha (con fallback al menú si no hay permiso)

    private func installOfficeHotKey() {
        OfficeHotKey.shared.onDoubleTap = { [weak self] in
            self?.toggleNotch()
        }
        OfficeHotKey.shared.install()
    }
}

/// Punto de extensión para los siguientes lotes. Si ningún lote lo
/// implementa, el notch muestra solo estado + avisos.
enum ExtraTabsProvider {
    static var makeTabs: (() -> [(title: String, view: AnyView)])?
    static func tabs() -> [(title: String, view: AnyView)] { makeTabs?() ?? [] }
}
#endif
