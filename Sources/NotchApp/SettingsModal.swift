#if os(macOS)
import AppKit
import NotchCore
import SwiftUI

/// Modal de ajustes: ventana aparte (no tapa el notch) con secciones
/// de color, navbar, comportamiento y privacidad. Estilo Lumio: vidrio
/// oscuro, filos redondeados, tipografía mono en los rótulos.
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = SettingsModalView()
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = true
            w.contentView = NSHostingView(
                rootView: view.environment(\.colorScheme, .dark)
            )
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }
}

struct SettingsModalView: View {
    @ObservedObject var settings = NotchSettings.shared
    @State private var hoverOpen = UserDefaults.standard.object(forKey: "notchHoverOpen") as? Bool ?? true
    @State private var autoSend = ReplyService.shared.autoSendEnabled
    @State private var trustState = ReplyService.shared.isTrusted
    @State private var vaultPath: String = UserDefaults.standard.string(forKey: "notchObsidianVault") ?? ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    colorSection
                    navbarSection
                    behaviorSection
                    privacySection
                }
                .padding(18)
            }
        }
        .frame(width: 460, height: 560)
        .background(SettingsCardBackground())
    }

    // MARK: - Cabecera

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(settings.accent).frame(width: 10, height: 10)
            Text("ajustes de notch")
                .font(.notchMono(13))
                .foregroundStyle(.white)
            Spacer()
            Button {
                SettingsWindowController.shared.hide()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Color

    private var colorSection: some View {
        SettingsSection(title: "color") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(Self.palette, id: \.self) { hex in
                        Button {
                            settings.accentHex = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 22, height: 22)
                                .overlay {
                                    if settings.accentHex.uppercased() == hex {
                                        Circle().stroke(.white, lineWidth: 2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                    ColorPicker("Personalizado", selection: Binding(
                        get: { Color(hex: settings.accentHex) },
                        set: { settings.accentHex = $0.hexString }
                    ))
                    .labelsHidden()
                    .frame(width: 30)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("opacidad del panel  \(Int(settings.panelOpacity * 100))%")
                        .font(.notchMono(10))
                        .foregroundStyle(Color.white.opacity(0.6))
                    Slider(value: $settings.panelOpacity, in: 0.55...0.95, step: 0.05)
                        .tint(settings.accent)
                }
            }
        }
    }

    // MARK: - Navbar

    private var navbarSection: some View {
        SettingsSection(title: "navbar") {
            VStack(spacing: 6) {
                ForEach(settings.tabOrder, id: \.self) { title in
                    HStack(spacing: 8) {
                        Image(systemName: iconName(for: title))
                            .font(.system(size: 11))
                            .frame(width: 18)
                            .foregroundStyle(
                                settings.hiddenTabs.contains(title)
                                    ? Color.white.opacity(0.3)
                                    : settings.accent
                            )
                        Text(title)
                            .font(.system(size: 12))
                            .foregroundStyle(
                                settings.hiddenTabs.contains(title)
                                    ? Color.white.opacity(0.35)
                                    : Color.white.opacity(0.85)
                            )
                            .strikethrough(settings.hiddenTabs.contains(title))
                        Spacer()
                        Button {
                            settings.move(title, by: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.white.opacity(0.5))
                        .disabled(settings.tabOrder.first == title)
                        Button {
                            settings.move(title, by: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.white.opacity(0.5))
                        .disabled(settings.tabOrder.last == title)
                        Toggle("", isOn: Binding(
                            get: { !settings.hiddenTabs.contains(title) },
                            set: { settings.setVisible(title, $0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .tint(settings.accent)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
                }
            }
        }
    }

    // MARK: - Comportamiento

    private var behaviorSection: some View {
        SettingsSection(title: "comportamiento") {
            VStack(alignment: .leading, spacing: 8) {
                SettingsToggleRow(
                    label: "Abrir al pasar el ratón por el notch",
                    isOn: $hoverOpen,
                    accent: settings.accent
                ) {
                    UserDefaults.standard.set(hoverOpen, forKey: "notchHoverOpen")
                }
                SettingsToggleRow(
                    label: "Auto-send en Claude (Accessibility)",
                    isOn: $autoSend,
                    accent: settings.accent
                ) {
                    if autoSend, !ReplyService.shared.isTrusted {
                        ReplyService.shared.requestTrust()
                    }
                    ReplyService.shared.autoSendEnabled = autoSend
                    trustState = ReplyService.shared.isTrusted
                }
                Text(trustState ? "Accesibilidad: concedida ✓" : "Accesibilidad: pendiente (solo si activas auto-send)")
                    .font(.notchMono(9))
                    .foregroundStyle(Color.white.opacity(0.45))
                TextField("Obsidian vault (dev log)", text: $vaultPath, onCommit: {
                    UserDefaults.standard.set(vaultPath, forKey: "notchObsidianVault")
                })
                .textFieldStyle(.roundedBorder)
                .font(.notchMono(11))
            }
        }
    }

    // MARK: - Privacidad

    private var privacySection: some View {
        SettingsSection(title: "privacidad") {
            Text("Todo queda en tu Mac. Sin cuentas, sin tracking, sin Screen Recording. El historial vive en ~/Library/Application Support/NOTCH.")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static let palette = ["A550A7", "7C5CFF", "2F9E6E", "D9A514", "E0574B", "3E8BD8"]

    private func iconName(for title: String) -> String {
        switch title {
        case "Shelf": return "tray"
        case "Focus": return "timer"
        case "Mac": return "cpu"
        case "Actividad": return "chart.bar"
        case "Música": return "music.note"
        case "Notas": return "note.text"
        default: return "gearshape"
        }
    }
}

// MARK: - Piezas

/// Tarjeta de sección: rótulo mono + fondo sutil.
private struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.notchMono(11))
                .foregroundStyle(Color.white.opacity(0.5))
                .kerning(1.5)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsToggleRow: View {
    var label: String
    @Binding var isOn: Bool
    var accent: Color
    var onChange: () -> Void

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.85))
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(accent)
                .onChange(of: isOn) { _ in onChange() }
        }
    }
}

private struct SettingsCardBackground: View {
    var body: some View {
        ZStack {
            UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 12, bottomLeading: 18, bottomTrailing: 18, topTrailing: 12),
                style: .continuous
            )
            .fill(.ultraThinMaterial)
            UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 12, bottomLeading: 18, bottomTrailing: 18, topTrailing: 12),
                style: .continuous
            )
            .fill(Color.black.opacity(0.82))
        }
        .overlay(
            UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 12, bottomLeading: 18, bottomTrailing: 18, topTrailing: 12),
                style: .continuous
            )
            .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .ignoresSafeArea()
    }
}

extension Color {
    /// Convierte a #RRGGBB para persistir en ajustes.
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(
            format: "%02X%02X%02X",
            Int(round(c.redComponent * 255)),
            Int(round(c.greenComponent * 255)),
            Int(round(c.blueComponent * 255))
        )
    }
}
#endif
