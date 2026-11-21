#if os(macOS)
import NotchCore
import SwiftUI

// MARK: - Oficina estilo Lumio: piezas pixel-art compartidas.
// Vista lateral, gente de espaldas (pelo + camisa del color del agente),
// iMac según estado, madera cálida, suelo de baldosas y pared oscura.
// La pestaña y la ventana grande componen con las mismas piezas.

// MARK: - Tema

enum OfficeTheme {
    static let floor = Color(red: 0.78, green: 0.74, blue: 0.66)
    static let floorLine = Color.black.opacity(0.06)
    static let wall = Color(red: 0.16, green: 0.17, blue: 0.19)
    static let wallBand = Color(red: 0.13, green: 0.14, blue: 0.16)
    static let wood = Color(red: 0.55, green: 0.38, blue: 0.22)
    static let woodDark = Color(red: 0.42, green: 0.28, blue: 0.16)
    static let woodLight = Color(red: 0.64, green: 0.46, blue: 0.28)
    static let chairBlack = Color(red: 0.12, green: 0.12, blue: 0.14)
    static let metal = Color(red: 0.55, green: 0.57, blue: 0.6)
    static let paper = Color(red: 0.93, green: 0.92, blue: 0.88)
    static let mugWhite = Color(red: 0.92, green: 0.93, blue: 0.94)
    static let screenOff = Color(red: 0.14, green: 0.15, blue: 0.18)
    static let leafGreen = Color(red: 0.35, green: 0.52, blue: 0.32)
    static let sofaGray = Color(red: 0.2, green: 0.21, blue: 0.24)
    static let cushionGreen = Color(red: 0.48, green: 0.6, blue: 0.44)
    static let cushionCream = Color(red: 0.88, green: 0.84, blue: 0.72)
    static let rug = Color(red: 0.84, green: 0.8, blue: 0.68)
    static let alertAmber = Color(red: 0.95, green: 0.62, blue: 0.1)
    static let okGreen = Color(red: 0.3, green: 0.75, blue: 0.45)

    /// Camisa del color del agente, aclarada si es demasiado oscura
    /// para verse sobre el fondo (p. ej. OpenCode es negro puro).
    static func shirt(for agent: AgentID) -> Color {
        var h = agent.notchColorHex
        if h.hasPrefix("#") { h.removeFirst() }
        let v = UInt64(h, radix: 16) ?? 0x888888
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if lum >= 0.38 { return Color(red: r, green: g, blue: b) }
        let m = 0.55
        return Color(red: r + (1 - r) * m, green: g + (1 - g) * m, blue: b + (1 - b) * m)
    }

    /// Pelo variado por agente (vista de espaldas: es su seña).
    static func hair(for agent: AgentID) -> Color {
        let palette: [Color] = [
            Color(red: 0.45, green: 0.27, blue: 0.14), // castaño
            Color(red: 0.12, green: 0.1, blue: 0.1), // negro
            Color(red: 0.75, green: 0.6, blue: 0.35), // rubio
            Color(red: 0.6, green: 0.25, blue: 0.15), // pelirrojo
            Color(red: 0.55, green: 0.55, blue: 0.58), // gris
            Color(red: 0.3, green: 0.18, blue: 0.1), // moreno
        ]
        let idx = abs(agent.rawValue.hashValue) % palette.count
        return palette[idx]
    }
}

// MARK: - Personita de espaldas

/// Trabajador visto por detrás: pelo, camisa del color del agente y
/// brazos. `pose`: sentado (teclea), de pie (te necesita) o café.
struct OfficePerson: View {
    var agent: AgentID
    var pose: Pose
    var tick: Int = 0

    enum Pose { case sitting, standing, lounging }

    var body: some View {
        let shirt = OfficeTheme.shirt(for: agent)
        let hair = OfficeTheme.hair(for: agent)
        Group {
            switch pose {
            case .sitting:
                VStack(spacing: 0) {
                    // Cabeza: pelo con escalón pixel.
                    ZStack(alignment: .top) {
                        RoundedRectangle(cornerRadius: 4).fill(hair).frame(width: 26, height: 22)
                        RoundedRectangle(cornerRadius: 2).fill(hair).frame(width: 30, height: 10).offset(y: 8)
                    }
                    // Cuello + camisa.
                    Rectangle().fill(Color(red: 0.85, green: 0.68, blue: 0.55)).frame(width: 8, height: 4)
                    HStack(spacing: 0) {
                        // Brazo izq. al teclado (teclea: sube y baja).
                        RoundedRectangle(cornerRadius: 3).fill(shirt)
                            .frame(width: 9, height: 26)
                            .offset(y: tick % 2 == 0 ? 0 : -2)
                        RoundedRectangle(cornerRadius: 4).fill(shirt).frame(width: 30, height: 32)
                        RoundedRectangle(cornerRadius: 3).fill(shirt)
                            .frame(width: 9, height: 26)
                            .offset(y: tick % 2 == 0 ? -2 : 0)
                    }
                }
            case .standing:
                VStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        RoundedRectangle(cornerRadius: 4).fill(hair).frame(width: 26, height: 22)
                        RoundedRectangle(cornerRadius: 2).fill(hair).frame(width: 30, height: 10).offset(y: 8)
                    }
                    Rectangle().fill(Color(red: 0.85, green: 0.68, blue: 0.55)).frame(width: 8, height: 4)
                    // Brazos en alto: "¡eh, mírame!".
                    HStack(spacing: 22) {
                        RoundedRectangle(cornerRadius: 3).fill(shirt).frame(width: 9, height: 30)
                            .rotationEffect(.degrees(-14))
                        RoundedRectangle(cornerRadius: 4).fill(shirt).frame(width: 30, height: 36)
                        RoundedRectangle(cornerRadius: 3).fill(shirt).frame(width: 9, height: 30)
                            .rotationEffect(.degrees(14))
                    }
                    // Piernas.
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.2, green: 0.22, blue: 0.28))
                            .frame(width: 10, height: 30)
                        RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.2, green: 0.22, blue: 0.28))
                            .frame(width: 10, height: 30)
                    }
                }
            case .lounging:
                VStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        RoundedRectangle(cornerRadius: 4).fill(hair).frame(width: 24, height: 20)
                        RoundedRectangle(cornerRadius: 2).fill(hair).frame(width: 28, height: 9).offset(y: 7)
                    }
                    RoundedRectangle(cornerRadius: 4).fill(shirt).frame(width: 34, height: 26)
                }
            }
        }
    }
}

// MARK: - iMac

/// iMac con la pantalla según el estado: código, logo, olas o apagado.
struct OfficeMac: View {
    enum Screen { case code, logo, waves, off }
    var mode: Screen
    var width: CGFloat = 92

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.82, green: 0.83, blue: 0.86))
                    .frame(width: width, height: width * 0.62)
                RoundedRectangle(cornerRadius: 2).fill(Color.black).frame(width: width - 8, height: width * 0.62 - 8)
                screenContent.frame(width: width - 8, height: width * 0.62 - 8).clipShape(RoundedRectangle(cornerRadius: 2))
            }
            Rectangle().fill(OfficeTheme.metal).frame(width: 8, height: 10)
            RoundedRectangle(cornerRadius: 2).fill(OfficeTheme.metal).frame(width: 32, height: 4)
        }
    }

    @ViewBuilder
    private var screenContent: some View {
        switch mode {
        case .off:
            OfficeTheme.screenOff
        case .logo:
            ZStack {
                Color(red: 0.88, green: 0.89, blue: 0.91)
                Circle().fill(Color(red: 0.45, green: 0.46, blue: 0.5)).frame(width: 16, height: 16)
            }
        case .waves:
            LinearGradient(
                colors: [Color(red: 0.35, green: 0.25, blue: 0.6), Color(red: 0.2, green: 0.15, blue: 0.45)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .code:
            ZStack(alignment: .topLeading) {
                Color(red: 0.09, green: 0.11, blue: 0.14)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<4, id: \.self) { i in
                        HStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 1).fill(codeColor(i)).frame(width: codeWidth(i), height: 3)
                            if i % 2 == 0 {
                                RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.5)).frame(width: 10, height: 3)
                            }
                        }
                    }
                }
                .padding(6)
            }
        }
    }

    private func codeColor(_ i: Int) -> Color {
        [.init(red: 0.49, green: 0.91, blue: 0.53), .init(red: 0.47, green: 0.75, blue: 1),
         .init(red: 1, green: 0.85, blue: 0.4), .init(red: 0.82, green: 0.66, blue: 1)][i % 4]
    }

    private func codeWidth(_ i: Int) -> CGFloat {
        [34, 48, 26, 40][i % 4]
    }
}

// MARK: - Silla

struct OfficeChair: View {
    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 6).fill(OfficeTheme.chairBlack).frame(width: 36, height: 42)
            RoundedRectangle(cornerRadius: 3).fill(OfficeTheme.chairBlack).frame(width: 40, height: 10)
            Rectangle().fill(OfficeTheme.metal).frame(width: 5, height: 14)
            // Base de 5 radios simplificada.
            ZStack {
                RoundedRectangle(cornerRadius: 2).fill(OfficeTheme.chairBlack).frame(width: 44, height: 5)
                RoundedRectangle(cornerRadius: 2).fill(OfficeTheme.chairBlack).frame(width: 5, height: 20)
            }
        }
    }
}

// MARK: - Mesa con enseres

/// Mesa de madera con iMac, teclado, lámpara, libros y taza. La `placa`
/// lleva el nombre corto del agente, como la etiqueta de Lumio.
struct OfficeDesk: View {
    var screen: OfficeMac.Screen
    var plate: String?
    var width: CGFloat = 200

    var body: some View {
        ZStack(alignment: .top) {
            // Patas.
            HStack {
                Rectangle().fill(OfficeTheme.chairBlack).frame(width: 6, height: 52)
                Spacer()
                Rectangle().fill(OfficeTheme.chairBlack).frame(width: 6, height: 52)
            }
            .frame(width: width - 12)
            .offset(y: 10)
            VStack(spacing: 0) {
                // Sobremesa.
                RoundedRectangle(cornerRadius: 3).fill(OfficeTheme.wood).frame(width: width, height: 10)
                Rectangle().fill(OfficeTheme.woodDark).frame(width: width, height: 5)
                // Enseres sobre la mesa.
                HStack(alignment: .bottom, spacing: 6) {
                    booksStack
                    lampView
                    Spacer(minLength: 0)
                    mugView
                }
                .frame(width: width - 16)
                .offset(y: -6)
            }
            // Teclado centrado bajo el iMac (lo pone DeskUnit).
            if let plate {
                Text(plate)
                    .font(.notchMono(7))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.55)))
                    .offset(y: 20)
            }
        }
        .frame(width: width, height: 76)
    }

    private var booksStack: some View {
        VStack(spacing: 1) {
            RoundedRectangle(cornerRadius: 1).fill(Color(red: 0.75, green: 0.55, blue: 0.25)).frame(width: 26, height: 6)
            RoundedRectangle(cornerRadius: 1).fill(Color(red: 0.3, green: 0.45, blue: 0.65)).frame(width: 24, height: 6)
            RoundedRectangle(cornerRadius: 1).fill(Color(red: 0.6, green: 0.3, blue: 0.3)).frame(width: 26, height: 6)
        }
    }

    private var lampView: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 1).fill(OfficeTheme.chairBlack).frame(width: 4, height: 26)
                RoundedRectangle(cornerRadius: 2).fill(OfficeTheme.chairBlack).frame(width: 16, height: 8)
                    .rotationEffect(.degrees(-24)).offset(x: 4, y: -20)
            }
            RoundedRectangle(cornerRadius: 2).fill(OfficeTheme.chairBlack).frame(width: 12, height: 4)
        }
    }

    private var mugView: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2).fill(OfficeTheme.mugWhite).frame(width: 10, height: 12)
            RoundedRectangle(cornerRadius: 1).fill(OfficeTheme.woodDark).frame(width: 10, height: 2)
        }
    }
}

// MARK: - Unidad completa: silla + persona + mesa + iMac

/// Un puesto con su agente. `mode` decide pantalla y pose.
struct DeskUnit: View {
    enum Mark { case none, alert, check }

    var agent: AgentID
    var screen: OfficeMac.Screen
    var pose: OfficePerson.Pose
    var mark: Mark = .none
    /// Sin ocupar: silla vacía y pantalla apagada.
    var occupied: Bool = true
    var showPlate: Bool = true
    var tick: Int = 0
    var width: CGFloat = 200

    var body: some View {
        ZStack(alignment: .bottom) {
            // Sombra sobre el suelo.
            Ellipse().fill(Color.black.opacity(0.25)).frame(width: width * 0.9, height: 10)
            // iMac detrás, sobre la mesa.
            OfficeMac(mode: screen, width: width * 0.46)
                .offset(y: -width * 0.36)
            // Silla + persona.
            ZStack(alignment: .bottom) {
                if pose != .lounging { OfficeChair() }
                if occupied {
                    OfficePerson(agent: agent, pose: pose, tick: tick)
                        .offset(y: pose == .standing ? -10 : -34)
                }
                if mark != .none {
                    badgeView.offset(x: 26, y: -110)
                }
            }
            .offset(y: -14)
            // Mesa delante.
            OfficeDesk(screen: screen, plate: showPlate ? shortName : nil, width: width)
        }
        .frame(width: width, height: width * 0.98)
    }

    private var shortName: String {
        String(agent.displayName.split(separator: " ").first ?? Substring(agent.displayName))
    }

    @ViewBuilder
    private var badgeView: some View {
        if mark == .alert {
            ZStack {
                Circle().fill(OfficeTheme.alertAmber).frame(width: 18, height: 18)
                Text("!").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
            }
        } else {
            ZStack {
                Circle().fill(OfficeTheme.okGreen).frame(width: 18, height: 18)
                Text("✓").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
            }
        }
    }
}

// MARK: - Suelo de baldosas (ventana grande)

/// Baldosas claras con juntas sutiles, como la oficina de Lumio.
struct OfficeFloorGrid: View {
    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(OfficeTheme.floor))
                let step: CGFloat = 46
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += step
                }
                var y: CGFloat = 0
                while y <= size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += step
                }
                ctx.stroke(path, with: .color(OfficeTheme.floorLine), lineWidth: 1)
            }
        }
    }
}



struct OfficePlant: View {
    var height: CGFloat = 60
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Ellipse().fill(OfficeTheme.leafGreen).frame(width: 34, height: 22)
                Ellipse().fill(OfficeTheme.leafGreen.opacity(0.85)).frame(width: 22, height: 30).offset(y: -12)
                Ellipse().fill(Color(red: 0.42, green: 0.6, blue: 0.38)).frame(width: 26, height: 18).offset(x: -10, y: -4)
            }
            RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.6, green: 0.6, blue: 0.62))
                .frame(width: 24, height: height * 0.3)
        }
        .frame(height: height)
    }
}

struct OfficeSofa: View {
    /// Agentes tomando café (hasta 3 sentados).
    var sitters: [AgentID] = []
    var body: some View {
        ZStack(alignment: .top) {
            // Respaldo.
            RoundedRectangle(cornerRadius: 8).fill(OfficeTheme.sofaGray).frame(width: 170, height: 52)
            // Sentados asomando.
            HStack(spacing: 14) {
                ForEach(sitters.prefix(3), id: \.self) { a in
                    OfficePerson(agent: a, pose: .lounging)
                }
            }
            .offset(y: -22)
            // Cojines y base.
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6).fill(OfficeTheme.cushionGreen).frame(width: 34, height: 30)
                RoundedRectangle(cornerRadius: 6).fill(OfficeTheme.cushionCream).frame(width: 34, height: 30)
                RoundedRectangle(cornerRadius: 6).fill(OfficeTheme.sofaGray).frame(width: 34, height: 30)
            }
            .offset(y: 22)
            RoundedRectangle(cornerRadius: 8).fill(OfficeTheme.sofaGray).frame(width: 170, height: 26).offset(y: 52)
            // Patas.
            HStack {
                Rectangle().fill(OfficeTheme.woodDark).frame(width: 6, height: 8)
                Spacer()
                Rectangle().fill(OfficeTheme.woodDark).frame(width: 6, height: 8)
            }
            .frame(width: 150).offset(y: 78)
        }
        .frame(width: 170, height: 108)
    }
}

struct OfficeCoffeeTable: View {
    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3).fill(OfficeTheme.wood).frame(width: 120, height: 9)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(OfficeTheme.mugWhite).frame(width: 9, height: 10)
                RoundedRectangle(cornerRadius: 1).fill(OfficeTheme.paper).frame(width: 26, height: 16)
                    .rotationEffect(.degrees(-6))
                RoundedRectangle(cornerRadius: 2).fill(OfficeTheme.cushionGreen).frame(width: 12, height: 8)
            }
            .offset(y: -16)
            HStack {
                Rectangle().fill(OfficeTheme.woodDark).frame(width: 6, height: 20)
                Spacer()
                Rectangle().fill(OfficeTheme.woodDark).frame(width: 6, height: 20)
            }
            .frame(width: 100)
        }
        .frame(width: 120, height: 48)
    }
}
#endif
