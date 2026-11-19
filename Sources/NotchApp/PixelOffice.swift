#if os(macOS)
import NotchCore
import SwiftUI

/// Oficina pixel-art que crece desde el notch.
/// Cada agente teclea en su iMac; el que te necesita se levanta;
/// los terminados se van al café. Desde 6 agentes: 10 desks + sala
/// de reuniones + lounge + ciudad al atardecer. La luz sigue al sol real.
struct PixelOfficeView: View {
    @ObservedObject var store: SessionStore
    @State private var tick = 0
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("office").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(sunLabel).font(.caption).foregroundStyle(.secondary)
            }
            Canvas { ctx, size in
                drawScene(ctx: ctx, size: size)
            }
            .frame(height: canvasHeight)
            .background(RoundedRectangle(cornerRadius: 12).fill(skyColor))
            .onReceive(timer) { _ in tick += 1 }
        }
    }

    private var liveAgents: [AgentID] {
        let active = Set(store.sessions.map(\.agent))
        // Muestra activos + los 4 principales aunque estén inactivos (oficina viva).
        let base: [AgentID] = [.claudeCode, .codex, .cursor, .opencode]
        return Array(active.union(base)).sorted { $0.rawValue < $1.rawValue }
    }

    private var canvasHeight: CGFloat {
        liveAgents.count > 6 ? 300 : 170
    }

    private var isNight: Bool {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 7 || h >= 20
    }

    private var skyColor: Color {
        isNight ? Color(red: 0.08, green: 0.1, blue: 0.22) : Color(red: 0.85, green: 0.93, blue: 0.97)
    }

    private var sunLabel: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 6..<12: return "mañana"
        case 12..<20: return "tarde"
        default: return "noche"
        }
    }

    private func status(of agent: AgentID) -> AgentStatus {
        store.session(for: agent)?.status ?? .idle
    }

    private func drawScene(ctx: GraphicsContext, size: CGSize) {
        let agents = liveAgents
        // Fondo: ciudad al atardecer cuando hay sala grande.
        if agents.count > 6 {
            drawCity(ctx: ctx, size: size)
        }
        let cols = agents.count > 6 ? 5 : 4
        let cw = size.width / CGFloat(cols)
        for (i, agent) in agents.enumerated() {
            let col = i % cols, row = i / cols
            let cx = cw * (CGFloat(col) + 0.5)
            let cy = size.height - 34 - CGFloat(row) * 74
            drawDesk(ctx: ctx, center: CGPoint(x: cx, y: cy), agent: agent)
        }
    }

    private func drawCity(ctx: GraphicsContext, size: CGSize) {
        // Ventana con edificios y sol/luna según hora real.
        var win = CGRect(x: 8, y: 8, width: size.width - 16, height: 64)
        ctx.fill(Path(win), with: .color(isNight ? .black.opacity(0.7) : .cyan.opacity(0.25)))
        let orbX = win.maxX - 24, orbY = isNight ? win.maxY - 16 : win.minY + 16
        ctx.fill(Path(CGRect(x: orbX - 8, y: orbY - 8, width: 16, height: 16)), with: .color(isNight ? .white : .yellow))
        for i in 0..<8 {
            let bw: CGFloat = (win.width - 16) / 8
            let bh = CGFloat(20 + ((i * 37) % 30))
            let bx = win.minX + 8 + CGFloat(i) * bw
            let b = CGRect(x: bx, y: win.minY + 4, width: bw - 3, height: bh)
            ctx.fill(Path(b), with: .color(isNight ? .black.opacity(0.8) : .gray.opacity(0.5)))
            if isNight {
                for wy in stride(from: b.minY + 3, to: b.maxY - 2, by: 6) {
                    for wx in stride(from: b.minX + 2, to: b.maxX - 2, by: 6) {
                        if (i + Int(wx) + Int(wy) + tick) % 3 == 0 {
                            ctx.fill(Path(CGRect(x: wx, y: wy, width: 3, height: 3)), with: .color(.yellow.opacity(0.9)))
                        }
                    }
                }
            }
        }
    }

    private func drawDesk(ctx: GraphicsContext, center: CGPoint, agent: AgentID) {
        let st = status(of: agent)
        let accent = Color(hex: agent.notchColorHex)
        let bob: CGFloat = (st == .working && tick % 2 == 0) ? -2 : 0

        // iMac
        let scr = CGRect(x: center.x - 14, y: center.y - 6, width: 28, height: 20)
        ctx.fill(Path(scr), with: .color(.black.opacity(0.85)))
        let glow = CGRect(x: scr.minX + 2, y: scr.minY + 2, width: 24, height: 16)
        ctx.fill(Path(glow), with: .color(st == .idle ? .gray.opacity(0.3) : accent.opacity(0.85)))
        // Soporte
        ctx.fill(Path(CGRect(x: center.x - 2, y: scr.minY - 8, width: 4, height: 8)), with: .color(.gray))
        // Mesa
        ctx.fill(Path(CGRect(x: center.x - 22, y: center.y - 16, width: 44, height: 5)), with: .color(.brown))

        if st == .done {
            // Al café: taza humeante sobre la mesa, silla vacía.
            drawMug(ctx: ctx, at: CGPoint(x: center.x + 14, y: center.y - 11))
        } else {
            // Personita: cabeza + cuerpo. De pie si te necesita.
            let standing = (st == .waiting)
            let bodyH: CGFloat = standing ? 22 : 12
            let bodyY = center.y - 16 - bodyH + bob
            ctx.fill(Path(CGRect(x: center.x - 12, y: bodyY, width: 8, height: bodyH)), with: .color(accent))
            ctx.fill(Path(CGRect(x: center.x - 14, y: bodyY + bodyH, width: 12, height: 10)), with: .color(.pink.opacity(0.9)))
            if standing {
                // Brazos arriba: "¡eh, mírame!"
                let wave: CGFloat = tick % 2 == 0 ? 3 : -3
                ctx.fill(Path(CGRect(x: center.x - 18, y: bodyY + bodyH - 2 + wave, width: 4, height: 10)), with: .color(accent))
                ctx.fill(Path(CGRect(x: center.x - 6, y: bodyY + bodyH - 2 - wave, width: 4, height: 10)), with: .color(accent))
            }
        }
        // Etiqueta
        let label = "\(agent.displayName)"
        ctx.draw(Text(label).font(.system(size: 7)).foregroundColor(.secondary),
                 at: CGPoint(x: center.x, y: center.y - 24), anchor: .center)
    }

    private func drawMug(ctx: GraphicsContext, at p: CGPoint) {
        ctx.fill(Path(CGRect(x: p.x - 4, y: p.y - 6, width: 8, height: 7)), with: .color(.white))
        if tick % 2 == 0 {
            ctx.fill(Path(CGRect(x: p.x - 1, y: p.y + 1, width: 2, height: 4)), with: .color(.gray.opacity(0.5)))
        }
    }
}
#endif
