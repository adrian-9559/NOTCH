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

    private func logFile() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NOTCH")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.jsonl")
    }

    /// Solo registra transiciones (working→waiting→done…), no cada poll.
    func record(_ sessions: [AgentSession]) {
        var fresh: [HistoryEvent] = []
        for s in sessions {
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
    }

    func load() {
        guard let data = try? Data(contentsOf: logFile()),
              !data.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 86400)
        events = data.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONDecoder().decode(HistoryEvent.self, from: Data($0)) }
            .filter { $0.ts > cutoff }
        for e in events { lastByAgent[e.agent] = e.status }
    }

    /// Vacía memoria y disco (Ajustes → Borrar datos).
    func reset() {
        events = []
        lastByAgent = [:]
        try? FileManager.default.removeItem(at: logFile())
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
    func last24h(now: Date = Date()) -> [Int] {
        (0..<24).map { back in
            let start = now.addingTimeInterval(-Double(back + 1) * 3600)
            let end = now.addingTimeInterval(-Double(back) * 3600)
            return events.filter { $0.ts >= start && $0.ts < end && $0.status != "idle" }.count
        }.reversed()
    }
}

struct HistoryView: View {
    @ObservedObject var store = HistoryStore.shared
    @ObservedObject private var settings = NotchSettings.shared
    @State private var dayOffset = 0 // 0 hoy, -1 ayer… -6 semana

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(dayOffset == 0 ? tr("hist.today") : dayName).font(.notchMono(11)).foregroundStyle(.secondary)
                Spacer()
                Button("‹") { dayOffset = max(-6, dayOffset - 1) }.buttonStyle(NotchGhostButton(size: .small))
                Button("›") { dayOffset = min(0, dayOffset + 1) }.buttonStyle(NotchGhostButton(size: .small))
            }
            let rows = store.hours(for: day)
            if rows.allSatisfy({ $0.count == 0 }) {
                Text(tr("hist.empty")).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rows.filter { $0.count > 0 }, id: \.hour) { r in
                    HStack(spacing: 6) {
                        Text(String(format: "%02d", r.hour)).font(.caption2).monospacedDigit().frame(width: 22)
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2)).frame(height: 10)
                            RoundedRectangle(cornerRadius: 3).fill(Color.accentColor)
                                .frame(width: max(8, CGFloat(min(r.count, 12)) * 12), height: 10)
                        }
                        .frame(width: 150)
                        Text(r.agents.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(8)
        .onAppear { store.load() }
    }

    private var day: Date {
        Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
    }

    private var dayName: String {
        let f = DateFormatter(); f.dateStyle = .medium
        return f.string(from: day)
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
