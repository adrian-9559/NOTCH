import Foundation

/// Lógica pura del hover del notch (testeable): con el estado actual,
/// decide si mostrar, ocultar o no hacer nada.
public enum HoverDecision: Sendable, Equatable {
    case show
    case hide
    case none
}

public enum HoverLogic {
    /// - visible: panel abierto o no.
    /// - inNotch/inPanel: ratón dentro de cada zona.
    /// - armed: ya estuvo dentro desde que se abrió (evita cerrar un panel
    ///   abierto por menú cuando el ratón está en otro lado).
    /// - outsideElapsed: segundos fuera de toda zona.
    /// - grace: retardo de cierre para no parpadear.
    public static func decide(visible: Bool, inNotch: Bool, inPanel: Bool, armed: Bool, outsideElapsed: TimeInterval, grace: TimeInterval = 0.45) -> HoverDecision {
        if !visible {
            return inNotch ? .show : .none
        }
        if inPanel || inNotch { return .none }
        if armed && outsideElapsed >= grace { return .hide }
        return .none
    }
}
