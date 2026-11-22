import Foundation

/// Contrato que cumple cada uno de los 16 detectores.
public protocol AgentDetector: Sendable {
    var agent: AgentID { get }
    /// Nombres de proceso a buscar en `ps` (minúsculas, match por contains).
    var processHints: [String] { get }
    /// Basenames EXACTOS del binario (minúsculas): para CLIs ambiguos
    /// tipo `pi` donde un contains cascaría con `pip`, `pix`…
    var processBasenames: [String] { get }
    /// Exclusiones (minúsculas): si el comando las contiene, se descarta.
    /// Evita falsos positivos como CursorUIViewService de Apple.
    var processExclusions: [String] { get }
    /// Rutas de sesión/config a vigilar. `~` se expande. Pueden no existir.
    var sessionPaths: [String] { get }
    func detect(with snapshot: SystemSnapshot) -> [AgentSession]
}

public extension AgentDetector {
    var processExclusions: [String] { [] }
    var processBasenames: [String] { [] }

    func detect(with snapshot: SystemSnapshot) -> [AgentSession] {
        // Basename del binario: primer token del comando, última barra.
        func base(_ command: String) -> String {
            let first = command.split(separator: " ").first.map(String.init) ?? command
            return (first.split(separator: "/").last.map(String.init) ?? first).lowercased()
        }
        let procs = snapshot.processes.filter { p in
            let cmd = p.command.lowercased()
            guard !processExclusions.contains(where: { cmd.contains($0) }) else { return false }
            if processHints.contains(where: { cmd.contains($0) }) { return true }
            let b = base(cmd)
            return processBasenames.contains { b == $0 }
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
        let freshFiles = files.contains { $0.mtime.timeIntervalSinceNow > -60 }
        if let waiting = checkWaitingNeedle(in: files), !procs.isEmpty || freshFiles {
            status = .waiting; detail = waiting
        } else if !procs.isEmpty, (cpu > 5.0 || isRecent(latestMtime, within: 60)) {
            status = .working; detail = latestPath
        } else if !procs.isEmpty {
            status = isRecent(latestMtime, within: 300) ? .done : .idle
            detail = latestPath
        } else if isRecent(latestMtime, within: 60) {
            // Sin proceso reconocido pero el log se está escribiendo
            // AHORA: en uso (agentes de extensión cuyo host no matchea).
            status = .working; detail = latestPath
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
    /// Devuelve la LÍNEA de la pregunta (no la ruta) para mostrarla tal cual.
    private func checkWaitingNeedle(in files: [SessionFile]) -> String? {
        let needles = ["approval", "permission", "waiting", "needs your", "allow?", "confirm", "yes/no", "[y/n]"]
        // Lo más nuevo primero EN GLOBAL (las rutas van en orden fijo y
        // la evidencia reciente podría quedar fuera del prefix).
        for f in files.sorted(by: { $0.mtime > $1.mtime }).prefix(6)
            where f.mtime.timeIntervalSinceNow > -300 {
            guard let full = try? String(contentsOfFile: f.path, encoding: .utf8) else { continue }
            let raw = String(full.suffix(8000)) // la pregunta está al final
            guard let r = needles.compactMap({ raw.range(of: $0, options: .caseInsensitive) })
                .min(by: { $0.lowerBound < $1.lowerBound }) else { continue }
            return Self.questionLine(around: r.lowerBound, in: raw) ?? "waiting: \(f.path)"
        }
        return nil
    }

    /// Extrae la línea que contiene la pregunta (caso original), limpia de
    /// ANSI y capada. nil si es binario (sqlite) o vacía → fallback a ruta.
    static func questionLine(around idx: String.Index, in raw: String) -> String? {
        let lineStart = raw[..<idx].lastIndex(of: "\n").map { raw.index(after: $0) } ?? raw.startIndex
        let lineEnd = raw[idx...].firstIndex(of: "\n") ?? raw.endIndex
        let candidate = String(raw[lineStart..<lineEnd])
        // Binario (sqlite): exige mayoría imprimible sobre el original.
        let printable = candidate.unicodeScalars.filter { ($0.isASCII && $0.value >= 32) || $0.value == 9 }.count
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !candidate.contains("\0"), // binario (sqlite) siempre los trae
              Double(printable) / Double(max(1, candidate.count)) > 0.7 else { return nil }
        // Pela controles/ANSI para pintar limpio en la píldora.
        var line = candidate
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .filter { $0.isASCII && ($0 >= " " || $0 == "\t") }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        if line.count > 160 { line = String(line.prefix(160)) + "…" }
        return line
    }
}

// MARK: - Juez de episodios (anti-spam de avisos)

// Decisiones puras para los avisos de agente: solo al completar episodios
// de verdad (no por parpadeos del detector ni subagentes que van y vienen).
public enum EpisodeJudge {
    /// Trabajo mínimo para que un done avise (igual que antes).
    public static let doneMinWorked: TimeInterval = 20
    /// El done debe mantenerse este tiempo (antes 10 s: los subagentes
    /// largos dejaban el proceso quieto y disparaban avisos falsos).
    public static let donePersistence: TimeInterval = 45
    /// La pregunta debe seguir ahí este tiempo (evita parpadeos).
    public static let waitPersistence: TimeInterval = 5

    /// ¿Arranca el reloj de done? Solo working/waiting → done con curro.
    public static func shouldStartDoneClock(prev: AgentStatus?, current: AgentStatus, worked: TimeInterval) -> Bool {
        guard current == .done, prev == .working || prev == .waiting else { return false }
        return worked >= doneMinWorked
    }

    /// ¿Avisa el done? Solo si sigue en done y no es el mismo request
    /// ya avisado (sin quietud/idle/crash de por medio).
    public static func shouldToastDone(stillDone: Bool, sameRequestNotified: Bool) -> Bool {
        stillDone && !sameRequestNotified
    }

    /// ¿Arranca el reloj de espera? Solo al ENTRAR en waiting (una vez
    /// por episodio: waiting → waiting no re-dispara).
    public static func shouldStartWaitClock(prev: AgentStatus?, current: AgentStatus) -> Bool {
        current == .waiting && prev != .waiting
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
