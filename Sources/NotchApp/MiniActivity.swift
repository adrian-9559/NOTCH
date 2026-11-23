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
    /// Mínimo diario para que el día cuente en la racha.
    private static let streakMinimum: TimeInterval = 60

    /// Segundos activos por agente en [since, now], de más a menos.
    /// Recorta los intervalos cacheados (sin re-parear eventos por render).
    func activeSecondsPerAgent(since: Date, now: Date = Date()) -> [(agent: String, seconds: TimeInterval)] {
        var out: [String: TimeInterval] = [:]
        for iv in activeIntervals() {
            let a = max(iv.start, since)
            let b = min(iv.end ?? now, now)
            if b > a { out[iv.agent, default: 0] += b.timeIntervalSince(a) }
        }
        return out.map { (agent: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }
    }

    func activeSecondsTotal(since: Date, now: Date = Date()) -> TimeInterval {
        var total: TimeInterval = 0
        for iv in activeIntervals() {
            let a = max(iv.start, since)
            let b = min(iv.end ?? now, now)
            if b > a { total += b.timeIntervalSince(a) }
        }
        return total
    }

    /// Segundos activos por día (día → segundos), los últimos `days`
    /// días. Reparte los intervalos cacheados por día: una sola pasada
    /// (antes: `days` filtros + agrupaciones sobre TODOS los eventos).
    func secondsPerDay(last days: Int, now: Date = Date()) -> [(day: Date, seconds: TimeInterval)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var buckets: [Date: TimeInterval] = [:]
        for iv in activeIntervals() {
            let end = min(iv.end ?? now, now)
            var cursor = cal.startOfDay(for: iv.start)
            while cursor <= end {
                let dayEnd = cal.date(byAdding: .day, value: 1, to: cursor) ?? now
                let segStart = max(iv.start, cursor)
                let segEnd = min(end, dayEnd)
                if segEnd > segStart {
                    buckets[cursor, default: 0] += segEnd.timeIntervalSince(segStart)
                }
                cursor = dayEnd
            }
        }
        return (0..<days).map { i in
            let d = cal.date(byAdding: .day, value: -i, to: today) ?? today
            return (d, buckets[d] ?? 0)
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

    /// Rango real: hoy, la semana natural (según locale) y el mes
    /// natural — no una ventana rodante de7/30 días.
    private var since: Date {
        let cal = Calendar.current
        switch range {
        case 0:
            return cal.startOfDay(for: Date())
        case 1:
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
            return cal.date(from: comps) ?? cal.startOfDay(for: Date())
        default:
            let comps = cal.dateComponents([.year, .month], from: Date())
            return cal.date(from: comps) ?? cal.startOfDay(for: Date())
        }
    }

    /// Días transcurridos del periodo (para la media diaria).
    private var daysInPeriod: Int {
        let diff = Calendar.current.dateComponents([.day], from: since, to: Date()).day ?? 0
        return max(1, diff + 1)
    }

    private var periodLabel: String {
        switch range {
        case 0: return tr("act.today")
        case 1: return tr("act.thisWeek")
        default: return tr("act.thisMonth")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Solo uso real: mínimo60 s en el periodo. Detecciones
            // accidentales de segundos no aparecen (ni su tiempo en el
            // total). Si no has usado nada, se muestra el vacío.
            let rows = store.activeSecondsPerAgent(since: since).filter { $0.seconds >= 60 }
            let total = rows.reduce(0.0) { $0 + $1.seconds }

            // Primero la cabecera con la media; el selector, debajo.
            heroCard(total: total)
            // Selector en tarjeta, como el resto de componentes, con los
            // tres segmentos repartidos a todo el ancho.
            NotchCard {
                NotchSegments(
                    selection: $range,
                    options: [(0, tr("act.day")), (1, tr("act.week")), (2, tr("act.month"))],
                    color: settings.accent,
                    fill: true
                )
            }

            if rows.isEmpty {
                emptyState
            } else {
                rankingCard(rows: rows)
            }
            heatmapCard
        }
        .padding(8)
        .onAppear { store.load() }
    }

    // MARK: - Cabecera: total + racha

    private func heroCard(total: TimeInterval) -> some View {
        NotchCard(accent: settings.accent) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("act.total"))
                        .font(.notchMono(9))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .kerning(1.4)
                    Text(formatActive(total))
                        .font(.notchMono(34))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                    // Periodo + media diaria (arriba, como se pidió).
                    HStack(spacing: 5) {
                        Text(periodLabel)
                            .font(.notchMono(10))
                            .foregroundStyle(Color.white.opacity(0.42))
                        if total > 0 && daysInPeriod > 1 {
                            Text("·")
                                .font(.notchMono(10))
                                .foregroundStyle(Color.white.opacity(0.28))
                            Text("\(tr("act.avg")) \(formatActive(total / Double(daysInPeriod)))")
                                .font(.notchMono(10))
                                .foregroundStyle(settings.accent.opacity(0.95))
                                .monospacedDigit()
                        }
                    }
                }
                Spacer()
                // Racha como ficha: llama + número + mejor.
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.orange)
                            .shadow(color: .orange.opacity(0.5), radius: 6)
                        Text("\(store.currentStreak())")
                            .font(.notchMono(22))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                    }
                    Text(tr("act.best", store.bestStreak()))
                        .font(.notchMono(9))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.black.opacity(0.25))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.orange.opacity(0.25), lineWidth: 1)
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle().fill(Color.white.opacity(0.06)).frame(width: 40, height: 40)
                Image(systemName: "chart.bar")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            Text(tr("act.empty"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 16)
    }

    // MARK: - Clasificación con relleno proporcional

    private func rankingCard(rows: [(agent: String, seconds: TimeInterval)]) -> some View {
        let top = max(rows[0].seconds, 1)
        return NotchCard {
            // Contenido en UNA vista (ver NotchCard): si fueran hijos
            // sueltos del @ViewBuilder, la tarjeta se partiría.
            VStack(alignment: .leading, spacing: 8) {
                NotchTag(icon: "chart.bar.fill", text: tr("act.ranking"), color: settings.accent)
                    .padding(.bottom, 2)
                VStack(spacing: 3) {
                ForEach(Array(rows.prefix(8).enumerated()), id: \.element.agent) { i, r in
                    HStack(spacing: 9) {
                        rankBadge(i)
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
                            .foregroundStyle(.white.opacity(0.75))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 6).padding(.horizontal, 8)
                    .background(
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.white.opacity(0.03))
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(agentColor(for: r.agent, default: settings.accent).opacity(0.16))
                                    .frame(width: max(10, geo.size.width * CGFloat(r.seconds / top)))
                            }
                        }
                    )
                }
            }
        }
        }
    }

    /// Puesto: medalla en los tres primeros, número discreto después.
    private func rankBadge(_ i: Int) -> some View {
        let medal = [Color(hex: "F2B33D"), Color(hex: "C9CED6"), Color(hex: "D98A4E")]
        return Text(verbatim: "\(i + 1)")
            .font(.notchMono(10))
            .foregroundStyle(i < 3 ? Color.black.opacity(0.75) : Color.white.opacity(0.4))
            .monospacedDigit()
            .frame(width: 18, height: 18)
            .background(
                Circle().fill(i < 3 ? medal[i] : Color.white.opacity(0.07))
            )
            .overlay(
                Circle().stroke(i < 3 ? Color.white.opacity(0.25) : Color.clear, lineWidth: 1)
            )
    }

    // MARK: - Heatmap (GitHub): 12 semanas × 7 días, domingo primero.

    private var heatmapCard: some View {
        let heat = heatColumns()
        let hasData = heat.flatMap { $0 }.contains { $0.seconds > 0 }
        return NotchCard {
            // Una sola vista (ver NotchCard): tag + rejilla juntos.
            VStack(alignment: .leading, spacing: 8) {
                // Cabecera: rótulo a la izquierda, leyenda a la derecha.
                HStack(spacing: 8) {
                    NotchTag(icon: "square.grid.3x3.fill", text: tr("act.heat"), color: settings.accent)
                    HStack(spacing: 3) {
                        Text(tr("act.less"))
                            .font(.notchMono(8)).foregroundStyle(Color.white.opacity(0.4))
                        ForEach(0..<5, id: \.self) { b in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(b == 0 ? Color.white.opacity(0.08) : settings.accent.opacity([0.25, 0.45, 0.7, 1.0][b - 1]))
                                .frame(width: 9, height: 9)
                        }
                        Text(tr("act.more"))
                            .font(.notchMono(8)).foregroundStyle(Color.white.opacity(0.4))
                    }
                }
                if hasData {
                    let peak = max(heat.flatMap { $0 }.map(\.seconds).max() ?? 1, 1)
                    // Filas domingo primero: Lun/Mié/Vie en 1/3/5.
                    let wd = Calendar.current.veryShortWeekdaySymbols
                    HStack(alignment: .top, spacing: 4) {
                        // Columna de días (L X V) alineada con las celdas.
                        VStack(spacing: 3) {
                            // Ancho fijo: un Color.clear flexible se comería el espacio.
                            Color.clear.frame(width: 14, height: 12)
                            ForEach(0..<7, id: \.self) { r in
                                Text(r == 1 || r == 3 || r == 5 ? String(wd[r].prefix(1)) : " ")
                                    .font(.notchMono(7))
                                    .foregroundStyle(Color.white.opacity(0.35))
                                    .frame(height: 18)
                            }
                        }
                        ForEach(heat.indices, id: \.self) { c in
                            VStack(spacing: 3) {
                                Text(monthMark(heat, c))
                                    .font(.notchMono(7))
                                    .foregroundStyle(Color.white.opacity(0.4))
                                    .frame(height: 12)
                                VStack(spacing: 3) {
                                    ForEach(heat[c].indices, id: \.self) { r in
                                        let cell = heat[c][r]
                                        if let d = cell.day {
                                            let isToday = Calendar.current.isDateInToday(d)
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(heatColor(cell.seconds, peak: peak))
                                                .frame(width: 18, height: 18)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 4)
                                                        .stroke(
                                                            isToday ? Color.white.opacity(0.75)
                                                                : Color.white.opacity(cell.seconds > 0 ? 0 : 0.05),
                                                            lineWidth: isToday ? 1.4 : 1
                                                        )
                                                )
                                                .help("\(dayLabel(d)): \(formatActive(cell.seconds))")
                                        } else {
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(Color.clear)
                                                .frame(width: 18, height: 18)
                                        }
                                    }
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    if let best = weekBest() {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(settings.accent.opacity(0.9))
                            Text(tr("act.bestDay", dayLabel(best.day), formatActive(best.seconds)))
                                .font(.notchMono(9))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.top, 2)
                    }
                } else {
                    Text(tr("act.empty"))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                }
            }
        }
    }


    private typealias HeatCell = (day: Date?, seconds: TimeInterval)

    private func heatColumns(days: Int = 84) -> [[HeatCell]] {
        let ordered = store.secondsPerDay(last: days).reversed() // viejo → nuevo
        guard let first = ordered.first else { return [] }
        let cal = Calendar.current
        let lead = (cal.component(.weekday, from: first.day) - 1 + 7) % 7
        var cells: [HeatCell] = Array(repeating: (nil, 0), count: lead)
        // Uso real: <60 s en el día = sin celda.
        cells += ordered.map { ($0.day, $0.seconds >= 60 ? $0.seconds : 0) }
        while cells.count % 7 != 0 { cells.append((nil, 0)) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
    }

    private func heatColor(_ v: TimeInterval, peak: TimeInterval) -> Color {
        guard v > 0, peak > 0 else { return Color.white.opacity(0.08) }
        let t = v / peak
        let bucket = min(4, max(1, Int(ceil(t * 4))))
        return settings.accent.opacity([0.25, 0.45, 0.7, 1.0][bucket - 1])
    }

    private func monthMark(_ heat: [[HeatCell]], _ col: Int) -> String {
        let days = heat[col].compactMap(\.day)
        guard let d = days.first else { return " " }
        let label = NotchDateFmt.monthShort.string(from: d)
        if col == 0 { return label }
        let prevDays = heat[col - 1].compactMap(\.day)
        guard let p = prevDays.first else { return label }
        return NotchDateFmt.monthShort.string(from: p) == label ? " " : label
    }

    private func weekBest() -> (day: Date, seconds: TimeInterval)? {
        let week = store.secondsPerDay(last: 7)
        guard let best = week.max(by: { $0.seconds < $1.seconds }), best.seconds > 0 else { return nil }
        return best
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return tr("act.today") }
        if cal.isDateInYesterday(d) { return tr("act.yesterday") }
        return NotchDateFmt.dayShort.string(from: d)
    }
}
#endif
