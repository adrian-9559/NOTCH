import CoreGraphics
import Foundation

/// Geometría del notch, pura y testeable (sin AppKit).
/// El puente con `NSScreen.auxiliaryTopLeftArea/RightArea` vive en NotchApp.
public struct NotchLayout: Sendable, Equatable {
    public var hasNotch: Bool
    public var notchRect: CGRect
    public var leftArea: CGRect
    public var rightArea: CGRect
    public var menuThickness: CGFloat

    public init(hasNotch: Bool, notchRect: CGRect, leftArea: CGRect, rightArea: CGRect, menuThickness: CGFloat) {
        self.hasNotch = hasNotch; self.notchRect = notchRect
        self.leftArea = leftArea; self.rightArea = rightArea
        self.menuThickness = menuThickness
    }

    /// El notch físico vive entre ambas áreas auxiliares, en la franja superior.
    /// Coordenadas de pantalla (origen abajo-izquierda, como `NSScreen.frame`).
    public static func make(screenFrame: CGRect, leftArea: CGRect?, rightArea: CGRect?, menuThickness: CGFloat) -> NotchLayout {
        let empty = NotchLayout(hasNotch: false, notchRect: .null, leftArea: .zero, rightArea: .zero, menuThickness: menuThickness)
        guard let l = leftArea, let r = rightArea,
              !l.isNull, !r.isNull, l.width > 1, r.width > 1 else { return empty }
        let nw = r.minX - l.maxX
        guard nw > 1 else { return empty }
        let notch = CGRect(x: l.maxX, y: min(l.minY, r.minY), width: nw, height: max(l.height, r.height))
        return NotchLayout(hasNotch: true, notchRect: notch, leftArea: l, rightArea: r, menuThickness: menuThickness)
    }

    /// Notch virtual estándar para Macs sin notch físico.
    public static func virtualNotch(screenFrame: CGRect, menuThickness: CGFloat) -> CGRect {
        let w: CGFloat = 180, h = min(menuThickness + 6, 32)
        return CGRect(x: screenFrame.midX - w / 2, y: screenFrame.maxY - h, width: w, height: h)
    }
}
