#if os(macOS)
import NotchCore
import SwiftUI

// MARK: - Actividad: tiempo por agente (día/semana/mes) + rachas.
// Todo sale del historial local de transiciones: se empareja cada inicio
// working/waiting con el siguiente evento del mismo agente. Sin permisos.

extension HistoryStore {
    /// Ventana en memoria y en disco: 90 días (antes 7).
    static let retentionDays = 90
    /// Estados que cuentan como tiempo activo (como SessionStore.active).
    private static let activeStatuses: Set<String> = ["working", "waiting"]
    /// Mínimo diario para que el día cuente en la racha.
    private static let streakMinimum: TimeInterval = 60

    /// Segundos activos por agente en [since, now], de más a menos.
    func activeSecondsPerAgent(since: Date, now: Date = Date()) -> [(agent: String, seconds: TimeInterval)] {
        var out: [String: TimeInterval] = [:]
        let scoped = events.filter { $0.ts >= since && $0.ts <= now }
        for (agent, evs) in Dictionary(grouping: scoped, by: \.agent) {
            var start: Date?
            for e in evs.sorted(by: { $0.ts < $1.ts }) {
                if Self.activeStatuses.contains(e.status) {
                    if start == nil { start = e.ts }
                } else if let s = start {
                    out[agent, default: 0] += max(0, e.ts.timeIntervalSince(max(s, since)))
                    start = nil
                }
            }
            // Sigue activo ahora: cuenta hasta `now`.
            if let s = start { out[agent, default: 0] += max(0, now.timeIntervalSince(max(s, since))) }
        }
        return out.map { (agent: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }
    }

    func activeSecondsTotal(since: Date, now: Date = Date()) -> TimeInterval {
        activeSecondsPerAgent(since: since, now: now).reduce(0) { $0 + $1.seconds }
    }

    /// Segundos activos por día (día → segundos), los últimos `days` días.
    func secondsPerDay(last days: Int, now: Date = Date()) -> [(day: Date, seconds: TimeInterval)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        return (0..<days).map { i in
            let d = cal.date(byAdding: .day, value: -i, to: today) ?? today
            let end = cal.date(byAdding: .day, value: 1, to: d) ?? now
            return (d, activeSecondsTotal(since: d, now: min(end, now)))
        }
    }

    /// Racha actual: días seguidos con actividad (si hoy aún no llega al
    /// mínimo, se cuenta desde ayer para no romperla a primera hora).
    func currentStreak(now: Date = Date()) -> Int {
        let days = secondsPerDay(last: Self.retentionDays, now: now)
        var start = 0
        if !days.isEmpty, days[0].seconds < Self.streakMinimum { start = 1 }
        var streak = 0
        for d in days.dropFirst(start) {
            guard d.seconds >= Self.streakMinimum else { break }
            streak += 1
        }
        return streak
    }

    /// Mejor racha en la ventana guardada.
    func bestStreak(now: Date = Date()) -> Int {
        let days = secondsPerDay(last: Self.retentionDays, now: now).reversed()
        var best = 0, run = 0
        for d in days {
            if d.seconds >= Self.streakMinimum { run += 1; best = max(best, run) }
            else { run = 0 }
        }
        return best
    }
}

/// Color del agente por su nombre visible (el historial guarda displayName).
func agentColor(for displayName: String, default accent: Color) -> Color {
    guard let id = AgentID.allCases.first(where: { $0.displayName == displayName }) else { return accent }
    // El negro de OpenCode no se ve sobre el vidrio oscuro.
    if id == .opencode { return Color.white.opacity(0.85) }
    return Color(hex: id.notchColorHex)
}

func formatActive(_ s: TimeInterval) -> String {
    let m = Int(s) / 60, h = m / 60
    if h > 0 { return "\(h)h \(m % 60)m" }
    if m > 0 { return "\(m)m" }
    if Int(s) > 0 { return "\(Int(s))s" }
    return "—"
}

struct ActivityView: View {
    @ObservedObject var store = HistoryStore.shared
    @ObservedObject private var settings = NotchSettings.shared
    @State private var range = 1 // 0 día · 1 semana · 2 mes

    private var since: Date {
        let cal = Calendar.current
        switch range {
        case 0: return cal.startOfDay(for: Date())
        case 2: return cal.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        default: return cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $range) {
                Text("Día").tag(0)
                Text("Semana").tag(1)
                Text("Mes").tag(2)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            let rows = store.activeSecondsPerAgent(since: since)
            let total = rows.reduce(0.0) { $0 + $1.seconds }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(formatActive(total))
                    .font(.notchMono(22))
                    .foregroundStyle(.white)
                Text(range == 0 ? "hoy" : range == 1 ? "7 días" : "30 días")
                    .font(.notchMono(11))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("racha \(store.currentStreak())d")
                        .font(.notchMono(11))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .help("Días seguidos con actividad (mejor: \(store.bestStreak())d)")
            }

            if rows.isEmpty {
                Text("Sin actividad en este periodo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let top = max(rows[0].seconds, 1)
                ForEach(rows.prefix(8), id: \.agent) { r in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(agentColor(for: r.agent, default: settings.accent))
                            .frame(width: 7, height: 7)
                        Text(r.agent)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                        Spacer()
                        Text(formatActive(r.seconds))
                            .font(.notchMono(10))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .overlay(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(agentColor(for: r.agent, default: settings.accent).opacity(0.7))
                            .frame(width: 120 * CGFloat(r.seconds / top), height: 3)
                            .offset(y: 4)
                    }
                    .padding(.bottom, 4)
                }
            }

            // Últimos 7 días: minibarras para ver el ritmo de un vistazo.
            let week = store.secondsPerDay(last: 7)
            if week.contains(where: { $0.seconds > 0 }) {
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(week.indices.reversed(), id: \.self) { i in
                        let v = week[i].seconds
                        let peak = max(week.map(\.seconds).max() ?? 1, 1)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(settings.accent.opacity(v > 0 ? 0.85 : 0.2))
                            .frame(width: 14, height: max(4, 34 * CGFloat(v / peak)))
                            .help("\(dayLabel(week[i].day)): \(formatActive(v))")
                    }
                    Spacer()
                    if let best = week.max(by: { $0.seconds < $1.seconds }), best.seconds > 0 {
                        Text("mejor \(dayLabel(best.day)) · \(formatActive(best.seconds))")
                            .font(.notchMono(9))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(8)
        .onAppear { store.load() }
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "hoy" }
        if cal.isDateInYesterday(d) { return "ayer" }
        let f = DateFormatter(); f.locale = .current; f.dateFormat = "EEE"
        return f.string(from: d)
    }
}
#endif
