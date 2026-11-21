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

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let sel = selection == value
                Button(label) {
                    withAnimation(.snappy(duration: 0.18)) { selection = value }
                }
                .font(.system(size: 11, weight: sel ? .semibold : .regular))
                .foregroundStyle(sel ? color : Color.white.opacity(0.6))
                .padding(.horizontal, 10).padding(.vertical, 5)
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
#endif
