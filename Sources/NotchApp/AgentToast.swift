#if os(macOS)
import AppKit
import NotchCore
import SwiftUI

// MARK: - Aviso de tarea terminada (como el de música).
//
// Cuando un agente acaba, sale del notch una píldora con su color,
// qué ha terminado y un ✓. Se oculta sola. Solo luz, sin clics.

/// Aviso estilo Lumio: sale del notch con el color del agente.
struct AgentToastView: View {
    @ObservedObject var state: AgentToastState

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                if state.visible {
                    pill
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .animation(.snappy(duration: 0.35), value: state.visible)
    }

    private var pill: some View {
        // El negro puro (OpenCode) no se ve: círculo claro con ✓ oscuro.
        let dark = isDarkHex(state.colorHex)
        return HStack(spacing: 10) {
            // Punto del agente con ✓.
            ZStack {
                Circle()
                    .fill(dark ? Color.white.opacity(0.9) : (state.colorHex.map { Color(hex: $0) } ?? Color.gray))
                    .frame(width: 30, height: 30)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(dark ? Color.black : Color.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(state.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .frame(width: 340, height: 64)
        .background(toastGlass)
    }

    private var toastGlass: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(Color.black.opacity(0.55))
            // Lavado sutil con el color del agente.
            if let hex = state.colorHex {
                shape.fill(
                    LinearGradient(
                        colors: [Color(hex: hex).opacity(0.3), Color(hex: hex).opacity(0.08)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
        }
        .overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(radius: 16)
    }
}

/// Hex casi negro (p. ej. OpenCode #000000): necesita círculo claro.
private func isDarkHex(_ hex: String?) -> Bool {
    guard var h = hex else { return false }
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 6, let v = UInt64(h, radix: 16) else { return false }
    let r = Double((v >> 16) & 0xFF) / 255, g = Double((v >> 8) & 0xFF) / 255, b = Double(v & 0xFF) / 255
    return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.15
}

/// Estado del aviso: visible + ocultado automático (con generación para
/// que un aviso nuevo reinicie el temporizador).
final class AgentToastState: ObservableObject {
    @Published var visible = false
    @Published var title = ""
    @Published var subtitle = ""
    @Published var colorHex: String?
    private var hideWork: DispatchWorkItem?
    private var gen = 0

    /// Muestra el aviso (reinicia si ya había uno).
    func announce(title: String, subtitle: String, colorHex: String?) {
        gen += 1
        let g = gen
        hideWork?.cancel()
        self.title = title
        self.subtitle = subtitle
        self.colorHex = colorHex
        visible = true
        let secs = NotchSettings.shared.agentToastSeconds
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.gen == g else { return }
            withAnimation(.snappy(duration: 0.35)) { self.visible = false }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + secs, execute: w)
    }

    func hideNow() {
        gen += 1
        hideWork?.cancel()
        visible = false
    }
}

/// Una ventana de aviso por pantalla con notch, siempre click-through.
/// Misma posición que el aviso de música: salen de uno en uno (cola).
final class AgentToastController {
    let state = AgentToastState()
    private var panels: [NSPanel] = []
    /// Para no pisar el panel principal cuando está abierto.
    var isPanelVisible: (() -> Bool)?

    func rebuild(notches: [ScreenNotch]) {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        for entry in notches where entry.layout.hasNotch {
            let n = entry.layout.notchRect
            let w: CGFloat = 340, h: CGFloat = 64
            let frame = NSRect(x: n.midX - w / 2, y: n.minY - h - 10, width: w, height: h)
            fputs("NOTCH-AGENTTOAST frame=\(frame)\n", stderr)
            panels.append(makePanel(frame: frame))
        }
        panels.forEach { $0.orderFrontRegardless() }
    }

    func show(session: AgentSession) {
        guard NotchSettings.shared.agentToastEnabled else { return }
        guard isPanelVisible?() != true else { return }
        // El detail de un done es el snapshot (path): acorta ~/.
        var detail = (session.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if detail.hasPrefix(home) { detail = "~" + detail.dropFirst(home.count) }
        state.announce(
            title: tr("toast.done", session.agent.displayName),
            subtitle: detail.isEmpty ? tr("toast.taskDone") : detail,
            colorHex: session.agent.notchColorHex
        )
    }

    func hide() { state.hideNow() }

    private func makePanel(frame: NSRect) -> NSPanel {
        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false
        // Solo luz: nunca intercepta clics (ni siquiera visible).
        p.ignoresMouseEvents = true
        p.contentView = NSHostingView(rootView: AgentToastView(state: state))
        return p
    }
}
#endif
