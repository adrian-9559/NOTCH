#if os(macOS)
import AppKit
import Foundation
import NotchCore
import SwiftUI

// MARK: - Tareas para agentes (estilo Notion, A1: modelo + store)
// Cola de peticiones con estado, prioridad, agente destino y persistencia
// local (tasks.json). El envío a agentes llega en A3; la UI en A2.

enum TaskStatus: String, Codable, CaseIterable {
    case todo
    case doing
    case done
    case archived
}

enum TaskPriority: Int, Codable, CaseIterable {
    case low = 0
    case normal = 1
    case high = 2
}

/// Cómo avisa un recordatorio (configurable por evento).
enum TaskNotify: String, Codable, CaseIterable {
    case pill
    case system
    case both
    case none
}

struct AgentTask: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var detail: String = ""
    var priority: TaskPriority = .normal
    var status: TaskStatus = .todo
    var createdAt: Date = Date()
    var doneAt: Date?
    /// Vencimiento (calendario) y aviso (recordatorio), personales.
    var dueAt: Date?
    var remindAt: Date?
    var notifyMode: TaskNotify = .both
    /// Ya avisado (no repetir, ni tras reiniciar).
    var remindedAt: Date?

    var isOpen: Bool { status == .todo || status == .doing }

    // Decodificación tolerante: los ficheros viejos no traen las claves
    // nuevas (dueAt…) y las desconocidas (agentRaw…) se ignoran.
    enum CodingKeys: String, CodingKey {
        case id, title, detail, priority, status, createdAt, doneAt
        case dueAt, remindAt, notifyMode, remindedAt
    }

    init(title: String, detail: String = "", priority: TaskPriority = .normal,
         dueAt: Date? = nil, remindAt: Date? = nil, notifyMode: TaskNotify = .both) {
        self.title = title
        self.detail = detail
        self.priority = priority
        self.dueAt = dueAt
        self.remindAt = remindAt
        self.notifyMode = notifyMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        priority = try c.decodeIfPresent(TaskPriority.self, forKey: .priority) ?? .normal
        status = try c.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .todo
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
        dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        remindAt = try c.decodeIfPresent(Date.self, forKey: .remindAt)
        notifyMode = try c.decodeIfPresent(TaskNotify.self, forKey: .notifyMode) ?? .both
        remindedAt = try c.decodeIfPresent(Date.self, forKey: .remindedAt)
    }
}

final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [AgentTask] = []

    private func tasksFile() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NOTCH")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tasks.json")
    }

    // MARK: - persistencia

    func load() {
        guard let data = try? Data(contentsOf: tasksFile()) else { return }
        do {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .secondsSince1970
            tasks = try dec.decode([AgentTask].self, from: data)
        } catch {
            fputs("NOTCH-DBG tasks-decode-error: \(error)\n", stderr)
        }
    }

    private func save() {
        guard let data = try? configuredEncoder().encode(tasks) else { return }
        try? data.write(to: tasksFile(), options: .atomic)
    }

    private func configuredEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        return enc
    }

    // MARK: - mutaciones (todas persisten)

    @discardableResult
    func add(title: String, detail: String = "",
             priority: TaskPriority = .normal,
             dueAt: Date? = nil, remindAt: Date? = nil,
             notifyMode: TaskNotify = .both) -> AgentTask? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let task = AgentTask(title: t, detail: detail, priority: priority,
                             dueAt: dueAt, remindAt: remindAt, notifyMode: notifyMode)
        tasks.insert(task, at: 0)
        save()
        return task
    }

    func remove(_ task: AgentTask) {
        tasks.removeAll { $0.id == task.id }
        save()
    }

    func update(_ task: AgentTask) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[i] = task
        save()
    }

    func setStatus(_ task: AgentTask, _ status: TaskStatus) {
        var t = task
        t.status = status
        if status == .done, t.doneAt == nil { t.doneAt = Date() }
        if status != .done { t.doneAt = nil }
        update(t)
    }

    /// Sustituye la lista completa (reorden global). Uso interno de la UI.
    func replaceAll(_ tasks: [AgentTask]) {
        self.tasks = tasks
        save()
    }

    /// Vacía todo (Ajustes → Borrar datos).
    func clearAll() {
        tasks = []
        save()
    }

    /// Reordena dentro de una lista filtrada (mapea a índices globales).
    /// Los no filtrados conservan su sitio; los filtrados toman el nuevo orden.
    func move(in filtered: [AgentTask], from source: IndexSet, to dest: Int) {
        var ids = filtered.map(\.id)
        ids.move(fromOffsets: source, toOffset: dest)
        let inFilter = Set(ids)
        let byId = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var out: [AgentTask] = []
        var j = 0
        for t in tasks {
            if inFilter.contains(t.id), j < ids.count, let nt = byId[ids[j]] {
                out.append(nt); j += 1
            } else if !inFilter.contains(t.id) {
                out.append(t)
            }
        }
        // Por si algún id filtrado ya no estaba en tasks.
        while j < ids.count {
            if let nt = byId[ids[j]], !out.contains(where: { $0.id == nt.id }) { out.append(nt) }
            j += 1
        }
        tasks = out
        save()
    }

    // MARK: - consultas

    /// Tareas cuyo aviso toca (recordatorio vencido, modo con aviso,
    /// aún no avisadas). Puro para programar y testear.
    func dueReminders(now: Date = Date()) -> [AgentTask] {
        tasks.filter { t in
            guard t.isOpen, t.notifyMode != .none, t.remindedAt == nil,
                  let r = t.remindAt, r <= now else { return false }
            return true
        }
    }

    /// Marca avisadas (persiste: no repite ni tras reiniciar).
    func markReminded(_ ids: [UUID]) {
        var changed = false
        for i in tasks.indices where ids.contains(tasks[i].id) && tasks[i].remindedAt == nil {
            tasks[i].remindedAt = Date()
            changed = true
        }
        if changed { save() }
    }

    var openCount: Int { tasks.filter(\.isOpen).count }

    var doneToday: Int {
        let day = Calendar.current.startOfDay(for: Date())
        return tasks.filter { ($0.doneAt ?? .distantPast) >= day }.count
    }
}

// MARK: - Vista: cola personal con calendario y recordatorios

/// Pestaña Tareas personales: calendario con recordatorios, añadido
/// rápido (Hoy/Mañana) y secciones por estado. Sin agentes.
struct TasksView: View {
    @ObservedObject var tasks: TaskStore
    @ObservedObject private var settings = NotchSettings.shared
    @State private var showAdd = false
    @State private var title = ""
    @State private var detail = ""
    @State private var priority: TaskPriority = .normal
    @State private var quickDue: QuickDue = .none
    @State private var expanded: UUID? = nil
    @State private var showArchived = false
    @State private var monthOffset = 0
    @State private var selectedDay: Date? = nil
    @State private var hoveredDay: Date? = nil

    enum QuickDue {
        case none, today, tomorrow
    }

    private var shown: [AgentTask] {
        let cal = Calendar.current
        return tasks.tasks.filter { t in
            guard let day = selectedDay else { return true }
            guard let due = t.dueAt else { return false }
            return cal.isDate(due, inSameDayAs: day)
        }
    }

    private func inStatus(_ st: TaskStatus) -> [AgentTask] {
        shown.filter { $0.status == st }
    }

    /// Cabecera de sección con chip de icono (mismo lenguaje que
    /// NotchTag en el resto del panel).
    private func sectionHeader(_ title: String, icon: String, count: Int, color: Color) -> some View {
        NotchTag(icon: icon, text: title, color: color, trailing: "\(count)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Cabecera: chip + título + abiertas + hoy + añadir rápido.
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(settings.accent.opacity(0.16))
                        .frame(width: 18, height: 18)
                    Image(systemName: "checklist")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(settings.accent)
                }
                Text(tr("task.title"))
                    .font(.notchMono(13))
                    .foregroundStyle(.white.opacity(0.92))
                    .kerning(1)
                if tasks.openCount > 0 {
                    Text(tr("task.open", tasks.openCount))
                        .font(.notchMono(10)).foregroundStyle(settings.accent)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(settings.accent.opacity(0.15)))
                        .monospacedDigit()
                }
                if tasks.doneToday > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9)).foregroundStyle(Color(hex: "2F9E6E"))
                        Text("\(tasks.doneToday)")
                            .font(.notchMono(10)).foregroundStyle(.white.opacity(0.7))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                }
                Spacer()
                Button {
                    showAdd.toggle()
                    if !showAdd { resetForm() }
                } label: {
                    Image(systemName: showAdd ? "xmark" : "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(NotchGhostButton(size: .small))
            }
            if showAdd {
                addForm
            }
            monthCalendar
            if let day = selectedDay {
                HStack(spacing: 6) {
                    Text(dayTitle(day))
                        .font(.notchMono(10))
                        .foregroundStyle(settings.accent)
                    Spacer()
                    Button(tr("task.clearDay")) { selectedDay = nil }
                        .buttonStyle(NotchGhostButton(size: .mini))
                }
                let dayEvents = CalService.shared.events(on: day)
                if !dayEvents.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(dayEvents) { e in
                            HStack(spacing: 8) {
                                Circle().fill(Color(hex: "3E8BD8")).frame(width: 6, height: 6)
                                Text(e.title.isEmpty ? tr("task.noTitle") : e.title)
                                    .font(.caption)
                                    .foregroundStyle(Color.white.opacity(0.85))
                                    .lineLimit(1)
                                Spacer()
                                Text(e.isAllDay ? tr("task.allDay") : hourRange(e))
                                    .font(.notchMono(9))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(hex: "3E8BD8").opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color(hex: "3E8BD8").opacity(0.25), lineWidth: 1)
                    )
                }
            }
            taskSections
        }
        .padding(8)
        .onAppear { tasks.load() }
    }

    // MARK: - Añadido rápido (para clase: título + Hoy/Mañana + listo)

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            NotchTextField(
                placeholder: tr("task.titlePh"), text: $title,
                icon: "bolt.fill", hint: "⏎",
                color: settings.accent, onCommit: add
            )
            NotchTextField(
                placeholder: tr("task.detailPh"), text: $detail,
                color: settings.accent, font: .caption, onCommit: add
            )
            HStack(spacing: 6) {
                dueChip(.today, label: tr("task.today"))
                dueChip(.tomorrow, label: tr("task.tomorrow"))
                NotchSegments(
                    selection: $priority,
                    options: [(TaskPriority.low, tr("task.low")), (.normal, tr("task.normal")), (.high, tr("task.high"))],
                    color: settings.accent
                )
                Spacer()
                Button(tr("task.add"), action: add)
                    .buttonStyle(NotchPrimaryButton(size: .small, color: settings.accent))
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(settings.accent.opacity(0.25), lineWidth: 1)
        )
    }

    private func dueChip(_ q: QuickDue, label: String) -> some View {
        let sel = quickDue == q
        return Button(label) { quickDue = sel ? .none : q }
            .font(.system(size: 11, weight: sel ? .semibold : .regular))
            .foregroundStyle(sel ? settings.accent : Color.white.opacity(0.6))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(sel ? settings.accent.opacity(0.18) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(sel ? settings.accent.opacity(0.5) : Color.white.opacity(0.09), lineWidth: 1)
            )
            .buttonStyle(.plain)
    }

    private func quickDates() -> (due: Date?, remind: Date?) {
        let cal = Calendar.current
        let now = Date()
        switch quickDue {
        case .none:
            return (nil, nil)
        case .today:
            let due = cal.date(bySettingHour: 23, minute: 59, second: 0, of: now)
            let nine = cal.date(bySettingHour: 9, minute: 0, second: 0, of: now)
            let remind = (nine ?? now) > now ? nine : now.addingTimeInterval(15 * 60)
            return (due, remind)
        case .tomorrow:
            guard let tm = cal.date(byAdding: .day, value: 1, to: now) else { return (nil, nil) }
            let due = cal.date(bySettingHour: 23, minute: 59, second: 0, of: tm)
            let remind = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tm)
            return (due, remind)
        }
    }

    private func add() {
        let qd = quickDates()
        guard tasks.add(title: title, detail: detail, priority: priority,
                        dueAt: qd.due, remindAt: qd.remind) != nil else { return }
        resetForm()
        showAdd = false
    }

    private func resetForm() {
        title = ""; detail = ""; priority = .normal; quickDue = .none
    }

    // MARK: - Calendario mensual con puntos y filtro por día

    private var monthBase: Date {
        Calendar.current.date(byAdding: .month, value: monthOffset, to: Date()) ?? Date()
    }

    private func dueDays() -> Set<Date> {
        let cal = Calendar.current
        var out = Set<Date>()
        for t in tasks.tasks {
            guard let d = t.dueAt else { continue }
            out.insert(cal.startOfDay(for: d))
        }
        return out
    }

    /// Días con eventos del sistema (calendario conectado): segundo punto.
    private func systemEventDays() -> Set<Date> {
        guard NotchSettings.shared.useSystemCalendar else { return [] }
        let cal = Calendar.current
        let start = cal.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        let end = cal.date(byAdding: .month, value: 3, to: Date()) ?? Date()
        return Set(CalService.shared.eventDays(from: start, to: end).map { cal.startOfDay(for: $0) })
    }

    /// Letras de día (L M X…) rotadas al primer día local, marcando el
    /// fin de semana para atenuarlo en la cabecera.
    private func weekdayLetters() -> [(letter: String, weekend: Bool)] {
        let cal = Calendar.current
        var syms = cal.veryShortWeekdaySymbols
        let full = cal.weekdaySymbols // Dom Lun… (índice 0 = domingo)
        let shift = (cal.firstWeekday - 1 + 7) % 7
        syms = Array(syms[shift...] + syms[..<shift])
        let fulls = Array(full[shift...] + full[..<shift])
        var out: [(letter: String, weekend: Bool)] = []
        for i in syms.indices {
            let f = fulls[i]
            out.append((letter: syms[i], weekend: f == "Saturday" || f == "Sunday"))
        }
        return out
    }

    private var monthCalendar: some View {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: monthBase)
        let first = cal.date(from: comps) ?? Date()
        let range = cal.range(of: .day, in: .month, for: first) ?? 1..<30
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let days = dueDays()
        // Una sola consulta para toda la rejilla (antes: por celda).
        let sys = systemEventDays()
        let today = cal.startOfDay(for: Date())
        let monthName: String = {
            return NotchDateFmt.monthLong.string(from: first).capitalized
        }()
        let year = String(cal.component(.year, from: first))
        return VStack(spacing: 8) {
            // Cabecera: mes grande + año atenuado, « › compactos y Hoy.
            HStack(spacing: 5) {
                Button { monthOffset -= 12 } label: {
                    Image(systemName: "chevron.left.2").font(.system(size: 9, weight: .bold)).frame(width: 21, height: 21)
                }
                .buttonStyle(NotchGhostButton(size: .mini))
                .help(String(Calendar.current.component(.year, from: monthBase) - 1))
                Button { monthOffset -= 1 } label: {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold)).frame(width: 21, height: 21)
                }
                .buttonStyle(NotchGhostButton(size: .mini))
                HStack(spacing: 5) {
                    Text(monthName)
                        .font(.notchMono(13))
                        .foregroundStyle(.white.opacity(0.92))
                    Text(year)
                        .font(.notchMono(11))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .monospacedDigit()
                }
                .padding(.leading, 5)
                Spacer()
                Button { monthOffset = 0; selectedDay = nil } label: {
                    Text(tr("act.today"))
                        .font(.notchMono(10))
                        .foregroundStyle(settings.accent)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(settings.accent.opacity(0.14)))
                        .overlay(Capsule().stroke(settings.accent.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button { monthOffset += 1 } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).frame(width: 21, height: 21)
                }
                .buttonStyle(NotchGhostButton(size: .mini))
                Button { monthOffset += 12 } label: {
                    Image(systemName: "chevron.right.2").font(.system(size: 9, weight: .bold)).frame(width: 21, height: 21)
                }
                .buttonStyle(NotchGhostButton(size: .mini))
                .help(String(Calendar.current.component(.year, from: monthBase) + 1))
            }
            // Franja de días de la semana.
            HStack(spacing: 0) {
                ForEach(Array(weekdayLetters().enumerated()), id: \.offset) { _, wd in
                    Text(wd.letter)
                        .font(.notchMono(9))
                        .foregroundStyle(Color.white.opacity(wd.weekend ? 0.32 : 0.45))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.035))
            )
            // Rejilla. OJO: las celdas vacías y los días son ForEach
            // hermanos: sus IDs no pueden solaparse (0..<lead chocaba
            // con 1..<31 y se comía los primeros días del mes).
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 3) {
                ForEach((0..<lead).map { -$0 - 1 }, id: \.self) { _ in
                    Color.clear.frame(height: 30)
                }
                ForEach(range.lowerBound..<range.upperBound, id: \.self) { d in
                    let date = cal.date(byAdding: .day, value: d - 1, to: first) ?? first
                    let sod = cal.startOfDay(for: date)
                    let isSel = selectedDay.map { cal.isDate($0, inSameDayAs: date) } ?? false
                    let isToday = cal.isDate(sod, inSameDayAs: today)
                    let isWeekend = cal.isDateInWeekend(date)
                    let hot = hoveredDay.map { cal.isDate($0, inSameDayAs: date) } ?? false
                    Button {
                        selectedDay = isSel ? nil : date
                    } label: {
                        VStack(spacing: 2) {
                            ZStack {
                                if isToday && !isSel {
                                    Circle().fill(settings.accent.opacity(0.9))
                                } else if isSel {
                                    Circle().fill(settings.accent.opacity(0.24))
                                        .overlay(Circle().stroke(settings.accent.opacity(0.85), lineWidth: 1))
                                } else if hot {
                                    Circle().fill(Color.white.opacity(0.08))
                                }
                                Text("\(d)")
                                    .font(.notchMono(11))
                                    .foregroundStyle(
                                        isSel ? .white
                                            : isToday ? (Color.black.opacity(0.85))
                                            : Color.white.opacity(isWeekend ? 0.42 : 0.8)
                                    )
                                    .monospacedDigit()
                            }
                            .frame(width: 26, height: 26)
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(days.contains(sod) ? settings.accent : Color.clear)
                                    .frame(width: 4, height: 4)
                                Circle()
                                    .fill(sys.contains(sod) ? Color(hex: "3E8BD8") : Color.clear)
                                    .frame(width: 4, height: 4)
                            }
                            .frame(height: 5)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hot in
                        withAnimation(.easeOut(duration: 0.12)) {
                            hoveredDay = hot ? date : (hoveredDay == date ? nil : hoveredDay)
                        }
                    }
                }
            }
            // Leyenda: qué significa cada punto.
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle().fill(settings.accent).frame(width: 5, height: 5)
                    Text(tr("task.title")).font(.notchMono(9)).foregroundStyle(Color.white.opacity(0.4))
                }
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: "3E8BD8")).frame(width: 5, height: 5)
                    Text(tr("task.lgCal")).font(.notchMono(9)).foregroundStyle(Color.white.opacity(0.4))
                }
                Spacer()
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color.white.opacity(0.058), Color.white.opacity(0.028)],
                                   startPoint: .top, endPoint: .bottom)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.13), Color.white.opacity(0.055)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.20), radius: 10, y: 5)
    }

    private func dayTitle(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return tr("act.today") }
        return NotchDateFmt.dayMedium.string(from: d)
    }

    private func hourRange(_ e: CalEvent) -> String {
        return "\(NotchDateFmt.hourMinute.string(from: e.start))–\(NotchDateFmt.hourMinute.string(from: e.end))"
    }

    // MARK: - Secciones por estado

    @ViewBuilder
    private var taskSections: some View {
        if shown.isEmpty {
            VStack(spacing: 7) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.06)).frame(width: 40, height: 40)
                    Image(systemName: "checklist")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
                Text(selectedDay == nil ? tr("task.empty") : tr("act.empty"))
                    .font(.caption).foregroundStyle(.secondary)
                if selectedDay != nil {
                    Button(tr("task.clearDay")) { selectedDay = nil }
                        .buttonStyle(NotchGhostButton(size: .mini, tint: settings.accent))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 16)
        } else {
            let todos = inStatus(.todo), doings = inStatus(.doing)
            let dones = inStatus(.done), archived = inStatus(.archived)
            if !doings.isEmpty {
                sectionHeader(tr("task.doing"), icon: "arrow.right", count: doings.count, color: settings.accent)
                ForEach(doings) { task in
                    TaskRow(
                        task: task, store: tasks,
                        expanded: expanded == task.id,
                        onToggleExpand: { expanded = expanded == task.id ? nil : task.id }
                    )
                }
            }
            if !todos.isEmpty {
                sectionHeader(tr("task.todo"), icon: "circle", count: todos.count, color: Color.white.opacity(0.5))
                ForEach(todos) { task in
                    TaskRow(
                        task: task, store: tasks,
                        expanded: expanded == task.id,
                        onToggleExpand: { expanded = expanded == task.id ? nil : task.id }
                    )
                }
            }
            if !dones.isEmpty {
                sectionHeader(tr("task.done"), icon: "checkmark", count: dones.count, color: Color(hex: "2F9E6E"))
                ForEach(dones) { task in
                    TaskRow(
                        task: task, store: tasks,
                        expanded: expanded == task.id,
                        onToggleExpand: { expanded = expanded == task.id ? nil : task.id }
                    )
                }
            }
            if !archived.isEmpty {
                Button {
                    showArchived.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showArchived ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.4))
                            .frame(width: 12)
                        Text(tr("task.archived").uppercased())
                            .font(.notchMono(10))
                            .foregroundStyle(Color.white.opacity(0.4))
                            .kerning(1.2)
                        Text("\(archived.count)")
                            .font(.notchMono(10))
                            .foregroundStyle(Color.white.opacity(0.3))
                            .monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
                if showArchived {
                    ForEach(archived) { task in
                        TaskRow(
                            task: task, store: tasks,
                            expanded: expanded == task.id,
                            onToggleExpand: { expanded = expanded == task.id ? nil : task.id }
                        )
                    }
                }
            }
        }
    }
}

/// Fila de tarea: estado (cicla), título, agente y expandible con
/// marcas de tiempo, reorden ↑↓, archivar y eliminar.
private struct TaskRow: View {
    var task: AgentTask
    @ObservedObject var store: TaskStore
    @ObservedObject private var settings = NotchSettings.shared
    var expanded: Bool
    var onToggleExpand: () -> Void

    private var notifyBinding: Binding<TaskNotify> {
        Binding(
            get: { task.notifyMode },
            set: {
                var t = task
                t.notifyMode = $0
                // Sin aviso no hay hora que valga.
                if $0 == .none { t.remindAt = nil; t.remindedAt = nil }
                store.update(t)
            }
        )
    }

    private var dueBinding: Binding<Date> {
        Binding(
            get: { task.dueAt ?? Date() },
            set: {
                var t = task
                t.dueAt = $0
                store.update(t)
            }
        )
    }

    private var remindBinding: Binding<Date> {
        Binding(
            get: { task.remindAt ?? Date().addingTimeInterval(3600) },
            set: {
                var t = task
                t.remindAt = $0
                t.remindedAt = nil
                if t.notifyMode == .none { t.notifyMode = .both }
                store.update(t)
            }
        )
    }

    private var isOverdue: Bool {
        guard task.isOpen, let d = task.dueAt else { return false }
        return d < Calendar.current.startOfDay(for: Date())
    }

    private func shortDay(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return tr("task.today") }
        if cal.isDateInTomorrow(d) { return tr("task.tomorrow") }
        return NotchDateFmt.dayShortStyle.string(from: d)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Carril de prioridad: color según urgencia.
            RoundedRectangle(cornerRadius: 2)
                .fill(priorityColor)
                .frame(width: 3)
                .padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button { advance() } label: {
                        Image(systemName: statusIcon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(statusColor)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(statusHelp)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(task.status == .done ? Color.white.opacity(0.45) : Color.white.opacity(0.92))
                            .strikethrough(task.status == .done)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            if let due = task.dueAt {
                                Text(tr("task.due") + " " + shortDay(due))
                                    .font(.notchMono(8))
                                    .foregroundStyle(isOverdue ? Color(hex: "E0574B") : settings.accent)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill((isOverdue ? Color(hex: "E0574B") : settings.accent).opacity(0.14)))
                            }
                            Text(statusLine)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button { onToggleExpand() } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.4))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                }
                if expanded {
                    if !task.detail.isEmpty {
                        Text(task.detail)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 32)
                    }
                    // Fecha + aviso configurable por evento.
                    VStack(spacing: 4) {
                        DatePicker(tr("task.due"), selection: dueBinding, displayedComponents: .date)
                            .font(.caption)
                        DatePicker(tr("task.remind"), selection: remindBinding, displayedComponents: [.date, .hourAndMinute])
                            .font(.caption)
                        NotchSegments(
                            selection: notifyBinding,
                            options: [(.pill, tr("task.nPill")), (.system, tr("task.nSystem")), (.both, tr("task.nBoth")), (.none, tr("task.nNone"))],
                            color: settings.accent
                        )
                    }
                    .padding(.leading, 32)
                    HStack(spacing: 4) {
                        Spacer()
                        Button { move(-1) } label: {
                            Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold)).frame(width: 24, height: 22)
                        }
                        .buttonStyle(NotchGhostButton(size: .mini))
                        .help(tr("task.up"))
                        Button { move(1) } label: {
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).frame(width: 24, height: 22)
                        }
                        .buttonStyle(NotchGhostButton(size: .mini))
                        .help(tr("task.down"))
                        Button {
                            var t = task
                            t.status = t.status == .archived ? .todo : .archived
                            store.update(t)
                        } label: {
                            Image(systemName: "archivebox").font(.system(size: 10)).frame(width: 24, height: 22)
                        }
                        .buttonStyle(NotchGhostButton(size: .mini))
                        .help(task.status == .archived ? tr("task.unarchive") : tr("task.archive"))
                        Button { store.remove(task) } label: {
                            Image(systemName: "trash").font(.system(size: 10)).frame(width: 24, height: 22)
                        }
                        .buttonStyle(NotchGhostButton(size: .mini, tint: Color(hex: "E0574B")))
                        .help(tr("task.delete"))
                    }
                }
            }
            .padding(.leading, 6)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(task.status == .done ? Color.white.opacity(0.025) : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(task.isOpen ? Color.white.opacity(0.08) : Color.clear, lineWidth: 1)
        )
    }

    private var priorityColor: Color {
        switch task.priority {
        case .high: return Color(hex: "E0574B")
        case .normal: return settings.accent.opacity(task.isOpen ? 0.8 : 0.3)
        case .low: return Color.white.opacity(0.25)
        }
    }

    private var statusIcon: String {
        switch task.status {
        case .todo: return "circle"
        case .doing: return "circle.dotted"
        case .done: return "checkmark.circle.fill"
        case .archived: return "archivebox"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .todo: return Color.white.opacity(0.5)
        case .doing: return settings.accent
        case .done: return Color(hex: "2F9E6E")
        case .archived: return Color.white.opacity(0.3)
        }
    }

    private var statusHelp: String {
        switch task.status {
        case .todo: return tr("task.todo")
        case .doing: return tr("task.doing")
        case .done: return tr("task.done")
        case .archived: return tr("task.archived")
        }
    }

    private var statusLine: String {
        let f = DateFormatter()
        f.locale = .current; f.dateStyle = .short; f.timeStyle = .short
        if let d = task.doneAt { return tr("task.doneAt", f.string(from: d)) }
        if let r = task.remindAt, task.remindedAt == nil { return tr("task.remind") + " " + shortTime(r) }
        return f.string(from: task.createdAt)
    }

    private func shortTime(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return NotchDateFmt.hourMinute.string(from: d) }
        return NotchDateFmt.dayShortTime.string(from: d)
    }

    private func advance() {
        switch task.status {
        case .todo: store.setStatus(task, .doing)
        case .doing: store.setStatus(task, .done)
        case .done: store.setStatus(task, .todo)
        case .archived: store.setStatus(task, .todo)
        }
    }

    private func move(_ delta: Int) {
        // Reordena dentro de la lista global por vecindad.
        guard let i = store.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let j = i + delta
        guard store.tasks.indices.contains(j) else { return }
        // Mueve usando el orden visible completo del store.
        let ids = store.tasks.map(\.id)
        var ids2 = ids
        ids2.move(fromOffsets: IndexSet(integer: i), toOffset: delta > 0 ? j + 1 : j)
        let byId = Dictionary(uniqueKeysWithValues: store.tasks.map { ($0.id, $0) })
        var out: [AgentTask] = []
        for id in ids2 { if let t = byId[id] { out.append(t) } }
        store.replaceAll(out)
    }
}
#endif
