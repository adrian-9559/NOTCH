import Foundation

/// Contrato que cumple cada uno de los 16 detectores.
public protocol AgentDetector: Sendable {
    var agent: AgentID { get }
    /// Nombres de proceso a buscar en `ps` (minúsculas, match por contains).
    var processHints: [String] { get }
    /// Exclusiones (minúsculas): si el comando las contiene, se descarta.
    /// Evita falsos positivos como CursorUIViewService de Apple.
    var processExclusions: [String] { get }
    /// Rutas de sesión/config a vigilar. `~` se expande. Pueden no existir.
    var sessionPaths: [String] { get }
    func detect(with snapshot: SystemSnapshot) -> [AgentSession]
}

public extension AgentDetector {
    var processExclusions: [String] { [] }

    func detect(with snapshot: SystemSnapshot) -> [AgentSession] {
        let procs = snapshot.processes.filter { p in
            let cmd = p.command.lowercased()
            guard !processExclusions.contains(where: { cmd.contains($0) }) else { return false }
            return processHints.contains { hint in cmd.contains(hint) }
        }
        let files = sessionPaths.flatMap { expandSessionFiles($0) }

        // Sin proceso ni archivos: no activo.
        if procs.isEmpty && files.isEmpty { return [] }

        let latestMtime = files.map { $0.mtime }.max()
        let latestPath = files.max(by: { $0.mtime < $1.mtime })?.path
        // Prioriza el binario real (basename) sobre procesos que solo contienen
        // el hint en sus argumentos (ej. node corriendo dentro de un worktree).
        func basenameMatches(_ command: String) -> Bool {
            let base = command.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
            return processHints.contains { base.contains($0.trimmingCharacters(in: .whitespaces)) }
        }
        let ranked = procs.sorted { basenameMatches($0.command) && !basenameMatches($1.command) }
        let cpu: Double = procs.map { $0.cpu }.max() ?? 0
        let pid: Int32? = ranked.first?.pid

        let status: AgentStatus
        let detail: String?
        if let waiting = checkWaitingNeedle(in: files), procs.isEmpty == false {
            status = .waiting; detail = waiting
        } else if !procs.isEmpty, (cpu > 5.0 || isRecent(latestMtime, within: 60)) {
            status = .working; detail = latestPath
        } else if !procs.isEmpty {
            status = isRecent(latestMtime, within: 300) ? .done : .idle
            detail = latestPath
        } else if isRecent(latestMtime, within: 600) {
            // Había actividad reciente pero el proceso murió.
            status = .crashed; detail = latestPath
        } else {
            return []
        }

        let sid = latestPath ?? "\(agent.rawValue)-proc"
        return [AgentSession(agent: agent, sessionID: sid, status: status, pid: pid,
                             cpuPercent: procs.isEmpty ? nil : cpu,
                             lastActivity: latestMtime, projectPath: nil, detail: detail)]
    }

    private func isRecent(_ date: Date?, within seconds: TimeInterval) -> Bool {
        guard let d = date else { return false }
        return Date().timeIntervalSince(d) < seconds
    }

    /// Heurística "needs your yes": busca approval/permission en logs recientes.
    private func checkWaitingNeedle(in files: [SessionFile]) -> String? {
        let needles = ["approval", "permission", "waiting", "needs your", "allow?", "confirm", "yes/no", "[y/n]"]
        for f in files.prefix(6) where f.mtime.timeIntervalSinceNow > -300 {
            guard let s = try? String(contentsOfFile: f.path, encoding: .utf8).lowercased().suffix(4000) else { continue }
            if needles.contains(where: { s.contains($0) }) { return "waiting: \(f.path)" }
        }
        return nil
    }
}

// MARK: - Snapshot del sistema

public struct LiveProcess: Sendable {
    public var pid: Int32
    public var command: String
    public var cpu: Double
    public init(pid: Int32, command: String, cpu: Double) {
        self.pid = pid; self.command = command; self.cpu = cpu
    }
}

public struct SessionFile: Sendable {
    public var path: String
    public var mtime: Date
}

public struct SystemSnapshot: Sendable {
    public var processes: [LiveProcess]
    public var now = Date()
    public init(processes: [LiveProcess]) {
        self.processes = processes
    }
    /// Compat: tuplas (command, pid, cpu) como las devuelve `ps`.
    public init(tuples: [(String, Int32, Double)]) {
        self.processes = tuples.map { LiveProcess(pid: $0.1, command: $0.0, cpu: $0.2) }
    }
}

func expandSessionFiles(_ pattern: String) -> [SessionFile] {
    let expanded = (pattern as NSString).expandingTildeInPath
    let fm = FileManager.default
    var out: [SessionFile] = []
    if let attrs = try? fm.attributesOfItem(atPath: expanded),
       let mtime = attrs[.modificationDate] as? Date {
        // Si es directorio, coge los N más recientes dentro (1 nivel).
        var isDir: ObjCBool = false
        fm.fileExists(atPath: expanded, isDirectory: &isDir)
        if isDir.boolValue {
            let kids = (try? fm.contentsOfDirectory(atPath: expanded)) ?? []
            for k in kids.prefix(40) {
                let p = (expanded as NSString).appendingPathComponent(k)
                if let a = try? fm.attributesOfItem(atPath: p),
                   let m = a[.modificationDate] as? Date {
                    // Para .sqlite con -wal, usa el wal si es más nuevo.
                    out.append(SessionFile(path: p, mtime: m))
                }
            }
            out.sort { $0.mtime > $1.mtime }
            return Array(out.prefix(10))
        }
        return [SessionFile(path: expanded, mtime: mtime)]
    }
    return []
}
