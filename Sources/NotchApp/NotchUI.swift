#if os(macOS)
import AppKit
import NotchCore

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
    private var engine = MonitorEngine()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "● NOTCH"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Ver agentes ahora", action: #selector(refreshNow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
        refreshNow()
    }

    @objc private func refreshNow() {
        let sessions = engine.poll()
        let active = sessions.filter { $0.status == .working || $0.status == .waiting }.count
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.title = active > 0 ? "● NOTCH (\(active))" : "○ NOTCH"
        }
        // TODO: NotchWindow (NSPanel screenSaver level) + PixelOfficeView + ShelfDrop + MiniFeatures.
        // El motor ya expone sessions; la UI solo observa este punto.
    }
}
#endif
