#if os(macOS)
import SwiftUI

/// Preferencias persistidas de NOTCH (todo local, sin cuentas).
/// AppDelegate observa `NotchSettings.shared` y reconstruye el panel
/// al cambiar, para que colores/pestañas se apliquen al instante.
final class NotchSettings: ObservableObject {
    static let shared = NotchSettings()

    static let defaultAccent = "A550A7"
    /// Pestañas que la navbar puede mostrar (orden por defecto).
    static let tabTitles = ["Shelf", "Focus", "Mac", "Actividad", "Música", "Notas"]

    /// Color de acento en hex (#RRGGBB).
    @Published var accentHex: String {
        didSet { save() }
    }
    /// Opacidad del negro del panel (0.55 translúcido … 0.95 casi sólido).
    @Published var panelOpacity: Double {
        didSet { save() }
    }
    /// Orden de las pestañas en la navbar.
    @Published var tabOrder: [String] {
        didSet { save() }
    }
    /// Pestañas desactivadas (ocultas de la navbar).
    @Published var hiddenTabs: [String] {
        didSet { save() }
    }
    /// Píldora al cambiar de canción (aviso estilo Lumio).
    @Published var songToastEnabled: Bool {
        didSet { save() }
    }
    /// Píldora al terminar un agente.
    @Published var agentToastEnabled: Bool {
        didSet { save() }
    }

    private init() {
        let d = UserDefaults.standard
        var hex = d.string(forKey: "notchAccentHex") ?? Self.defaultAccent
        if hex.hasPrefix("#") { hex.removeFirst() }
        accentHex = hex
        panelOpacity = d.object(forKey: "notchPanelOpacity") as? Double ?? 0.82
        // Normaliza: solo títulos conocidos, sin duplicados; los que falten
        // (títulos nuevos de una versión posterior) se añaden al final.
        var order = (d.stringArray(forKey: "notchTabOrder") ?? [])
            .filter { Self.tabTitles.contains($0) }
        var seen = Set<String>()
        order = order.filter { seen.insert($0).inserted }
        for t in Self.tabTitles where !order.contains(t) {
            order.append(t)
        }
        tabOrder = order
        hiddenTabs = (d.stringArray(forKey: "notchHiddenTabs") ?? [])
            .filter { Self.tabTitles.contains($0) }
        songToastEnabled = d.object(forKey: "notchSongToast") as? Bool ?? true
        agentToastEnabled = d.object(forKey: "notchAgentToast") as? Bool ?? true
        // Diagnóstico: qué leyó al arrancar (dominio UserDefaults = NotchApp).
        fputs("NOTCH-SETTINGS accent=\(accentHex) opacity=\(panelOpacity) hidden=\(hiddenTabs) order=\(tabOrder)\n", stderr)
    }

    var accent: Color { Color(hex: accentHex) }

    /// Títulos visibles en la navbar, en su orden.
    var visibleOrder: [String] {
        tabOrder.filter { !hiddenTabs.contains($0) }
    }

    /// Muestra/oculta una pestaña (siempre deja al menos una visible).
    func setVisible(_ title: String, _ visible: Bool) {
        if visible {
            hiddenTabs.removeAll { $0 == title }
        } else {
            guard visibleOrder.count > 1, !hiddenTabs.contains(title) else { return }
            hiddenTabs.append(title)
        }
    }

    /// Mueve una pestaña arriba/abajo en el orden de la navbar.
    func move(_ title: String, by delta: Int) {
        guard let i = tabOrder.firstIndex(of: title) else { return }
        let j = i + delta
        guard tabOrder.indices.contains(j) else { return }
        tabOrder.swapAt(i, j)
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(accentHex, forKey: "notchAccentHex")
        d.set(panelOpacity, forKey: "notchPanelOpacity")
        d.set(tabOrder, forKey: "notchTabOrder")
        d.set(hiddenTabs, forKey: "notchHiddenTabs")
        d.set(songToastEnabled, forKey: "notchSongToast")
        d.set(agentToastEnabled, forKey: "notchAgentToast")
    }
}
#endif
