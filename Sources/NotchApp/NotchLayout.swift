#if os(macOS)
import AppKit
import NotchCore

/// Puente AppKit → `NotchLayout` puro usando el API público
/// `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` (macOS 12+).
/// Sin APIs privadas: válido para notarización.
extension NSScreen {
    func notchLayout(menuThickness: CGFloat) -> NotchLayout {
        let l = auxiliaryTopLeftArea ?? .zero, r = auxiliaryTopRightArea ?? .zero
        let lay = NotchLayout.make(
            screenFrame: frame,
            leftArea: l.isEmpty ? nil : l,
            rightArea: r.isEmpty ? nil : r,
            menuThickness: menuThickness
        )
        if lay.hasNotch { return lay }
        return NotchLayout(hasNotch: false, notchRect: .null, leftArea: .zero, rightArea: .zero, menuThickness: menuThickness)
    }
}

/// Un layout por pantalla: el notch físico solo existe en la integrada.
struct ScreenNotch {
    var screen: NSScreen
    var layout: NotchLayout
}

func currentScreenNotches() -> [ScreenNotch] {
    let thickness = NSStatusBar.system.thickness
    return NSScreen.screens.map { ScreenNotch(screen: $0, layout: $0.notchLayout(menuThickness: thickness)) }
}
#endif
