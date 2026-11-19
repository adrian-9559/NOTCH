#if os(macOS)
import NotchCore
import SwiftUI

/// Vista raíz del notch. Datos desde SessionStore; acciones inyectadas
/// (Allow/Reply/Open las implementa ReplyService en su lote).
/// `extraTabs` permite añadir Office/Shelf/Mini sin tocar este archivo.
struct NotchRootView: View {
    @ObservedObject var store: SessionStore
    var extraTabs: [(title: String, view: AnyView)] = []
    /// Ancho del notch físico: dibuja la pestaña negra que lo continúa.
    /// nil = Mac sin notch (sin pestaña).
    var notchWidth: CGFloat? = nil
    var onAllow: (AgentSession) -> Void = { _ in }
    var onReply: (AgentSession, String) -> Void = { _, _ in }
    var onOpen: (AgentSession) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            if let nw = notchWidth {
                // Pestaña que continúa el notch físico: sin esquinas arriba
                // y solapada con el panel para que no haya costura.
                UnevenRoundedRectangle(
                    cornerRadii: .init(topLeading: 0, bottomLeading: 6, bottomTrailing: 6, topTrailing: 0),
                    style: .continuous
                )
                .fill(Color.black)
                .frame(width: min(nw, 200), height: 10)
                .padding(.bottom, -10)
            }
            VStack(spacing: 10) {
                statusRow
                if !store.waiting.isEmpty {
                    waitingBanner
                }
                if !extraTabs.isEmpty {
                    TabView {
                        ForEach(0..<extraTabs.count, id: \.self) { i in
                            extraTabs[i].view.tabItem { Text(extraTabs[i].title) }
                        }
                    }
                    .frame(minHeight: 220)
                }
            }
            .padding(.top, 1)
            .padding([.leading, .trailing, .bottom], 12)
            .frame(width: 520)
            .background(
                UnevenRoundedRectangle(
                    cornerRadii: .init(topLeading: 0, bottomLeading: 18, bottomTrailing: 18, topTrailing: 0),
                    style: .continuous
                )
                .fill(.ultraThinMaterial)
                .shadow(radius: 24)
            )
        }
        // Como Lumio: vidrio oscuro siempre, de día y de noche.
        .environment(\.colorScheme, .dark)
    }

    // Una luz por agente con su color, como Lumio.
    private var statusRow: some View {
        HStack(spacing: 8) {
            ForEach(AgentID.allCases, id: \.self) { agent in
                AgentDot(agent: agent, session: store.session(for: agent))
            }
            Spacer()
            Text(store.active.isEmpty ? "sin agentes" : "\(store.active.count) activos")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var waitingBanner: some View {
        VStack(spacing: 8) {
            ForEach(store.waiting, id: \.agent) { s in
                WaitingCard(session: s, onAllow: onAllow, onReply: onReply, onOpen: onOpen)
            }
        }
    }
}

private struct AgentDot: View {
    var agent: AgentID
    var session: AgentSession?

    var body: some View {
        Circle()
            .fill(Color(hex: agent.notchColorHex).opacity(session == nil ? 0.18 : 1))
            .frame(width: 12, height: 12)
            .overlay {
                if session?.status == .waiting {
                    Circle().stroke(.yellow, lineWidth: 2)
                } else if session?.status == .working {
                    Circle().stroke(.green.opacity(0.7), lineWidth: 1.5)
                }
            }
            .help("\(agent.displayName): \(session?.status.rawValue ?? "inactivo")")
    }
}

private struct WaitingCard: View {
    var session: AgentSession
    var onAllow: (AgentSession) -> Void
    var onReply: (AgentSession, String) -> Void
    var onOpen: (AgentSession) -> Void
    @State private var replyText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {            HStack {
                Circle().fill(Color(hex: session.agent.notchColorHex)).frame(width: 10, height: 10)
                Text("\(session.agent.displayName) te necesita")
                    .font(.headline)
                Spacer()
                Button("Abrir") { onOpen(session) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Text(session.detail ?? session.status.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Button("Allow") { onAllow(session) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                TextField("Responder…", text: $replyText, onCommit: {
                    onReply(session, replyText); replyText = ""
                })
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                Button("Enviar") { onReply(session, replyText); replyText = "" }
                    .controlSize(.small)
                    .disabled(replyText.isEmpty)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.yellow.opacity(0.12)))
        .onReceive(NotificationCenter.default.publisher(for: .notchPrefillReply)) { note in
            if let path = note.object as? String {
                replyText = path
            }
        }
    }
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(h, radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255,
            opacity: 1
        )
    }
}
#endif
