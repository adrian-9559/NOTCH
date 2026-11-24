#if os(macOS)
import AppKit
import Foundation
import NotchCore

/// Apertura al pasar el ratón por el notch, cierre al sacarlo.
/// Sin permisos: usa `NSEvent.mouseLocation` por polling (barato, 8 Hz).
/// Con histéresis: 2 polls seguidos para abrir, 0.45 s de gracia para cerrar,
/// y no cierra un panel abierto por menú hasta entrar en él una vez.
final class NotchHoverController {
    var onEnter: (() -> Void)?
    var onLeave: (() -> Void)?

    /// Zonas actuales: notch expandido, frame del panel (si visible), visibilidad.
    var zoneProvider: (() -> (notch: CGRect?, panel: CGRect?, visible: Bool))?

    private var timer: Timer?
    private var enterStreak = 0
    private var outsideElapsed: TimeInterval = 0
    private var armed = false
    private let interval: TimeInterval = 0.12
    private let openKey = "notchHoverOpen"

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: openKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: openKey) }
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Llamar cuando el panel se abre por otra vía (menú/luz): no cerrar
    /// hasta que el ratón entre una vez.
    func disarm() { armed = false; outsideElapsed = 0; enterStreak = 0 }

    private func poll() {
        guard isEnabled, let z = zoneProvider?() else { return }
        let mouse = NSEvent.mouseLocation
        let inNotch = z.notch?.insetBy(dx: -8, dy: -4).contains(mouse) ?? false
        let inPanel = z.panel.map { $0.insetBy(dx: -4, dy: -4).contains(mouse) } ?? false

        if !z.visible {
            armed = false; outsideElapsed = 0
            if inNotch {
                enterStreak += 1
                if enterStreak >= 2 {
                    enterStreak = 0
                    armed = true
                    onEnter?()
                }
            } else {
                enterStreak = 0
            }
            return
        }
        if inPanel || inNotch {
            armed = true
            outsideElapsed = 0
            return
        }
        // Fuera de todo.
        if armed {
            outsideElapsed += interval
            if HoverLogic.decide(visible: true, inNotch: false, inPanel: false, armed: armed, outsideElapsed: outsideElapsed) == .hide {
                armed = false
                outsideElapsed = 0
                onLeave?()
            }
        }
    }
}
#endif
