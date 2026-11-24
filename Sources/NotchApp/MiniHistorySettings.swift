#if os(macOS)
import NotchCore
import SwiftUI

// MARK: - Historial: qué hizo cada agente, hora a hora. Día y semana.
// (La retención es de 90 días: ver `HistoryStore.retentionDays`, la
// pestaña Actividad calcula tiempos y rachas sobre esa ventana.)

struct HistoryEvent: Codable {
    var ts: Date
    var agent: String
    var status: String
}

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    @Published private(set) var events: [HistoryEvent] = []
    private var lastByAgent: [String: String] = [:]
    /// Estados que cuentan como tiempo activo.
    static let activeStatuses: Set<String> = ["working", "waiting"]
    /// Revisión del conjunto de eventos (invalida las cachés).
    private var rev = 0
    /// Intervalos activos cacheados: el pareo de transiciones se hace
    /// una vez por revisión (antes se rehacía en cada cálculo).
    private var intervalsCache: (rev: Int, list: [(agent: String, start: Date, end: Date?)])?

    private func logFile() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NOTCH")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.jsonl")
    }

    /// Solo registra transiciones (working→waiting→done…), no cada poll.
    func record(_ sessions: [AgentSession]) {
        // Varias instancias del mismo agente: se registra su mejor
        // estado (working > waiting > done > resto) para no escribir
        // transiciones falsas por la instancia quieta.
        func rank(_ s: AgentStatus) -> Int {
            switch s {
            case .working: return 4
            case .waiting: return 3
            case .done: return 2
            default: return 1
            }
        }
        var best: [String: AgentSession] = [:]
        for s in sessions {
            if let b = best[s.agent.rawValue], rank(b.status) >= rank(s.status) { continue }
            best[s.agent.rawValue] = s
        }
        var fresh: [HistoryEvent] = []
        for s in best.values {
            if lastByAgent[s.agent.rawValue] != s.status.rawValue {
                lastByAgent[s.agent.rawValue] = s.status.rawValue
                fresh.append(HistoryEvent(ts: Date(), agent: s.agent.displayName, status: s.status.rawValue))
            }
        }
        guard !fresh.isEmpty else { return }
        events.append(contentsOf: fresh)
        if let h = try? FileHandle(forWritingTo: logFile()) {
            h.seekToEndOfFile()
            for e in fresh {
                if let d = try? JSONEncoder().encode(e) {
                    h.write(d); h.write(Data("\n".utf8))
                }
            }
            try? h.close()
        } else {
            let lines = fresh.compactMap { e -> String? in
                guard let d = try? JSONEncoder().encode(e) else { return nil }
                return String(data: d, encoding: .utf8)
            }.joined(separator: "\n") + "\n"
            try? lines.write(to: logFile(), atomically: true, encoding: .utf8)
        }
        // Ventana en memoria: últimos `retentionDays` (Actividad: mes + rachas).
        let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 86400)
        events = events.filter { $0.ts > cutoff }
        rev += 1
    }

    /// Carga el JSONL. Guardada: solo la primera vez — entrar en
    /// Actividad o Mac releía y re-decodificaba el fichero entero cada
    /// vez (lag al cambiar de pestaña). La primera carga puede llegar
    /// en background desde el arranque.
    func load() {
        guard events.isEmpty else { return }
        guard let data = try? Data(contentsOf: logFile()),
              !data.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 86400)
        let decoded = data.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONDecoder().decode(HistoryEvent.self, from: Data($0)) }
            .filter { $0.ts > cutoff }
        if Thread.isMainThread {
            applyLoad(decoded)
        } else {
            DispatchQueue.main.async { [weak self] in self?.applyLoad(decoded) }
        }
    }

    private func applyLoad(_ decoded: [HistoryEvent]) {
        guard events.isEmpty else { return }
        events = decoded
        rev += 1
        for e in events { lastByAgent[e.agent] = e.status }
    }

    /// Vacía memoria y disco (Ajustes → Borrar datos).
    func reset() {
        events = []
        lastByAgent = [:]
        rev += 1
        try? FileManager.default.removeItem(at: logFile())
    }

    /// Intervalos activos (inicio de working → primer evento que no es
    /// activo), por agente: los agentes trabajan a la vez, así que el
    /// seguimiento es independiente por agente. `end == nil` sigue en
    /// curso. Cacheado por revisión.
    func activeIntervals() -> [(agent: String, start: Date, end: Date?)] {
        if let c = intervalsCache, c.rev == rev { return c.list }
        let sorted = events.sorted { $0.ts < $1.ts }
        var out: [(agent: String, start: Date, end: Date?)] = []
        var starts: [String: Date] = [:]
        for e in sorted {
            if Self.activeStatuses.contains(e.status) {
                if starts[e.agent] == nil { starts[e.agent] = e.ts }
            } else if let s = starts.removeValue(forKey: e.agent) {
                out.append((agent: e.agent, start: s, end: e.ts))
            }
        }
        for (agent, s) in starts {
            out.append((agent: agent, start: s, end: nil))
        }
        intervalsCache = (rev, out)
        return out
    }

    func hours(for day: Date) -> [(hour: Int, count: Int, agents: [String])] {
        let cal = Calendar.current
        let dayEvents = events.filter { cal.isDate($0.ts, inSameDayAs: day) && $0.status != "idle" }
        return (0..<24).map { h in
            let hs = dayEvents.filter { cal.component(.hour, from: $0.ts) == h }
            return (h, hs.count, Array(Set(hs.map(\.agent))))
        }
    }

    /// Actividad por hora rodante (últimas 24 h) para la gráfica del hub.
    /// Pasada única sobre los eventos (antes:24 filtros completos).
    func last24h(now: Date = Date()) -> [Int] {
        var buckets = [Int](repeating: 0, count: 24)
        let hour: TimeInterval = 3600
        for e in events where e.status != "idle" {
            let back = Int(now.timeIntervalSince(e.ts) / hour)
            if back >= 0 && back < 24 { buckets[23 - back] += 1 }
        }
        return buckets
    }
}

// MARK: - Arranque con sesión (LaunchAgent, sin permisos)

/// `~/Library/LaunchAgents/com.notch.app.plist` apuntando al ejecutable.
/// Vale para el binario de desarrollo y para la app empaquetada.
enum LaunchAtLogin {
    static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.notch.app.plist")
    }

    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: plist.path)
    }

    static func set(_ on: Bool) {
        if on {
            let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let dict: [String: Any] = [
                "Label": "com.notch.app",
                "ProgramArguments": [exe],
                "RunAtLoad": true,
            ]
            try? FileManager.default.createDirectory(
                at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            (dict as NSDictionary).write(to: plist, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: plist)
        }
        // Recarga best-effort (si no está cargado, bootout falla y ya).
        let uid = getuid()
        for args in [["bootout", "gui/\(uid)/com.notch.app"],
                     ["bootstrap", "gui/\(uid)", plist.path]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }
}

// MARK: - Ajustes: tabs, auto-send (Accessibility opt-in), Obsidian

struct SettingsView: View {
    @State private var autoSend = ReplyService.shared.autoSendEnabled
    @State private var trustState = ReplyService.shared.isTrusted
    @State private var vaultPath: String = UserDefaults.standard.string(forKey: "notchObsidianVault") ?? ""
    @State private var hoverOpen = UserDefaults.standard.object(forKey: "notchHoverOpen") as? Bool ?? true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ajustes").font(.caption).foregroundStyle(.secondary)
            Toggle("Abrir al pasar el ratón por el notch", isOn: $hoverOpen)
                .font(.callout)
                .toggleStyle(NotchToggleStyle(mini: true))
                .onChange(of: hoverOpen) { v in
                    UserDefaults.standard.set(v, forKey: "notchHoverOpen")
                }
            Toggle("Auto-send en Claude (Accessibility)", isOn: $autoSend)
                .font(.callout)
                .toggleStyle(NotchToggleStyle(mini: true))
                .onChange(of: autoSend) { v in
                    if v && !ReplyService.shared.isTrusted {
                        ReplyService.shared.requestTrust()
                    }
                    ReplyService.shared.autoSendEnabled = v
                    trustState = ReplyService.shared.isTrusted
                }
            Text(trustState ? "Accesibilidad: concedida ✓" : "Accesibilidad: pendiente (solo si activas auto-send)")
                .font(.caption2).foregroundStyle(.secondary)
            TextField("Obsidian vault (dev log)", text: $vaultPath, onCommit: {
                UserDefaults.standard.set(vaultPath, forKey: "notchObsidianVault")
            })
            .textFieldStyle(.roundedBorder).font(.caption)
            Text("Privacidad: todo queda en tu Mac. Sin cuentas, sin tracking, sin Screen Recording.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
    }
}
#endif
