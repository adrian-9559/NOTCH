#if os(macOS)
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

// MARK: - Vista (A2): lista estilo Notion con filtros y reorden

/// Pestaña Tareas: crear, filtrar por estado/agente, reordenar con ↑↓,
/// archivar y eliminar. El envío a agentes llega en A3.
struct TasksView: View {
    @ObservedObject var tasks: TaskStore
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
            HStack {
                Text(tr("task.title")).font(.notchMono(11)).foregroundStyle(.secondary)
                if tasks.openCount > 0 {
                    Text(tr("task.open", tasks.openCount))
                        .font(.notchMono(10)).foregroundStyle(settings.accent)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(settings.accent.opacity(0.15)))
                }
                Spacer()
                Button {
                    showAdd.toggle()
                    if !showAdd { resetForm() }
                } label: {
                    Image(systemName: showAdd ? "xmark" : "plus")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            if showAdd {
                addForm
            }
            HStack(spacing: 4) {
                Picker("", selection: $filterRaw) {
                    Text(tr("task.all")).tag(nil as String?)
                    Text(tr("task.todo")).tag("todo" as String?)
                    Text(tr("task.doing")).tag("doing" as String?)
                    Text(tr("task.done")).tag("done" as String?)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(maxWidth: 300)
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
                Text(filterRaw == nil && agentFilterRaw == nil ? tr("task.empty") : tr("act.empty"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(shown) { task in
                    TaskRow(
                        task: task, store: tasks,
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
        VStack(alignment: .leading, spacing: 6) {
            TextField(tr("task.titlePh"), text: $title)
                .textFieldStyle(.roundedBorder).font(.callout)
            TextField(tr("task.detailPh"), text: $detail)
                .textFieldStyle(.roundedBorder).font(.caption)
            HStack {
                Menu(agentRaw.flatMap({ AgentID(rawValue: $0)?.displayName }) ?? tr("task.anyone")) {
                    Button(tr("task.anyone")) { agentRaw = nil }
                    ForEach(AgentID.allCases, id: \.self) { a in
                        Button(a.displayName) { agentRaw = a.rawValue }
                    }
                }
                .controlSize(.small)
                Picker("", selection: $priority) {
                    Text(tr("task.low")).tag(TaskPriority.low)
                    Text(tr("task.normal")).tag(TaskPriority.normal)
                    Text(tr("task.high")).tag(TaskPriority.high)
                }
                .pickerStyle(.segmented).controlSize(.mini)
                .frame(maxWidth: 220)
                Spacer()
                Button(tr("task.add")) {
                    if tasks.add(title: title, detail: detail,
                                 agent: agentRaw.flatMap(AgentID.init(rawValue:)),
                                 priority: priority) != nil {
                        resetForm()
                        showAdd = false
                    }
                }
                .controlSize(.small).buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
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
    var expanded: Bool
    var onToggleExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { advance() } label: {
                    Image(systemName: statusIcon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(statusHelp)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        if task.priority == .high {
                            Circle().fill(Color(hex: "E0574B")).frame(width: 6, height: 6)
                        }
                        Text(task.title)
                            .font(.callout).foregroundStyle(task.status == .done ? Color.white.opacity(0.5) : Color.white)
                            .strikethrough(task.status == .done)
                            .lineLimit(1)
                    }
                    if let agent = task.agent {
                        Text(agent.displayName)
                            .font(.caption2).foregroundStyle(settings.accent)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button { onToggleExpand() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleExpand)
            if expanded {
                if !task.detail.isEmpty {
                    Text(task.detail).font(.caption).foregroundStyle(Color.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 3) {
                    Text(statusLine).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("task.up")) { move(-1) }.controlSize(.mini)
                    Button(tr("task.down")) { move(1) }.controlSize(.mini)
                    Button(task.status == .archived ? tr("task.unarchive") : tr("task.archive")) {
                        var t = task
                        t.status = t.status == .archived ? .todo : .archived
                        store.update(t)
                    }.controlSize(.mini)
                    Button(tr("task.delete")) { store.remove(task) }
                        .controlSize(.mini).foregroundStyle(.red.opacity(0.9))
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.045)))
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
