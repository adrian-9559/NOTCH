import Foundation
import NotchCore

fputs("NOTCH-MAIN args=\(CommandLine.arguments.joined(separator: ","))\n", stderr)

// Entry point CLI: `swift run NotchApp --monitor-once` lista agentes activos.
// La UI completa (NSPanel notch) vive en NotchUI.swift y requiere macOS + Xcode.
if CommandLine.arguments.contains("--monitor-once") {
    let engine = MonitorEngine()
    let sessions = engine.poll()
    if sessions.isEmpty {
        print("Sin agentes activos.")
    } else {
        for s in sessions {
            print("\(s.agent.displayName) [\(s.status.rawValue)] pid=\(s.pid.map(String.init) ?? "-") cpu=\(s.cpuPercent.map { String(format: "%.1f", $0) } ?? "-") last=\(s.lastActivity?.description ?? "-") detail=\(s.detail ?? "-")")
        }
        let waiting = engine.needsAttention(sessions)
        if !waiting.isEmpty {
            print("NEED-YOU: \(waiting.map(\.agent.displayName).joined(separator: ", "))")
        }
    }
    exit(0)
}

#if os(macOS)
NotchAppMain.main()
#else
print("NotchApp requiere macOS 14+.")
#endif
