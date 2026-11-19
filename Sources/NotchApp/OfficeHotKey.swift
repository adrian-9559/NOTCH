#if os(macOS)
import AppKit

/// Doble-tap de ⌘ derecha para abrir la oficina.
/// Requiere permiso de Accesibilidad para el monitor global;
/// sin él, `isAvailable` es false y se usa el menú.
final class OfficeHotKey {
    static let shared = OfficeHotKey()
    var onDoubleTap: (() -> Void)?
    private(set) var isAvailable = false
    private var lastTap: Date?
    private var monitor: Any?

    func install() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return }
            // 0x100000 == ⌘ derecha en keyCode 54/55; filtramos por flags.
            let isCmd = event.modifierFlags.contains(.command)
            if isCmd {
                let now = Date()
                if let last = self.lastTap, now.timeIntervalSince(last) < 0.4 {
                    self.lastTap = nil
                    self.onDoubleTap?()
                } else {
                    self.lastTap = now
                }
            }
        }
        isAvailable = monitor != nil
    }
}
#endif
