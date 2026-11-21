#if os(macOS)
import AppKit
import NotchCore
import SwiftUI

// MARK: - Ventana grande de la oficina (como "Open the office" de Lumio).
// Pared con ventanas, estantería, pizarra de stats reales, reloj con la
// hora real y kitchenette; puestos por agente y lounge con los que ya
// terminaron tomando café.

final class OfficeWindowController: NSObject {
    static let shared = OfficeWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = OfficeBigView()
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Oficina NOTCH"
            w.minSize = NSSize(width: 760, height: 560)
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.11, alpha: 1)
            w.contentView = NSHostingView(
                rootView: view.environment(\.colorScheme, .dark)
            )
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Vista grande

struct OfficeBigView: View {
    @ObservedObject private var store = NotchContext.shared.store ?? SessionStore()
    @ObservedObject private var history = HistoryStore.shared
    @State private var tick = 0
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var agents: [AgentID] {
        let active = Set(store.sessions.map(\.agent))
        let base: [AgentID] = [.claudeCode, .codex, .cursor, .opencode]
        return Array(active.union(base)).sorted { $0.rawValue < $1.rawValue }
    }

    private func status(of agent: AgentID) -> AgentStatus {
        store.session(for: agent)?.status ?? .idle
    }

    private var working: [AgentID] { agents.filter { status(of: $0) == .working || status(of: $0) == .waiting } }
    private var done: [AgentID] { agents.filter { status(of: $0) == .done } }

    var body: some View {
        VStack(spacing: 0) {
            header
            wall
            HStack(alignment: .top, spacing: 0) {
                leftRail
                desksArea
                lounge
            }
        }
        .background(OfficeFloorGrid())
        .onReceive(timer) { _ in tick += 1 }
        .onAppear { history.load() }
    }

    // MARK: - cabecera

    private var header: some View {
        HStack {
            Text("Working: \(working.count)")
                .font(.notchMono(13)).foregroundStyle(Color.white.opacity(0.85))
            Spacer()
            Text(done.isEmpty ? "café vacío" : "\(done.count) en el café ☕")
                .font(.notchMono(11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.black)
    }

    // MARK: - pared

    private var wall: some View {
        HStack(alignment: .bottom, spacing: 18) {
            cityWindow
            shelfView
            statsBoard
            pictureView
            clockView
            cityWindow
            kitchenette
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(OfficeTheme.wallBand)
    }

    private var isNight: Bool {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 7 || h >= 20
    }

    private var cityWindow: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3).fill(isNight ? Color(red: 0.05, green: 0.06, blue: 0.12) : Color(red: 0.55, green: 0.72, blue: 0.85))
                    .frame(width: 120, height: 64)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<4, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(isNight ? Color.black.opacity(0.85) : Color.white.opacity(0.75))
                            .frame(width: 22, height: [40, 52, 34, 46][i])
                            .overlay(windowsLit(i))
                    }
                }
                .padding(.bottom, 4)
                Rectangle().fill(Color(red: 0.7, green: 0.71, blue: 0.73)).frame(width: 2, height: 64)
            }
            Rectangle().fill(Color(red: 0.75, green: 0.76, blue: 0.78)).frame(width: 128, height: 4)
        }
    }

    private func windowsLit(_ i: Int) -> some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { r in
                HStack(spacing: 2) {
                    ForEach(0..<2, id: \.self) { c in
                        Rectangle()
                            .fill(isNight && (i + r + c + tick) % 3 == 0 ? Color.yellow.opacity(0.9) : Color.clear)
                            .frame(width: 5, height: 5)
                    }
                }
            }
        }
        .padding(4)
    }

    private var shelfView: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { s in
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<7, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(shelfBook(s * 7 + i))
                            .frame(width: 8, height: [20, 26, 22, 28, 24, 21, 27][(s * 7 + i) % 7])
                    }
                }
                Rectangle().fill(OfficeTheme.wood).frame(width: 76, height: 4)
            }
        }
    }

    private func shelfBook(_ i: Int) -> Color {
        switch i % 5 {
        case 0: return Color(red: 0.75, green: 0.55, blue: 0.25)
        case 1: return Color(red: 0.3, green: 0.45, blue: 0.65)
        case 2: return Color(red: 0.6, green: 0.3, blue: 0.3)
        case 3: return Color(red: 0.4, green: 0.55, blue: 0.4)
        default: return Color(red: 0.55, green: 0.45, blue: 0.6)
        }
    }

    private var statsBoard: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let t = HistoryStore.shared.activeSecondsTotal(since: today)
        let w = HistoryStore.shared.activeSecondsTotal(since: weekAgo)
        return VStack(alignment: .leading, spacing: 2) {
            Text("✓\(doneToday)  TODAY \(shortFmt(t))").font(.notchMono(9)).foregroundStyle(.white)
            Text("WEEK \(shortFmt(w))").font(.notchMono(9)).foregroundStyle(Color.white.opacity(0.7))
            weekSpark
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.08, green: 0.1, blue: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(OfficeTheme.woodDark, lineWidth: 3))
    }

    /// Tareas terminadas hoy (transiciones a done en el historial).
    private var doneToday: Int {
        let today = Calendar.current.startOfDay(for: Date())
        return HistoryStore.shared.events.filter { $0.ts >= today && $0.status == "done" }.count
    }

    private var weekSpark: some View {
        let days = HistoryStore.shared.secondsPerDay(last: 7)
        let peak = max(days.map(\.seconds).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(days.indices.reversed(), id: \.self) { i in
                RoundedRectangle(cornerRadius: 1).fill(Color.green.opacity(0.8))
                    .frame(width: 6, height: max(2, 18 * CGFloat(days[i].seconds / peak)))
            }
        }
    }

    private var pictureView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.6, green: 0.48, blue: 0.25)).frame(width: 40, height: 50)
            RoundedRectangle(cornerRadius: 1).fill(Color(red: 0.2, green: 0.22, blue: 0.25)).frame(width: 32, height: 42)
            // Retrato abstracto estilo Mona Lisa.
            Circle().fill(Color(red: 0.8, green: 0.62, blue: 0.5)).frame(width: 12, height: 12).offset(y: -8)
            RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.25, green: 0.2, blue: 0.15)).frame(width: 20, height: 16).offset(y: 8)
        }
    }

    private var clockView: some View {
        let cal = Calendar.current
        let m = CGFloat(cal.component(.minute, from: Date()))
        let h = CGFloat(cal.component(.hour, from: Date()) % 12) + m / 60
        return ZStack {
            Circle().fill(Color.white).frame(width: 40, height: 40)
            Circle().stroke(Color.black.opacity(0.7), lineWidth: 2).frame(width: 40, height: 40)
            Rectangle().fill(Color.black).frame(width: 2, height: 10).offset(y: -5)
                .rotationEffect(.degrees(Double(h) * 30))
            Rectangle().fill(Color.black).frame(width: 2, height: 14).offset(y: -7)
                .rotationEffect(.degrees(Double(m) * 6))
            Circle().fill(Color.red).frame(width: 4, height: 4)
        }
    }

    private var kitchenette: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.85)).frame(width: 22, height: 16)
                RoundedRectangle(cornerRadius: 2).fill(OfficeTheme.mugWhite).frame(width: 8, height: 10)
                RoundedRectangle(cornerRadius: 2).fill(OfficeTheme.cushionGreen).frame(width: 8, height: 10)
            }
            RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.18, green: 0.18, blue: 0.2)).frame(width: 96, height: 30)
            HStack {
                ForEach(0..<3, id: \.self) { _ in Rectangle().fill(Color.white.opacity(0.25)).frame(width: 2, height: 10) }
                Spacer()
            }
            .frame(width: 80)
        }
    }

    // MARK: - cuerpo

    private var leftRail: some View {
        VStack(spacing: 14) {
            filingCabinet
            filingCabinet
            Spacer()
            serverRack
        }
        .padding(10)
        .frame(width: 76)
    }

    private var filingCabinet: some View {
        VStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.88, green: 0.89, blue: 0.9))
                    .frame(width: 44, height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 1).fill(Color.gray).frame(width: 12, height: 3))
            }
        }
    }

    private var serverRack: some View {
        VStack(spacing: 3) {
            ForEach(0..<8, id: \.self) { r in
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { c in
                        Circle()
                            .fill((r + c + tick) % 4 == 0 ? Color.green : Color.green.opacity(0.25))
                            .frame(width: 4, height: 4)
                    }
                    RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.15)).frame(width: 20, height: 3)
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.08, green: 0.09, blue: 0.1)))
    }

    private var desksArea: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(agents, id: \.self) { agent in
                    deskFor(agent)
                }
            }
            .padding(10)
        }
    }

    private func deskFor(_ agent: AgentID) -> some View {
        let st = status(of: agent)
        switch st {
        case .working:
            return AnyView(DeskUnit(agent: agent, screen: .code, pose: .sitting, tick: tick))
        case .waiting:
            return AnyView(DeskUnit(agent: agent, screen: .code, pose: .standing, mark: .alert, tick: tick))
        case .done where !sofaSeated(agent):
            return AnyView(DeskUnit(agent: agent, screen: .logo, pose: .sitting, mark: .check, tick: tick))
        case .done:
            return AnyView(DeskUnit(agent: agent, screen: .off, pose: .sitting, occupied: false, showPlate: true, tick: tick))
        default:
            return AnyView(DeskUnit(agent: agent, screen: .off, pose: .sitting, occupied: false, tick: tick))
        }
    }

    /// Los 3 primeros terminados, al sofá.
    private func sofaSeated(_ agent: AgentID) -> Bool {
        Array(done.prefix(3)).contains(agent)
    }

    private var lounge: some View {
        VStack(spacing: 10) {
            OfficePlant(height: 70)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(OfficeTheme.rug).frame(width: 220, height: 330)
                VStack(spacing: 8) {
                    OfficeSofa(sitters: Array(done.prefix(3)))
                    OfficeCoffeeTable()
                    HStack(spacing: 16) {
                        armchair
                        floorLamp
                        armchair
                    }
                }
            }
            OfficePlant(height: 46)
        }
        .padding(10)
        .frame(width: 250)
    }

    private var armchair: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 8).fill(OfficeTheme.cushionGreen).frame(width: 52, height: 44)
            HStack {
                Rectangle().fill(OfficeTheme.woodDark).frame(width: 5, height: 7)
                Spacer()
                Rectangle().fill(OfficeTheme.woodDark).frame(width: 5, height: 7)
            }
            .frame(width: 44)
        }
    }

    private var floorLamp: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 4).fill(OfficeTheme.cushionCream).frame(width: 26, height: 30)
                .overlay(Circle().fill(Color.yellow.opacity(isNight ? 0.35 : 0)).frame(width: 40, height: 40))
            Rectangle().fill(OfficeTheme.chairBlack).frame(width: 4, height: 52)
            Ellipse().fill(OfficeTheme.chairBlack).frame(width: 24, height: 6)
        }
    }

    private func shortFmt(_ s: TimeInterval) -> String {
        let m = Int(s) / 60
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }
}
#endif

