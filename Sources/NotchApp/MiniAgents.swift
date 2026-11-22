#if os(macOS)
import NotchCore
import SwiftUI

/// Aviso para abrir la pestaña de agentes (la píldora clicable la usa).
extension Notification.Name {
    static let notchShowAgents = Notification.Name("notchShowAgents")
}

// MARK: - Apartado Agentes: respuestas en un sitio especial.
//
// Mientras los agentes trabajan se ven en una lista cargando; el que
// tiene una pregunta sale expandido con la pregunta y las respuestas
// (Permitir / escribir / Abrir). La píldora "te necesita" abre el notch
// directamente aquí.

struct AgentsView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var settings = NotchSettings.shared
    @State private var replyText: [String: String] = [:]

    private var waiting: [AgentSession] { store.sessions.filter { $0.status == .waiting } }
    private var working: [AgentSession] { store.sessions.filter { $0.status == .working } }
    private var recent: [AgentSession] {
        store.sessions.filter { $0.status != .waiting && $0.status != .working }.prefix(4).map(\.self)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                NotchTag(icon: "sparkles", text: tr("agents.title"), color: settings.accent)
                if !store.active.isEmpty {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text(tr("agents.live", store.active.count))
                            .font(.notchMono(10))
                            .foregroundStyle(Color.green)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.12)))
                }
            }
            if waiting.isEmpty && working.isEmpty && recent.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("agents.empty"))
                        .font(.callout).foregroundStyle(.white.opacity(0.85))
                    Text(tr("agents.emptySub"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
            }
            if !waiting.isEmpty {
                NotchTag(icon: "hand.raised.fill", text: tr("agents.need"), color: settings.accent)
                ForEach(waiting, id: \.agent) { s in
                    waitingCard(s)
                }
            }
            if !working.isEmpty {
                NotchTag(icon: "arrow.triangle.2.circlepath", text: tr("agents.working"),
                         color: Color(hex: "4C8FD8"))
                ForEach(working, id: \.agent) { s in
                    loadingRow(s)
                }
            }
            if !recent.isEmpty {
                NotchTag(icon: "clock.arrow.circlepath", text: tr("agents.recent"),
                         color: Color.white.opacity(0.55))
                ForEach(recent, id: \.agent) { s in
                    recentRow(s)
                }
            }
        }
        .padding(8)
    }

    // MARK: - Tarjeta expandida con pregunta y respuestas

    private func waitingCard(_ s: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: s.agent.notchColorHex)).frame(width: 8, height: 8)
                Text("\(s.agent.displayName) \(tr("waiting.needs"))")
                    .font(.notchMono(12))
                    .foregroundStyle(.white)
                Spacer()
                HStack(spacing: 3) {
                    Circle().fill(settings.accent).frame(width: 6, height: 6)
                    Text(tr("waiting.tag"))
                        .font(.notchMono(10))
                        .foregroundStyle(settings.accent)
                }
            }
            if let q = s.detail, !q.isEmpty {
                Text(q)
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
            HStack(spacing: 6) {
                Button(tr("waiting.allow")) { ReplyService.shared.allow(session: s) }
                    .buttonStyle(NotchPrimaryButton(size: .small, color: settings.accent))
                NotchTextField(
                    placeholder: tr("waiting.replyPh"),
                    text: Binding(
                        get: { replyText[s.agent.rawValue] ?? "" },
                        set: { replyText[s.agent.rawValue] = $0 }
                    ),
                    color: settings.accent,
                    font: .notchMono(11),
                    onCommit: { sendReply(s) }
                )
                Button(tr("waiting.send")) { sendReply(s) }
                    .buttonStyle(NotchGhostButton(size: .small, tint: settings.accent))
                    .disabled((replyText[s.agent.rawValue] ?? "").isEmpty)
                Button(tr("waiting.open")) { ReplyService.shared.open(session: s) }
                    .buttonStyle(NotchGhostButton(size: .small))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(settings.accent.opacity(0.5), lineWidth: 1.2)
        )
    }

    // MARK: - Fila cargando (trabajando ahora mismo)

    private func loadingRow(_ s: AgentSession) -> some View {
        let dot = agentColor(for: s.agent.displayName, default: settings.accent)
        return HStack(spacing: 8) {
            ZStack {
                Circle().fill(dot).frame(width: 8, height: 8)
                Circle().fill(dot.opacity(0.3)).frame(width: 16, height: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(s.agent.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))
                Text(s.detail ?? s.status.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let cpu = s.cpuPercent {
                Text(verbatim: "\(Int(cpu.rounded()))%")
                    .font(.notchMono(10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    // MARK: - Recientes (terminados / caídos / quietos)

    private func recentRow(_ s: AgentSession) -> some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor(s.status)).frame(width: 7, height: 7)
            Text(s.agent.displayName)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            Spacer()
            Text(statusText(s.status))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.03)))
        .opacity(0.85)
    }

    private func statusText(_ st: AgentStatus) -> String {
        switch st {
        case .done: return tr("agents.stDone")
        case .idle: return tr("agents.stIdle")
        case .crashed: return tr("agents.stCrashed")
        default: return st.rawValue
        }
    }

    private func statusColor(_ st: AgentStatus) -> Color {
        switch st {
        case .working: return Color.green
        case .waiting: return settings.accent
        case .done: return Color(hex: "2F9E6E")
        default: return Color.white.opacity(0.3)
        }
    }

    private func sendReply(_ s: AgentSession) {
        let t = (replyText[s.agent.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        ReplyService.shared.reply(session: s, text: t)
        replyText[s.agent.rawValue] = ""
    }
}
#endif
