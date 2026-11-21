#if os(macOS)
import AppKit
import NotchCore
import SwiftUI

/// App mínima: icono en menu bar + ventana notch + polling cada 2s.
/// Office pixel-art / shelf / mini-features cuelgan de `sessions` aquí.
final class NotchAppMain: NSObject {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var store = SessionStore()
    private var windowController: NotchWindowController?
    private var lights = NotchLightsController()
    private var aura = NotchAuraController()
    private var hover = NotchHoverController()
    private var notchAnchorX: CGFloat?
    private var notchTopY: CGFloat?
    private var notchWidth: CGFloat?
    private var notchRect: CGRect?
    private var timer: Timer?
    private var officeVisible = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "● NOTCH"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Abrir notch", action: #selector(toggleNotch), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Ajustes…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Ver agentes ahora", action: #selector(refreshNow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        NotchContext.shared.store = store
        store.onChange = { HistoryStore.shared.record($0) }
        AppFonts.register()
        MiniTabs.register()
        configureScreens()
        rebuildWindow()
        installOfficeHotKey()
        installHover()
        installMenuHoverToggle()

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
        windowController?.show(anchorX: notchAnchorX, topY: notchTopY)
    }

    private func hidePanel() {
        windowController?.hide()
    }

    @objc private func refreshNow() {
        store.refresh()
        let n = store.active.count
        statusItem.button?.title = n > 0 ? "● NOTCH (\(n))" : "○ NOTCH"
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
        lights.rebuild(notches: notches, store: store) { [weak self] in
            self?.toggleNotch()
        }
        // El aura va detrás: se ordena primero y el panel queda delante.
        aura.rebuild(notches: notches)
    }

    // MARK: - Hover: abrir al subir el ratón, cerrar al sacarlo

    private func installHover() {
        hover.zoneProvider = { [weak self] in
            (notch: self?.notchRect,
             panel: self?.windowController?.isVisible == true ? self?.windowController?.frame : nil,
             visible: self?.windowController?.isVisible ?? false)
        }
        hover.onEnter = { [weak self] in self?.showPanel() }
        hover.onLeave = { [weak self] in self?.hidePanel() }
        hover.start()
    }

    private func installMenuHoverToggle() {
        let item = NSMenuItem(
            title: "Abrir al pasar el ratón",
            action: #selector(toggleHover),
            keyEquivalent: ""
        )
        item.state = hover.isEnabled ? .on : .off
        item.tag = 99
        statusItem.menu?.insertItem(item, at: 0)
    }

    @objc private func toggleHover(_ sender: NSMenuItem) {
        hover.isEnabled.toggle()
        sender.state = hover.isEnabled ? .on : .off
    }

    // MARK: - Office: doble-tap de ⌘ derecha (con fallback al menú si no hay permiso)

    private func installOfficeHotKey() {
        OfficeHotKey.shared.onDoubleTap = {
            OfficeWindowController.shared.show()
        }
        OfficeHotKey.shared.install()
        if OfficeHotKey.shared.isAvailable {
            let item = NSMenuItem(title: "Office: doble-tap ⌘ der. (activo)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            statusItem.menu?.insertItem(item, at: 0)
        }
    }
}

/// Punto de extensión para los siguientes lotes. Si ningún lote lo
/// implementa, el notch muestra solo estado + avisos.
enum ExtraTabsProvider {
    static var makeTabs: (() -> [(title: String, view: AnyView)])?
    static func tabs() -> [(title: String, view: AnyView)] { makeTabs?() ?? [] }
}
#endif
