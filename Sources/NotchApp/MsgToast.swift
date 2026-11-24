#if os(macOS)
import AppKit
import SwiftUI

/// Estado de la píldora de mensajes: app + texto, con ocultado
/// automático (misma semántica que el aviso de canción).
final class MsgToastState: ObservableObject {
    @Published var visible = false
    @Published var app = "WhatsApp"
    @Published var tint = "25D366"
    @Published var icon = "bubble.left.fill"
    @Published var text = ""
    private var hideWork: DispatchWorkItem?
    private var gen = 0

    func announce(app: String, tint: String, icon: String, text: String) {
        gen += 1
        let g = gen
        hideWork?.cancel()
        self.app = app
        self.tint = tint
        self.icon = icon
        self.text = text
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

/// Ventana de la píldora de mensajes (por pantalla con notch).
final class MsgToastController {
    let state = MsgToastState()
    private var panels: [NSPanel] = []
    var isPanelVisible: (() -> Bool)?
    var isBlocked: (() -> Bool)?
    private var retryGen = 0

    /// Lanza la píldora si no hay otra ocupando el notch.
    func show(app: String, tint: String, icon: String, text: String) {
        guard isPanelVisible?() != true else { return }
        retryGen += 1
        let gen = retryGen
        announceWhenFree(gen: gen, attempt: 0,
                         app: app, tint: tint, icon: icon, text: text)
    }

    private func announceWhenFree(gen: Int, attempt: Int, app: String,
                                  tint: String, icon: String, text: String) {
        guard gen == retryGen, attempt < 3 else {
            if gen == retryGen {
                state.announce(app: app, tint: tint, icon: icon, text: text)
            }
            return
        }
        if isBlocked?() == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.announceWhenFree(gen: gen, attempt: attempt + 1,
                                       app: app, tint: tint, icon: icon, text: text)
            }
            return
        }
        state.announce(app: app, tint: tint, icon: icon, text: text)
    }

    func rebuild(notches: [ScreenNotch]) {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        for entry in notches where entry.layout.hasNotch {
            let n = entry.layout.notchRect
            let w: CGFloat = 340, h: CGFloat = 64
            let frame = NSRect(x: n.midX - w / 2, y: n.minY - h - 10, width: w, height: h)
            fputs("NOTCH-MSGTOAST frame=\(frame)\n", stderr)
            panels.append(makePanel(frame: frame))
        }
        panels.forEach { $0.orderFrontRegardless() }
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
        p.alphaValue = 0
        p.ignoresMouseEvents = true
        p.contentView = NSHostingView(rootView: MsgToastView(state: state))
        return p
    }
}

/// Píldora de mensajes: mismo material que el resto de avisos (vidrio
/// oscuro + tinte de la app) y con Liquid Glass si está activo.
struct MsgToastView: View {
    @ObservedObject var state: MsgToastState

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
        let tint = Color(hex: state.tint)
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.opacity(0.22))
                    .frame(width: 28, height: 28)
                Image(systemName: state.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(state.app)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Text(state.text)
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tint.opacity(0.16))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .liquidGlass(NotchSettings.shared.liquidGlass, radius: 14)
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
    }
}
#endif
