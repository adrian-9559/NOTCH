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

struct AgentTask: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var detail: String = ""
    /// AgentID.rawValue destino, nil = cualquiera.
    var agentRaw: String?
    var priority: TaskPriority = .normal
    var status: TaskStatus = .todo
    var createdAt: Date = Date()
    var sentAt: Date?
    var doneAt: Date?

    var agent: AgentID? {
        get { agentRaw.flatMap(AgentID.init(rawValue:)) }
        set { agentRaw = newValue?.rawValue }
    }

    var isOpen: Bool { status == .todo || status == .doing }
}

final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [AgentTask] = []
    /// Último error de envío (se muestra en la cabecera).
    @Published var lastError: String = ""

    private func tasksFile() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NOTCH")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tasks.json")
    }

    // MARK: - persistencia

    func load() {
        guard let data = try? Data(contentsOf: tasksFile()),
              let decoded = try? JSONDecoder().decode([AgentTask].self, from: data) else { return }
        tasks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        try? data.write(to: tasksFile(), options: .atomic)
    }

    // MARK: - mutaciones (todas persisten)

    @discardableResult
    func add(title: String, detail: String = "", agent: AgentID? = nil,
             priority: TaskPriority = .normal) -> AgentTask? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var task = AgentTask(title: t, detail: detail, priority: priority)
        task.agent = agent
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

    func filtered(status: TaskStatus?, agent: AgentID?) -> [AgentTask] {
        tasks.filter { t in
            (status == nil || t.status == status) &&
            (agent == nil || t.agentRaw == agent?.rawValue)
        }
    }

    var openCount: Int { tasks.filter(\.isOpen).count }

    var doneToday: Int {
        let day = Calendar.current.startOfDay(for: Date())
        return tasks.filter { ($0.doneAt ?? .distantPast) >= day }.count
    }
}

// MARK: - Envío a agentes (A3): manual por defecto + auto-envío opcional

/// Entrega la tarea al agente por los canales existentes (iTerm directo,
/// reply del notch o portapapeles + focus). Marca enviada y en curso.
enum TaskDispatcher {
    @discardableResult
    static func send(_ task: AgentTask, via sessions: SessionStore, store: TaskStore) -> Bool {
        let session: AgentSession?
        if let a = task.agent {
            session = sessions.sessions.first { $0.agent == a }
        } else {
            session = sessions.active.first ?? sessions.sessions.first
        }
        guard let s = session else {
            store.lastError = tr("task.noSession")
            return false
        }
        let msg = task.detail.isEmpty ? task.title : "\(task.title)\n\(task.detail)"
        if !HandoffService.deliver(path: msg, to: s) {
            // Fallback: al portapapeles + ventana al frente para pegar.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(msg, forType: .string)
            ReplyService.shared.focus(session: s)
        }
        var t = task
        t.sentAt = Date()
        if t.status == .todo { t.status = .doing }
        store.update(t)
        store.lastError = ""
        return true
    }
}

// MARK: - Vista (A2): lista estilo Notion con filtros y reorden

/// Pestaña Tareas: crear, filtrar por estado/agente, reordenar con ↑↓,
/// archivar y eliminar. El envío a agentes llega en A3.
struct TasksView: View {
    @ObservedObject var tasks: TaskStore
    var sessions: SessionStore?
    @ObservedObject private var settings = NotchSettings.shared
    @State private var showAdd = false
    @State private var title = ""
    @State private var detail = ""
    @State private var agentRaw: String?
    @State private var priority: TaskPriority = .normal
    @State private var filterRaw: String? = nil // nil = todas
    @State private var agentFilterRaw: String? = nil
    @State private var expanded: UUID? = nil

    private var shown: [AgentTask] {
        tasks.tasks.filter { t in
            (filterRaw == nil || t.status.rawValue == filterRaw) &&
            (agentFilterRaw == nil || t.agentRaw == agentFilterRaw)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Cabecera de misión: título + abiertas + hoy + auto + añadir.
            HStack(spacing: 8) {
                Text(tr("task.title"))
                    .font(.notchMono(11))
                    .foregroundStyle(.secondary)
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
                Toggle(tr("task.auto"), isOn: $settings.autoSendTasks)
                    .font(.caption2).toggleStyle(NotchToggleStyle(color: settings.accent, mini: true))
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
            if !tasks.lastError.isEmpty {
                Text(tasks.lastError).font(.caption2).foregroundStyle(.red.opacity(0.9)).lineLimit(1)
            }
            if showAdd {
                addForm
            }
            // Filtros: estado + agente.
            HStack(spacing: 6) {
                NotchSegments(
                    selection: $filterRaw,
                    options: [(nil, tr("task.all")), ("todo", tr("task.todo")), ("doing", tr("task.doing")), ("done", tr("task.done"))],
                    color: settings.accent
                )
                Spacer()
                Menu(agentFilterRaw.flatMap({ AgentID(rawValue: $0)?.displayName }) ?? tr("task.anyone")) {
                    Button(tr("task.anyone")) { agentFilterRaw = nil }
                    ForEach(AgentID.allCases, id: \.self) { a in
                        Button(a.displayName) { agentFilterRaw = a.rawValue }
                    }
                }
                .controlSize(.mini)
            }
            if shown.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "checklist")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.white.opacity(0.25))
                    Text(filterRaw == nil && agentFilterRaw == nil ? tr("task.empty") : tr("act.empty"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 14)
            } else {
                ForEach(shown) { task in
                    TaskRow(
                        task: task, store: tasks, sessions: sessions,
                        expanded: expanded == task.id,
                        onToggleExpand: { expanded = expanded == task.id ? nil : task.id }
                    )
                }
            }
        }
        .padding(8)
        .onAppear { tasks.load() }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(settings.accent)
                TextField(tr("task.titlePh"), text: $title, onCommit: add)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            TextField(tr("task.detailPh"), text: $detail, onCommit: add)
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.75))
            HStack(spacing: 8) {
                Menu(agentRaw.flatMap({ AgentID(rawValue: $0)?.displayName }) ?? tr("task.anyone")) {
                    Button(tr("task.anyone")) { agentRaw = nil }
                    ForEach(AgentID.allCases, id: \.self) { a in
                        Button(a.displayName) { agentRaw = a.rawValue }
                    }
                }
                .controlSize(.small)
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

    private func add() {
        guard let created = tasks.add(title: title, detail: detail,
                     agent: agentRaw.flatMap(AgentID.init(rawValue:)),
                     priority: priority) else { return }
        resetForm()
        showAdd = false
        tasks.lastError = ""
        if settings.autoSendTasks, let ss = sessions {
            TaskDispatcher.send(created, via: ss, store: tasks)
        }
    }

    private func resetForm() {
        title = ""; detail = ""; agentRaw = nil; priority = .normal
    }
}

/// Fila de tarea: estado (cicla), título, agente y expandible con
/// marcas de tiempo, reorden ↑↓, archivar y eliminar.
private struct TaskRow: View {
    var task: AgentTask
    @ObservedObject var store: TaskStore
    @ObservedObject private var settings = NotchSettings.shared
    var sessions: SessionStore?
    var expanded: Bool
    var onToggleExpand: () -> Void

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
                            if let agent = task.agent {
                                Text(agent.displayName.uppercased())
                                    .font(.notchMono(8))
                                    .foregroundStyle(settings.accent)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(settings.accent.opacity(0.14)))
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
                    HStack(spacing: 4) {
                        Spacer()
                        if task.isOpen, sessions != nil {
                            Button { if let ss = sessions { TaskDispatcher.send(task, via: ss, store: store) } } label: {
                                Label(tr("task.send"), systemImage: "paperplane.fill")
                            }
                            .buttonStyle(NotchPrimaryButton(size: .mini, color: settings.accent))
                            .help(tr("task.send"))
                        }
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
        if let s = task.sentAt { return tr("task.sentAt", f.string(from: s)) }
        return f.string(from: task.createdAt)
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
