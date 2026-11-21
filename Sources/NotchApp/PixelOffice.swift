#if os(macOS)
import NotchCore
import SwiftUI

/// Pestaña Oficina estilo Lumio: los agentes como personitas pixel-art
/// vistas de espaldas en su puesto (teclea, de pie si te necesita, ✓ si
/// terminó, silla vacía si está inactivo) + botón para abrir la oficina
/// grande (ventana aparte) o doble-tap de ⌘ derecha.
struct PixelOfficeView: View {
    @ObservedObject var store: SessionStore
    @State private var tick = 0
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("office").font(.notchMono(11)).foregroundStyle(.secondary)
                Spacer()
                Text("Working: \(workingCount)").font(.notchMono(11)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                ForEach(liveAgents, id: \.self) { agent in
                    deskFor(agent)
                }
            }
            // Abrir la oficina grande, como en Lumio.
            Button {
                OfficeWindowController.shared.show()
            } label: {
                Text("Abrir la oficina")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22).padding(.vertical, 8)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
            Text("o doble-tap ⌘ der.")
                .font(.notchMono(10))
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .onReceive(timer) { _ in tick += 1 }
    }

    private var liveAgents: [AgentID] {
        let active = Set(store.sessions.map(\.agent))
        let base: [AgentID] = [.claudeCode, .codex, .cursor, .opencode]
        return Array(active.union(base)).sorted { $0.rawValue < $1.rawValue }
    }

    private var workingCount: Int {
        store.sessions.filter { $0.status == .working || $0.status == .waiting }.count
    }

    private func status(of agent: AgentID) -> AgentStatus {
        store.session(for: agent)?.status ?? .idle
    }

    private func deskFor(_ agent: AgentID) -> some View {
        let st = status(of: agent)
        switch st {
        case .working:
            return AnyView(DeskUnit(agent: agent, screen: .code, pose: .sitting, tick: tick, width: 140))
        case .waiting:
            return AnyView(DeskUnit(agent: agent, screen: .code, pose: .standing, mark: .alert, tick: tick, width: 140))
        case .done:
            return AnyView(DeskUnit(agent: agent, screen: .logo, pose: .sitting, mark: .check, tick: tick, width: 140))
        default:
            return AnyView(DeskUnit(agent: agent, screen: .off, pose: .sitting, occupied: false, tick: tick, width: 140))
        }
    }
}
#endif
