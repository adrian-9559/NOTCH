import Foundation

/// Lee `ps aux` sin permisos especiales (igual que Lumio: sin Screen Recording).
public enum ProcessMonitor {
    public static func snapshot() -> SystemSnapshot {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid=,pcpu=,command="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            // Leer ANTES de waitUntilExit: si el hijo llena el pipe (ps con
            // cientos de procesos) y nadie lee, hijo y padre se bloquean.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let out = String(data: data, encoding: .utf8) ?? ""
            return parsePsOutput(out)
        } catch { return SystemSnapshot(processes: []) }
    }

    static func parsePsOutput(_ out: String) -> SystemSnapshot {
        var rows: [LiveProcess] = []
        for line in out.split(separator: "\n") {
            // Formato: "  PID %CPU COMMAND"
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]) else { continue }
            // Este Mac usa coma decimal en `ps` (locale es_ES): "5,5".
            let cpu = Double(parts[1].replacingOccurrences(of: ",", with: ".")) ?? 0
            rows.append(LiveProcess(pid: pid, command: String(parts[2]).lowercased(), cpu: cpu))
        }
        return SystemSnapshot(processes: rows)
    }
}

/// Agrega los 16 detectores y publica el estado global.
public final class MonitorEngine: Sendable {
    private let detectors: [any AgentDetector]
    public init(detectors: [any AgentDetector] = AllDetectors.all) {
        self.detectors = detectors
    }

    /// Una pasada: todos los agentes activos ahora mismo.
    public func poll(snapshot: SystemSnapshot? = nil) -> [AgentSession] {
        let snap = snapshot ?? ProcessMonitor.snapshot()
        return detectors.flatMap { $0.detect(with: snap) }
            .sorted { $0.agent.rawValue < $1.agent.rawValue }
    }

    /// Los que necesitan tu "yes" (waiting) primero, como el notch de Lumio.
    public func needsAttention(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.filter { $0.status == .waiting }
    }
}
