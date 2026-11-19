#if os(macOS)
import NotchCore
import SwiftUI

// MARK: - Historial: qué hizo cada agente, hora a hora. Día y semana.

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
        // Ventana en memoria: última semana.
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        events = events.filter { $0.ts > weekAgo }
    }

    func load() {
        guard let data = try? Data(contentsOf: logFile()),
              !data.isEmpty else { return }
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        events = data.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONDecoder().decode(HistoryEvent.self, from: Data($0)) }
            .filter { $0.ts > weekAgo }
        for e in events { lastByAgent[e.agent] = e.status }
    }

    func hours(for day: Date) -> [(hour: Int, count: Int, agents: [String])] {
        let cal = Calendar.current
        let dayEvents = events.filter { cal.isDate($0.ts, inSameDayAs: day) && $0.status != "idle" }
        return (0..<24).map { h in
            let hs = dayEvents.filter { cal.component(.hour, from: $0.ts) == h }
            return (h, hs.count, Array(Set(hs.map(\.agent))))
        }
    }
}

struct HistoryView: View {
    @ObservedObject var store = HistoryStore.shared
    @State private var dayOffset = 0 // 0 hoy, -1 ayer… -6 semana

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(dayOffset == 0 ? "hoy" : dayName).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("‹") { dayOffset = max(-6, dayOffset - 1) }.controlSize(.small)
                Button("›") { dayOffset = min(0, dayOffset + 1) }.controlSize(.small)
            }
            .buttonStyle(.bordered)
            let rows = store.hours(for: day)
            if rows.allSatisfy({ $0.count == 0 }) {
                Text("Sin actividad registrada").font(.caption).foregroundStyle(.secondary)
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
                .onChange(of: hoverOpen) { v in
                    UserDefaults.standard.set(v, forKey: "notchHoverOpen")
                }
            Toggle("Auto-send en Claude (Accessibility)", isOn: $autoSend)
                .font(.callout)
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
