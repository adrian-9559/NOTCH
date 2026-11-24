#if os(macOS)
import AppKit

/// Escucha los BANNERS de notificación de WhatsApp y Telegram usando
/// la API PÚBLICA de Accesibilidad (AXObserver + kAXWindowCreated),
/// el MISMO permiso que NOTCH ya pide para el autoenvío. No usa
/// APIs privadas del Centro de notificaciones: la notarización no
/// se rompe y todo es local.
///
/// Cada ventana de aviso nueva se lee (emisor + texto) y se lanza
/// la píldora en el notch vía `onMessage`. Las ventanas grandes
/// (ventana principal, diálogos anchos) se ignoran por tamaño.
final class MsgSniffer {
    static let shared = MsgSniffer()

    struct Target {
        let bundle: String
        let name: String
        let tint: String
        let icon: String
    }

    private let targets: [Target] = [
        Target(bundle: "net.whatsapp.WhatsApp", name: "WhatsApp",
               tint: "25D366", icon: "bubble.left.fill"),
        Target(bundle: "ru.keepcoder.Telegram", name: "Telegram",
               tint: "2AABEE", icon: "paperplane.fill"),
    ]

    /// (app, tinte, icono, texto)
    var onMessage: ((String, String, String, String) -> Void)?

    private var observers: [pid_t: AXObserver] = [:]
    private var attached = Set<pid_t>()
    private var seen = Set<String>()
    private var retryTimer: Timer?
    private var started = false

    /// Arranca (o reintenta hasta que haya permiso de Accesibilidad).
    func start() {
        if ProcessInfo.processInfo.environment["NOTCH_SNIFF_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.onMessage?("WhatsApp", "25D366", "bubble.left.fill",
                                 "Prueba de píldora: mensaje de bienvenida")
            }
        }
        guard AXIsProcessTrusted() else {
            fputs("NOTCH-SNIFF sin permiso de Accesibilidad; se reintentará\n", stderr)
            scheduleRetry()
            return
        }
        guard !started else { return }
        started = true
        for t in targets { attachIfRunning(t) }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        fputs("NOTCH-SNIFF listo (WhatsApp/Telegram)\n", stderr)
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard AXIsProcessTrusted() else { return }
            self?.retryTimer?.invalidate()
            self?.retryTimer = nil
            self?.start()
        }
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        for t in targets where app.bundleIdentifier == t.bundle {
            attachIfRunning(t)
        }
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        detach(pid: app.processIdentifier)
    }

    private func attachIfRunning(_ t: Target) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: t.bundle).first else { return }
        attach(pid: app.processIdentifier, target: t)
    }

    private func attach(pid: pid_t, target: Target) {
        guard !attached.contains(pid) else { return }
        var observer: AXObserver?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = AXObserverCreate(pid, { _, element, _, refcon in
            guard let refcon else { return }
            let sniffer = Unmanaged<MsgSniffer>.fromOpaque(refcon).takeUnretainedValue()
            sniffer.windowCreated(element)
        }, &observer)
        guard result == .success, let obs = observer else {
            fputs("NOTCH-SNIFF AXObserverCreate falló pid=\(pid) r=\(result.rawValue)\n", stderr)
            return
        }
        let appEl = AXUIElementCreateApplication(pid)
        let add = AXObserverAddNotification(obs, appEl, kAXWindowCreatedNotification as CFString, refcon)
        guard add == .success else {
            fputs("NOTCH-SNIFF addNotification falló pid=\(pid) r=\(add.rawValue)\n", stderr)
            return
        }
        // El observer necesita un runloop en el hilo principal.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observers[pid] = obs
        attached.insert(pid)
        fputs("NOTCH-SNIFF adjunto \(target.name) pid=\(pid)\n", stderr)
    }

    private func detach(pid: pid_t) {
        guard let obs = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        attached.remove(pid)
        fputs("NOTCH-SNIFF separado pid=\(pid)\n", stderr)
    }

    /// Nueva ventana en la app observada: si parece un banner (pequeño
    /// y con texto), se emite el mensaje (con antirrepetición).
    private func windowCreated(_ element: AXUIElement) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            var wins: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &wins)
            guard let arr = wins as? [AXUIElement] else { return }
            for w in arr {
                var sizeVal: CFTypeRef?
                AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeVal)
                var size = CGSize.zero
                if let sizeVal { AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) }
                // Banner: ancho moderado y bajo. La ventana principal
                // (mucho mayor) y los diálogos anchos se descartan.
                guard size.width > 180, size.width < 560, size.height > 30, size.height < 170 else { continue }
                let texts = Self.texts(of: w)
                guard !texts.isEmpty else { continue }
                let joined = texts.joined(separator: " · ")
                guard !seen.contains(joined) else { continue }
                seen.insert(joined)
                guard let target = self.target(for: element) else { continue }
                fputs("NOTCH-SNIFF banner \(target.name): \(joined.prefix(160))\n", stderr)
                DispatchQueue.main.async {
                    self.onMessage?(target.name, target.tint, target.icon, joined)
                }
            }
        }
    }

    /// App dueña de ese elemento AX (por pid).
    private func target(for element: AXUIElement) -> Target? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundle = app.bundleIdentifier else { return nil }
        return targets.first { $0.bundle == bundle }
    }

    private static func texts(of element: AXUIElement) -> [String] {
        var out: [String] = []
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 8 else { return }
            var role: CFTypeRef?, value: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            if role as? String == "AXStaticText" {
                AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value)
                if let s = value as? String {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { out.append(t) }
                }
            }
            var list: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &list)
            if let arr = list as? [AXUIElement] { for c in arr { walk(c, depth: depth + 1) } }
        }
        walk(element, depth: 0)
        return out
    }
}
#endif
