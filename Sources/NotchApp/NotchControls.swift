#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Controles propios de NOTCH (100% personalizados)
//
// Botones, interruptores, selectores y steppers con el lenguaje de
// NOTCH: vidrio oscuro, esquinas continuas, acento del usuario y
// micro-interacciones (escala al pulsar, fundidos). Nada de
// .bordered / .switch / .segmented del sistema.

/// Tamaño de control propio (sustituye a controlSize en estos estilos).
enum NotchControlSize {
    case small, mini

    var fontSize: CGFloat { self == .mini ? 11 : 12 }
    var hPad: CGFloat { self == .mini ? 9 : 12 }
    var vPad: CGFloat { self == .mini ? 4 : 6 }
    var radius: CGFloat { self == .mini ? 7 : 9 }
}

// MARK: - Botones

/// Botón principal: relleno con degradado del color + brillo.
/// Respeta `role == .destructive` (usa rojo).
struct NotchPrimaryButton: ButtonStyle {
    var size: NotchControlSize = .small
    var color: Color = NotchSettings.shared.accent

    func makeBody(configuration: Configuration) -> some View {
        let base = configuration.role == .destructive ? Color(hex: "E0574B") : color
        configuration.label
            .font(.system(size: size.fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, size.hPad).padding(.vertical, size.vPad)
            .background(
                RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                    .fill(LinearGradient(
                        colors: [base, base.opacity(0.72)],
                        startPoint: .top, endPoint: .bottom
                    ))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                    .stroke(.white.opacity(configuration.isPressed ? 0.05 : 0.22), lineWidth: 1)
            )
            .shadow(color: base.opacity(configuration.isPressed ? 0.1 : 0.35),
                    radius: configuration.isPressed ? 2 : 7, y: configuration.isPressed ? 0 : 2)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Botón secundario: vidrio sutil con filo. `tint` tiñe texto y filo.
struct NotchGhostButton: ButtonStyle {
    var size: NotchControlSize = .small
    var tint: Color = Color.white.opacity(0.85)

    func makeBody(configuration: Configuration) -> some View {
        let hot = configuration.role == .destructive
        let fg = hot ? Color(hex: "E0574B") : tint
        configuration.label
            .font(.system(size: size.fontSize, weight: .medium))
            .foregroundStyle(fg.opacity(configuration.isPressed ? 0.7 : 1))
            .padding(.horizontal, size.hPad).padding(.vertical, size.vPad)
            .background(
                RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.1 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                    .stroke(fg.opacity(configuration.isPressed ? 0.25 : 0.14), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Interruptor

/// Switch propio: píldora con pomo deslizante y glow del color.
struct NotchToggleStyle: ToggleStyle {
    var color: Color = NotchSettings.shared.accent
    var mini = false

    func makeBody(configuration: Configuration) -> some View {
        let w: CGFloat = mini ? 30 : 36
        let h: CGFloat = mini ? 18 : 21
        HStack(spacing: 7) {
            configuration.label
            Button {
                withAnimation(.snappy(duration: 0.2)) { configuration.isOn.toggle() }
            } label: {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn
                              ? LinearGradient(colors: [color, color.opacity(0.7)],
                                               startPoint: .leading, endPoint: .trailing)
                              : LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.14)],
                                               startPoint: .leading, endPoint: .trailing))
                        .frame(width: w, height: h)
                        .shadow(color: configuration.isOn ? color.opacity(0.45) : .clear, radius: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: h - 5, height: h - 5)
                        .padding(2.5)
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Selector segmentado

/// Segmentos propios (sustituye a pickerStyle(.segmented)).
struct NotchSegments<V: Hashable>: View {
    @Binding var selection: V
    var options: [(V, String)]
    var color: Color = NotchSettings.shared.accent
    var disabledAll = false
    /// Ocupa todo el ancho disponible (segmentos equitativos).
    var fill = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                segment(value, label)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
        .opacity(disabledAll ? 0.55 : 1)
    }

    /// Un segmento. Vive fuera del body: el type-checker de CI (CI
    /// con Xcode26) se ahogaba con la cadena completa anidada en el
    /// ForEach genérico («unable to type-check in reasonable time»).
    private func segment(_ value: V, _ label: String) -> some View {
        let sel = selection == value
        return Button(label) {
            withAnimation(.snappy(duration: 0.18)) { selection = value }
        }
        .font(.system(size: 11, weight: sel ? .semibold : .regular))
        .foregroundStyle(sel ? color : Color.white.opacity(0.6))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(maxWidth: fill ? .infinity : nil)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(sel ? color.opacity(0.2) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(sel ? color.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .buttonStyle(.plain)
        .disabled(disabledAll)
    }
}

// MARK: - Stepper

/// Stepper propio: − valor + con botones fantasma.
struct NotchStepper: View {
    var label: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int = 1
    var color: Color = NotchSettings.shared.accent
    var suffix: String = ""

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.85))
            Spacer()
            Button { value = max(range.lowerBound, value - step) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(NotchGhostButton(size: .mini, tint: color))
            .disabled(value <= range.lowerBound)
            Text("\(value)\(suffix)")
                .font(.notchMono(12))
                .foregroundStyle(color)
                .monospacedDigit()
                .frame(minWidth: 40)
            Button { value = min(range.upperBound, value + step) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(NotchGhostButton(size: .mini, tint: color))
            .disabled(value > range.upperBound)
        }
        .padding(.vertical, 2)
    }
}
// MARK: - Campo de texto propio

/// Input estilo command-palette (Raycast): icono, placeholder, foco con
/// filo de acento, botón de limpiar y pista de tecla. Sustituye a todos
/// los `.roundedBorder` de la app.
struct NotchTextField: View {
    var placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var hint: String? = nil
    var color: Color = NotchSettings.shared.accent
    var font: Font = .system(size: 13)
    var onCommit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(focused ? color : Color.white.opacity(0.45))
                    .frame(width: 20)
            }
            TextField(placeholder, text: $text, onCommit: onCommit)
                .textFieldStyle(.plain)
                .font(font)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            } else if let hint {
                Text(hint)
                    .font(.notchMono(10))
                    .foregroundStyle(Color.white.opacity(0.3))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(focused ? 0.07 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(focused ? color.opacity(0.55) : Color.white.opacity(0.09), lineWidth: focused ? 1.5 : 1)
        )
        .animation(.snappy(duration: 0.18), value: focused)
    }
}

// MARK: - Tarjeta y rótulos compartidos

/// Tarjeta base del panel: vidrio con degradado sutil (más luminoso
/// arriba), filo en degradado y sombra suave. Unifica todas las
/// pestañas bajo el mismo material.
struct NotchCard<Content: View>: View {
    /// Tinte sutil del acento en la cabecera (para tarjetas "hero").
    var accent: Color? = nil
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        // OJO: el contenido debe llegar como UNA vista. Si el
        // @ViewBuilder tiene varios hijos (TupleView) directamente aquí,
        // SwiftUI aplica estos modificadores POR HIJO y cada uno dibujaría
        // su propia tarjeta (tarjeta partida). Los call sites envuelven su
        // contenido en un VStack; este contenedor solo aporta spacing.
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: accent.map {
                                [$0.opacity(0.10), Color.white.opacity(0.035)]
                            } ?? [Color.white.opacity(0.058), Color.white.opacity(0.028)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.13), Color.white.opacity(0.055)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .liquidGlass(NotchSettings.shared.liquidGlass, radius: 13)
            .shadow(color: .black.opacity(0.20), radius: 10, y: 5)
    }
}

// MARK: - Liquid Glass

/// Fondo de vidrio REAL de Apple: `NSGlassEffectView` (macOS26+)
/// refracta de verdad lo que hay detrás de la ventana — lo renderiza
/// el sistema, sin diseño nuestro. En macOS14/15 instala un
/// NSVisualEffectView equivalente al material de siempre. La máscara
/// da la forma exacta (esquinas superiores rectas, radios
/// irregulares…). Solo hace falta en fondos grandes (panel,
/// Ajustes); las tarjetas usan el modificador .glassEffect.
struct AppleGlassBase: NSViewRepresentable {
    var radius: CGFloat = 0
    /// El panel cuelga del notch: esquinas superiores rectas.
    var topFlat = false
    /// (topLeading, bottomLeading, bottomTrailing, topTrailing).
    var radii: (CGFloat, CGFloat, CGFloat, CGFloat)? = nil

    func makeNSView(context: Context) -> GlassCanvas {
        let v = GlassCanvas()
        v.radius = radius
        v.topFlat = topFlat
        v.radii = radii
        v.install()
        return v
    }

    func updateNSView(_ v: GlassCanvas, context: Context) {
        v.radius = radius
        v.topFlat = topFlat
        v.radii = radii
        v.needsLayout = true
    }

    final class GlassCanvas: NSView {
        var radius: CGFloat = 0
        var topFlat = false
        var radii: (CGFloat, CGFloat, CGFloat, CGFloat)?
        private var installed = false

        func install() {
            guard !installed else { return }
            installed = true
            let inner: NSView
            if #available(macOS 26.0, *) {
                let g = NSGlassEffectView()
                g.style = .regular
                g.contentView = nil
                inner = g
            } else {
                let v = NSVisualEffectView()
                v.material = .hudWindow
                v.blendingMode = .behindWindow
                v.state = .active
                inner = v
            }
            inner.frame = bounds
            inner.autoresizingMask = [.width, .height]
            addSubview(inner)
        }

        override func layout() {
            super.layout()
            let r = CGRect(origin: .zero, size: bounds.size)
            guard r.width > 1, r.height > 1 else { return }
            let p: Path
            if let q = radii {
                p = UnevenRoundedRectangle(
                    cornerRadii: .init(topLeading: q.0, bottomLeading: q.1,
                                       bottomTrailing: q.2, topTrailing: q.3),
                    style: .continuous).path(in: r)
            } else if topFlat {
                p = UnevenRoundedRectangle(
                    cornerRadii: .init(topLeading: 0, bottomLeading: radius,
                                       bottomTrailing: radius, topTrailing: 0),
                    style: .continuous).path(in: r)
            } else {
                p = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: r)
            }
            let mask = CAShapeLayer()
            mask.path = p.cgPath
            layer?.mask = mask
        }
    }
}

/// Capas de brillo «Liquid Glass» con DISTORSIÓN simulada: la luz
/// del filo se retuerce en onda viva (como vidrio líquido) y el
/// borde dispersa en prisma (franjas roja/cian desplazadas).
///
/// Honesty: la refracción REAL del fondo (torcer lo que hay detrás)
/// exige .glassEffect de macOS26 o capturar el escritorio, y eso
/// último sería Grabación de pantalla (no usada en NOTCH). Aquí la
/// distorsión se simula sobre nuestras capas, y la translucidez del
/// fondo es de verdad: el material (blur del escritorio) se ve
/// moverse detrás del vidrio.
private struct GlassLayers<S: Shape>: View {
    var shape: S

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 10.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                //1) Luz de estudio diagonal (brillo base).
                shape.fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.13), .clear, Color.white.opacity(0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                //2) Menisco con ONDA VIVA: la banda de luz del filo
                //    se ondula en bucle (dos ecos en fase opuesta),
                //    recortada a la forma del vidrio.
                Canvas { ctx, size in
                    let rect = CGRect(origin: .zero, size: size)
                    ctx.clip(to: shape.path(in: rect))
                    for (phase, alpha) in [(0.0, 0.28), (Double.pi, 0.13)] {
                        var wave = Path()
                        wave.move(to: CGPoint(x: 0, y: 0))
                        let steps = 44
                        for i in 0...steps {
                            let x = size.width * CGFloat(i) / CGFloat(steps)
                            let y = CGFloat(5) + CGFloat(sin(Double(x) * 0.05 + t * 1.7 + phase)) * 2.4
                            wave.addLine(to: CGPoint(x: x, y: max(0, y)))
                        }
                        wave.addLine(to: CGPoint(x: size.width, y: 0))
                        wave.closeSubpath()
                        ctx.fill(
                            wave,
                            with: .linearGradient(
                                Gradient(colors: [Color.white.opacity(alpha),
                                                  Color.white.opacity(alpha * 0.25),
                                                  .clear]),
                                startPoint: .zero,
                                endPoint: CGPoint(x: 0, y: 15)
                            )
                        )
                    }
                }
                //3) PRISMA: el filo dispersa la luz en franjas
                //    cromáticas desplazadas (roja abajo-dcha, cian
                //    arriba-izda) + el filo blanco marcado.
                ZStack {
                    shape.stroke(Color.red.opacity(0.14), lineWidth: 1)
                        .offset(x: 0.8, y: 0.8)
                    shape.stroke(Color.cyan.opacity(0.16), lineWidth: 1)
                        .offset(x: -0.8, y: -0.8)
                    shape.stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.38), Color.white.opacity(0.10)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                }
                .clipShape(shape)
            }
            .clipShape(shape)
            .allowsHitTesting(false)
        }
    }
}

/// Modificador de vidrio. En macOS26+ usa el Liquid Glass REAL de
/// Apple (`.glassEffect(in:)`: el sistema dibuja brillos y refracta
/// el fondo — sin nada diseñado por nosotros). En macOS14/15 cae en
/// nuestra simulación (GlassLayers: onda + prisma).
struct LiquidGlassStyle: ViewModifier {
    var on: Bool
    var radius: CGFloat = 13
    /// El panel cuelga del notch: esquinas superiores rectas.
    var topFlat = false
    /// Radios personalizados (topLeading, bottomLeading, bottomTrailing,
    /// topTrailing) para superficies irregulares (la ventana de Ajustes).
    var radii: (CGFloat, CGFloat, CGFloat, CGFloat)?

    func body(content: Content) -> some View {
        if on {
            if #available(macOS 26.0, *) {
                // Vidrio de Apple: lo renderiza el sistema con
                // refracción real del fondo (macOS26+).
                if let r = radii {
                    content.glassEffect(in: UnevenRoundedRectangle(
                        cornerRadii: .init(topLeading: r.0, bottomLeading: r.1,
                                           bottomTrailing: r.2, topTrailing: r.3),
                        style: .continuous
                    ))
                } else if topFlat {
                    content.glassEffect(in: UnevenRoundedRectangle(
                        cornerRadii: .init(topLeading: 0, bottomLeading: radius,
                                           bottomTrailing: radius, topTrailing: 0),
                        style: .continuous
                    ))
                } else {
                    content.glassEffect(in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                }
            } else {
                // Fallback macOS14/15: nuestra simulación.
                content.overlay {
                    if let r = radii {
                        GlassLayers(shape: UnevenRoundedRectangle(
                            cornerRadii: .init(topLeading: r.0, bottomLeading: r.1,
                                               bottomTrailing: r.2, topTrailing: r.3),
                            style: .continuous
                        ))
                    } else if topFlat {
                        GlassLayers(shape: UnevenRoundedRectangle(
                            cornerRadii: .init(topLeading: 0, bottomLeading: radius,
                                               bottomTrailing: radius, topTrailing: 0),
                            style: .continuous
                        ))
                    } else {
                        GlassLayers(shape: RoundedRectangle(cornerRadius: radius, style: .continuous))
                    }
                }
            }
        } else {
            content
        }
    }
}

extension View {
    /// Activa el brillo Liquid Glass (Apariencia → Liquid Glass).
    func liquidGlass(_ on: Bool, radius: CGFloat = 13, topFlat: Bool = false,
                     radii: (CGFloat, CGFloat, CGFloat, CGFloat)? = nil) -> some View {
        modifier(LiquidGlassStyle(on: on, radius: radius, topFlat: topFlat, radii: radii))
    }
}

/// Rótulo de sección: chip de icono + texto mono con tracking y
/// contenido a la derecha opcional (recuento, estado…).
struct NotchTag: View {
    var icon: String
    var text: String
    var color: Color = .white
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(color.opacity(0.16))
                )
            Text(text.uppercased())
                .font(.notchMono(10))
                .foregroundStyle(Color.white.opacity(0.6))
                .kerning(1.2)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.notchMono(10))
                    .foregroundStyle(Color.white.opacity(0.38))
                    .monospacedDigit()
            }
        }
    }
}
#endif
