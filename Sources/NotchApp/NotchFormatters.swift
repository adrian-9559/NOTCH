#if os(macOS)
import Foundation

/// Formateadores de fecha cacheados. Crear un `DateFormatter` en cada
/// render (heatmap, filas de tareas, relojes del hub) era caro: se
/// crean una vez y se reutilizan. Uso solo en el hilo principal.
enum NotchDateFmt {
    private static func make(_ pattern: String, tz: TimeZone? = nil) -> DateFormatter {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = pattern
        if let tz { f.timeZone = tz }
        return f
    }

    static let monthShort = make("MMM")
    static let monthLong = make("LLLL")
    static let dayShort = make("EEE")
    static let weekdayFull = make("EEEE")
    static let hourMinute = make("HH:mm")
    static let hourH = make("HH'h'")
    static let hourOnly = make("H")
    /// Reloj del parte de tiempo: el valor ya lleva el desfase (GMT).
    static let hourMinuteGMT = make("HH:mm", tz: TimeZone(secondsFromGMT: 0))

    static let dayMedium: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static let dayShortStyle: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    static let dayShortTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
#endif
