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
    @State private var selectedTab = 0

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
            VStack(spacing: 0) {
                if !store.waiting.isEmpty {
                    waitingBanner
                        .padding(.top, 11)
                        .padding([.leading, .trailing], 14)
                }
                if !extraTabs.isEmpty {
                    // Como Lumio: fila de botones arriba, separador fino,
                    // contenido debajo.
                    let sel = min(selectedTab, extraTabs.count - 1)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 5) {
                            ForEach(0..<extraTabs.count, id: \.self) { i in
                                NavButton(
                                    title: extraTabs[i].title,
                                    icon: iconName(for: extraTabs[i].title),
                                    selected: i == sel
                                ) { selectedTab = i }
                            }
                            Spacer(minLength: 0)
                            Text(store.active.isEmpty ? "sin agentes" : "\(store.active.count) activos")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.white.opacity(0.8))
                        }
                        .padding(.top, 10)
                        .padding(.bottom, 9)
                        .padding(.horizontal, 16)

                        // Separador fino a todo el ancho, como Lumio.
                        Rectangle()
                            .fill(Color.white.opacity(0.16))
                            .frame(height: 1)

                        extraTabs[sel].view
                            .frame(minHeight: 220)
                            .padding(.top, 12)
                            .padding(.bottom, 14)
                            .padding(.horizontal, 16)
                    }
                }
            }
            .frame(width: 680)
            .background(panelGlass)
        }
        // Como Lumio: vidrio oscuro siempre, de día y de noche.
        .environment(\.colorScheme, .dark)
    }

    /// Vidrio casi negro de Lumio (#131413 sobre el fondo), con filo sutil.
    private var panelGlass: some View {
        let shape = UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 0, bottomLeading: 18, bottomTrailing: 18, topTrailing: 0),
            style: .continuous
        )
        return ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(Color.black.opacity(0.55))
        }
        .overlay(shape.stroke(Color.white.opacity(0.07), lineWidth: 1))
        .shadow(radius: 24)
    }

    private var waitingBanner: some View {
        VStack(spacing: 8) {
            ForEach(store.waiting, id: \.agent) { s in
                WaitingCard(session: s, onAllow: onAllow, onReply: onReply, onOpen: onOpen)
            }
        }
    }
}

private struct WaitingCard: View {
    var session: AgentSession
    var onAllow: (AgentSession) -> Void
    var onReply: (AgentSession, String) -> Void
    var onOpen: (AgentSession) -> Void
    @State private var replyText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: session.agent.notchColorHex)).frame(width: 8, height: 8)
                Text("\(session.agent.displayName) te necesita")
                    .font(.notchMono(12))
                    .foregroundStyle(.white)
                Spacer()
                Text("espera")
                    .font(.notchMono(10))
                    .foregroundStyle(Color.lumioMagenta)
            }
            Text(session.detail ?? session.status.rawValue)
                .font(.notchMono(10))
                .foregroundStyle(Color.white.opacity(0.6))
                .lineLimit(2)
            HStack(spacing: 6) {
                Button("Allow") { onAllow(session) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.lumioMagenta)
                    .controlSize(.small)
                TextField("Responder…", text: $replyText, onCommit: {
                    onReply(session, replyText); replyText = ""
                })
                .textFieldStyle(.roundedBorder)
                .font(.notchMono(11))
                Button("Enviar") { onReply(session, replyText); replyText = "" }
                    .controlSize(.small)
                    .disabled(replyText.isEmpty)
                Button("Abrir") { onOpen(session) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.lumioMagenta.opacity(0.45), lineWidth: 1)
        )
        .onReceive(NotificationCenter.default.publisher(for: .notchPrefillReply)) { note in
            if let path = note.object as? String {
                replyText = path
            }
        }
    }
}

/// Botón del menú de navegación, con la píldora magenta de Lumio.
private struct NavButton: View {
    var title: String
    var icon: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 30, height: 19)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.lumioMagenta : Color.white.opacity(0.10))
        )
        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.72))
        .help(title)
        .controlSize(.mini)
    }
}

private func iconName(for title: String) -> String {
    switch title {
    case "Office": return "building.2"
    case "Shelf": return "tray"
    case "Focus": return "timer"
    case "Mac": return "cpu"
    case "Notas": return "note.text"
    default: return "gearshape"
    }
}

extension Color {
    /// Magenta de Lumio (barras y píldora activa: #A550A7).
    static let lumioMagenta = Color(hex: "A550A7")

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
