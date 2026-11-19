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

    private let engine: MonitorEngine

    public init(engine: MonitorEngine = MonitorEngine()) {
        self.engine = engine
    }

    public func refresh() {
        let fresh = engine.poll()
        let old = Dictionary(uniqueKeysWithValues: sessions.map { ($0.agent, $0) })
        var changed = false
        for s in fresh {
            if old[s.agent]?.status != s.status { changed = true; break }
        }
        if changed || fresh.count != sessions.count {
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
