#if os(macOS)
import CoreText
import SwiftUI

/// La tipografía de Lumio: Departure Mono (OFL, Helena Zhang),
/// empaquetada en Resources con su licencia.
enum AppFonts {
    static let monoName = "Departure Mono"

    static func register() {
        guard let url = Bundle.module.url(forResource: "DepartureMono-Regular", withExtension: "otf") else {
            return
        }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

extension Font {
    /// Mono de NOTCH/Lumio. Si la fuente falta, cae a mono del sistema.
    static func notchMono(_ size: CGFloat) -> Font {
        .custom(AppFonts.monoName, size: size)
    }
}
#endif
