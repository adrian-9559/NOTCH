import Combine
import Foundation
import NotchCore

/// Fuente única de verdad para la UI. El motor expone sesiones;
/// este store publica y detecta transiciones. Usar solo desde el hilo principal.
public final class SessionStore: ObservableObject {
    @Published public private(set) var sessions: [AgentSession] = []
    @Published public private(set) var lastUpdate = Date()

    /// Hook para historial (lo usa HistoryStore en el lote de mini-features).
    public var onChange: ([AgentSession]) -> Void = { _ in }
    /// Snapshot crudo de procesos (auditoría de agentes sin mapear).
    public var onSnapshot: ((SystemSnapshot) -> Void)?

    private let engine: MonitorEngine
    /// Evita solapar pasadas (el poll tarda y llega cada2 s).
    private var refreshing = false

    public init(engine: MonitorEngine = MonitorEngine()) {
        self.engine = engine
    }

    /// Una pasada del motor. `engine.poll()` lanza `ps` y lee logs de
    /// los agentes: se ejecuta en background — en el hilo principal
    /// cada2 s producía tirones al usar el panel.
    public func refresh() {
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // Un solo `ps` para detectar Y auditar (sin lanzarlo dos veces).
            let snap = ProcessMonitor.snapshot()
            let fresh = self.engine.poll(snapshot: snap)
            self.onSnapshot?(snap)
            DispatchQueue.main.async {
                self.refreshing = false
                self.apply(fresh)
            }
        }
    }

    private func apply(_ fresh: [AgentSession]) {
        // Clave agente+pid: puede haber varias instancias del mismo
        // agente (varias TUIs) y la clave por agente solo chocaría.
        func key(_ s: AgentSession) -> String { "\(s.agent.rawValue)#\(s.pid ?? -1)" }
        var old: [String: AgentStatus] = [:]
        for s in sessions { old[key(s)] = s.status }
        var changed = fresh.count != sessions.count
        if !changed {
            for s in fresh where old[key(s)] != s.status { changed = true; break }
        }
        if changed {
            sessions = fresh
            onChange(fresh)
        } else {
            sessions = fresh
        }
        lastUpdate = Date()
    }

    public var active: [AgentSession] {
        sessions.filter { $0.status == .working || $0.status == .waiting }
    }

    public var waiting: [AgentSession] {
        sessions.filter { $0.status == .waiting }
    }

    public func session(for agent: AgentID) -> AgentSession? {
        sessions.first { $0.agent == agent }
    }
}
