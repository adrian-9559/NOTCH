#if os(macOS)
import NotchCore
import SwiftUI

// MARK: - Actividad: tiempo por agente (día/semana/mes) + rachas.
// Todo sale del historial local de transiciones: se empareja cada inicio
// working/waiting con el siguiente evento del mismo agente. Sin permisos.

extension HistoryStore {
    /// Ventana en memoria y en disco (días, configurable en Ajustes).
    static var retentionDays: Double {
        UserDefaults.standard.object(forKey: "notchHistoryDays") as? Double ?? 90
    }
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
        let days = secondsPerDay(last: Int(Self.retentionDays), now: now)
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
        let days = secondsPerDay(last: Int(Self.retentionDays), now: now).reversed()
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
        VStack(alignment: .leading, spacing: 10) {
            // Selector de rango propio.
            NotchSegments(
                selection: $range,
                options: [(0, tr("act.day")), (1, tr("act.week")), (2, tr("act.month"))],
                color: settings.accent
            )
            .frame(maxWidth: 260)

            let rows = store.activeSecondsPerAgent(since: since)
            let total = rows.reduce(0.0) { $0 + $1.seconds }

            // Cabecera: total grande + racha.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(formatActive(total))
                        .font(.notchMono(30))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                    Text(range == 0 ? tr("act.today") : range == 1 ? tr("act.days7") : tr("act.days30"))
                        .font(.notchMono(10))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text("\(store.currentStreak())")
                            .font(.notchMono(18))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                    }
                    Text(tr("act.best", store.bestStreak()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(actCard)

            if rows.isEmpty {
                Text(tr("act.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            } else {
                // Clasificación por agente con barra proporcional.
                let top = max(rows[0].seconds, 1)
                VStack(spacing: 0) {
                    ForEach(Array(rows.prefix(8).enumerated()), id: \.element.agent) { i, r in
                        HStack(spacing: 8) {
                            Text(verbatim: "\(i + 1)")
                                .font(.notchMono(10))
                                .foregroundStyle(Color.white.opacity(0.35))
                                .frame(width: 12, alignment: .trailing)
                                .monospacedDigit()
                            Circle()
                                .fill(agentColor(for: r.agent, default: settings.accent))
                                .frame(width: 8, height: 8)
                            Text(r.agent)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                            Spacer()
                            Text(formatActive(r.seconds))
                                .font(.notchMono(11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 6)
                        .background(
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(agentColor(for: r.agent, default: settings.accent).opacity(0.16))
                                        .frame(width: geo.size.width * CGFloat(r.seconds / top), height: 3)
                                }
                                .frame(maxHeight: .infinity, alignment: .bottom)
                                .offset(y: 8)
                            }
                        )
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(actCard)
            }

            // Semana: 7 columnas con letra del día.
            let week = store.secondsPerDay(last: 7)
            if week.contains(where: { $0.seconds > 0 }) {
                let peak = max(week.map(\.seconds).max() ?? 1, 1)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(week.indices.reversed(), id: \.self) { i in
                            let v = week[i].seconds
                            let isToday = Calendar.current.isDateInToday(week[i].day)
                            VStack(spacing: 3) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(isToday ? settings.accent : settings.accent.opacity(v > 0 ? 0.55 : 0.15))
                                    .frame(width: 18, height: max(5, 40 * CGFloat(v / peak)))
                                Text(dayLetter(week[i].day))
                                    .font(.notchMono(8))
                                    .foregroundStyle(isToday ? settings.accent : Color.white.opacity(0.4))
                            }
                            .frame(maxWidth: .infinity)
                            .help("\(dayLabel(week[i].day)): \(formatActive(v))")
                        }
                    }
                    if let best = week.max(by: { $0.seconds < $1.seconds }), best.seconds > 0 {
                        Text(tr("act.bestDay", dayLabel(best.day), formatActive(best.seconds)))
                            .font(.notchMono(9))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(actCard)
            }
        }
        .padding(8)
        .onAppear { store.load() }
    }

    private var actCard: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    private func dayLetter(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = .current; f.dateFormat = "EEEEE"
        return f.string(from: d)
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return tr("act.today") }
        if cal.isDateInYesterday(d) { return tr("act.yesterday") }
        let f = DateFormatter(); f.locale = .current; f.dateFormat = "EEE"
        return f.string(from: d)
    }
}
#endif
