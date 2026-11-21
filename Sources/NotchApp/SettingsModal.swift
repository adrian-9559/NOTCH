#if os(macOS)
import AppKit
import NotchCore
import SwiftUI

/// Modal de ajustes rediseñado: ventana lateral (sidebar + contenido),
/// estilo macOS Ajustes con acento de NOTCH. Todo se aplica al instante.
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = SettingsModalView()
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
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

/// Páginas del sidebar.
private enum SettingsPage: String, CaseIterable, Identifiable {
    case appearance, tabs, behavior, music, data, language, about
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appearance: return "paintpalette.fill"
        case .tabs: return "menubar.rectangle"
        case .behavior: return "cursorarrow.click.2"
        case .music: return "music.note"
        case .data: return "externaldrive.fill"
        case .language: return "globe"
        case .about: return "lock.fill"
        }
    }

    var titleKey: String {
        switch self {
        case .appearance: return "set.color"
        case .tabs: return "set.navbar"
        case .behavior: return "set.behavior"
        case .music: return "set.music"
        case .data: return "set.data"
        case .language: return "set.language"
        case .about: return "set.privacy"
        }
    }
}

struct SettingsModalView: View {
    @ObservedObject var settings = NotchSettings.shared
    @State private var page: SettingsPage = .appearance
    @State private var hoverOpen = UserDefaults.standard.object(forKey: "notchHoverOpen") as? Bool ?? true
    @State private var autoSend = ReplyService.shared.autoSendEnabled
    @State private var trustState = ReplyService.shared.isTrusted
    @State private var vaultPath: String = UserDefaults.standard.string(forKey: "notchObsidianVault") ?? ""
    @State private var launchLogin = false
    @State private var storageSize = "—"

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            content
        }
        .frame(width: 700, height: 560)
        .background(SettingsCardBackground())
        .onAppear {
            launchLogin = LaunchAtLogin.isEnabled()
            refreshStorageSize()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(settings.accent.opacity(0.22))
                        .frame(width: 32, height: 32)
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(settings.accent)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("NOTCH")
                        .font(.notchMono(13))
                        .foregroundStyle(.white)
                    Text(tr("set.subtitle"))
                        .font(.notchMono(8))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ForEach(SettingsPage.allCases) { p in
                Button {
                    page = p
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: p.icon)
                            .font(.system(size: 12))
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(page == p ? settings.accent.opacity(0.25) : Color.white.opacity(0.07))
                            )
                            .foregroundStyle(page == p ? settings.accent : Color.white.opacity(0.6))
                        Text(tr(p.titleKey).capitalized)
                            .font(.system(size: 12, weight: page == p ? .semibold : .regular))
                            .foregroundStyle(page == p ? .white : Color.white.opacity(0.7))
                        Spacer()
                        if p == .tabs {
                            Text("\(settings.visibleOrder.count)")
                                .font(.notchMono(9))
                                .foregroundStyle(Color.white.opacity(0.55))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.white.opacity(0.1)))
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(page == p ? Color.white.opacity(0.09) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text(tr("set.local"))
                    .font(.notchMono(8))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(width: 212)
    }

    // MARK: - Contenido

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr(page.titleKey))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                    Text(pageSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                Spacer()
                Button {
                    SettingsWindowController.shared.hide()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch page {
                    case .appearance: appearancePage
                    case .tabs: tabsPage
                    case .behavior: behaviorPage
                    case .music: musicPage
                    case .data: dataPage
                    case .language: languagePage
                    case .about: aboutPage
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    private var pageSubtitle: String {
        switch page {
        case .tabs: return "\(settings.visibleOrder.count) / \(settings.tabOrder.count)"
        case .language: return tr("set.languageSub")
        case .about: return tr("set.local")
        default: return tr("set.subtitle")
        }
    }

    // MARK: - Apariencia

    private var appearancePage: some View {
        VStack(spacing: 12) {
            SettingsCard(label: tr("set.color"), icon: "paintpalette.fill", accent: settings.accent) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 10) {
                    ForEach(Self.palette, id: \.self) { hex in
                        let sel = settings.accentHex.uppercased() == hex
                        Button {
                            settings.accentHex = hex
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 34, height: 34)
                                    .shadow(color: sel ? Color(hex: hex).opacity(0.7) : .clear, radius: sel ? 8 : 0)
                                if sel {
                                    Circle().stroke(.white, lineWidth: 2).frame(width: 34, height: 34)
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 10) {
                    ZStack {
                        ColorPicker("", selection: Binding(
                            get: { Color(hex: settings.accentHex) },
                            set: { settings.accentHex = $0.hexString }
                        ))
                        .labelsHidden()
                        .frame(width: 34, height: 34)
                        .opacity(0.02)
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.white.opacity(0.5))
                            .allowsHitTesting(false)
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("#" + settings.accentHex.uppercased())
                            .font(.notchMono(12)).foregroundStyle(.white).monospacedDigit()
                        Text(tr("set.color"))
                            .font(.caption2).foregroundStyle(Color.white.opacity(0.4))
                    }
                    Spacer()
                    // Mini-preview del notch con el acento.
                    HStack(spacing: 4) {
                        Circle().fill(settings.accent).frame(width: 8, height: 8)
                        RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.25)).frame(width: 34, height: 6)
                        RoundedRectangle(cornerRadius: 3).fill(settings.accent.opacity(0.7)).frame(width: 20, height: 6)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.5)).stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
                .padding(.top, 2)
            }
            SettingsCard(label: tr("set.opacity"), icon: "circle.lefthalf.filled", accent: settings.accent) {
                HStack {
                    Text("\(Int(settings.panelOpacity * 100))%")
                        .font(.notchMono(16)).foregroundStyle(settings.accent).monospacedDigit()
                        .frame(width: 56, alignment: .leading)
                    Slider(value: $settings.panelOpacity, in: 0.55...0.95, step: 0.01)
                        .tint(settings.accent)
                }
                HStack(spacing: 6) {
                    ForEach(opacityPresets, id: \.self) { v in
                        PresetPill(label: opacityLabel(v), selected: isOpacityPreset(v), accent: settings.accent) {
                            settings.panelOpacity = v
                        }
                    }
                    Spacer()
                    // Barra que simula el fondo del panel.
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black.opacity(settings.panelOpacity))
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        .frame(width: 90, height: 18)
                        .overlay(Text("abc").font(.notchMono(8)).foregroundStyle(.white.opacity(0.8)))
                }
            }
        }
    }

    // MARK: - Pestañas

    private var tabsPage: some View {
        SettingsCard(label: tabsProgressLabel, icon: "menubar.rectangle", accent: settings.accent) {
            VStack(spacing: 6) {
                // Progreso de visibles.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1)).frame(height: 5)
                        Capsule().fill(settings.accent)
                            .frame(width: geo.size.width * tabsFraction, height: 5)
                    }
                }
                .frame(height: 5)
                .padding(.bottom, 4)
                ForEach(settings.tabOrder, id: \.self) { id in
                    let visible = !settings.hiddenTabs.contains(id)
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(visible ? settings.accent.opacity(0.2) : Color.white.opacity(0.06))
                                .frame(width: 28, height: 28)
                            Image(systemName: NotchTab(rawValue: id)?.icon ?? "gearshape")
                                .font(.system(size: 12))
                                .foregroundStyle(visible ? settings.accent : Color.white.opacity(0.3))
                        }
                        Text(NotchTab(rawValue: id)?.title ?? id)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(visible ? Color.white.opacity(0.9) : Color.white.opacity(0.35))
                            .strikethrough(!visible)
                        Spacer()
                        Button {
                            settings.move(id, by: -1)
                        } label: {
                            Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.white.opacity(0.5))
                        .disabled(settings.tabOrder.first == id)
                        Button {
                            settings.move(id, by: 1)
                        } label: {
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.white.opacity(0.5))
                        .disabled(settings.tabOrder.last == id)
                        Toggle("", isOn: Binding(
                            get: { visible },
                            set: { settings.setVisible(id, $0) }
                        ))
                        .toggleStyle(NotchToggleStyle(color: settings.accent, mini: true))
                        .labelsHidden()
                    }
                    .padding(.vertical, 5).padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(visible ? 0.05 : 0.02)))
                }
            }
        }
    }

    // MARK: - Comportamiento

    private var behaviorPage: some View {
        VStack(spacing: 12) {
            SettingsCard(label: tr("set.behavior"), icon: "cursorarrow.click.2", accent: settings.accent) {
                VStack(spacing: 2) {
                    IconToggleRow(icon: "cursorarrow.motionlines", label: tr("set.hover"), subtitle: tr("set.hoverSub"), isOn: $hoverOpen, accent: settings.accent) {
                        UserDefaults.standard.set(hoverOpen, forKey: "notchHoverOpen")
                    }
                    Divider().background(Color.white.opacity(0.07))
                    IconToggleRow(icon: "power", label: tr("set.login"), subtitle: tr("set.loginSub"), isOn: $launchLogin, accent: settings.accent) {
                        LaunchAtLogin.set(launchLogin)
                        launchLogin = LaunchAtLogin.isEnabled()
                    }
                }
            }
            SettingsCard(label: tr("set.autosend"), icon: "paperplane.fill", accent: settings.accent) {
                VStack(spacing: 6) {
                    IconToggleRow(icon: "bolt.fill", label: tr("set.autosend"), subtitle: tr("set.autosendSub"), isOn: $autoSend, accent: settings.accent) {
                        if autoSend, !ReplyService.shared.isTrusted {
                            ReplyService.shared.requestTrust()
                        }
                        ReplyService.shared.autoSendEnabled = autoSend
                        trustState = ReplyService.shared.isTrusted
                    }
                    HStack {
                        Circle().fill(trustState ? Color.green : Color.orange).frame(width: 7, height: 7)
                        Text(trustState ? tr("set.trustOk") : tr("set.trustPending"))
                            .font(.notchMono(9)).foregroundStyle(Color.white.opacity(0.5))
                        Spacer()
                    }
                    Divider().background(Color.white.opacity(0.07))
                    IconToggleRow(icon: "checklist", label: tr("set.taskAuto"), subtitle: tr("set.taskAutoSub"), isOn: $settings.autoSendTasks, accent: settings.accent) {}
                }
            }
            SettingsCard(label: tr("set.songToast"), icon: "bell.fill", accent: settings.accent) {
                VStack(spacing: 2) {
                    IconToggleRow(icon: "music.note", label: tr("set.songToast"), subtitle: tr("set.songToastSub"), isOn: $settings.songToastEnabled, accent: settings.accent) {}
                    Divider().background(Color.white.opacity(0.07))
                    IconToggleRow(icon: "person.fill.checkmark", label: tr("set.agentToast"), subtitle: tr("set.agentToastSub"), isOn: $settings.agentToastEnabled, accent: settings.accent) {}
                    Divider().background(Color.white.opacity(0.07))
                    DurationRow(label: tr("set.durSong"), value: $settings.songToastSeconds, accent: settings.accent)
                    DurationRow(label: tr("set.durAgent"), value: $settings.agentToastSeconds, accent: settings.accent)
                }
            }
            SettingsCard(label: tr("set.vault"), icon: "folder.fill", accent: settings.accent) {
                TextField(tr("set.vaultPh"), text: $vaultPath, onCommit: {
                    UserDefaults.standard.set(vaultPath, forKey: "notchObsidianVault")
                })
                .textFieldStyle(.roundedBorder).font(.callout)
            }
        }
    }

    // MARK: - Música

    private var musicPage: some View {
        SettingsCard(label: tr("set.source"), icon: "music.note", accent: settings.accent) {
            HStack(spacing: 8) {
                SourceCard(title: tr("focus.auto"), icon: "sparkles", sel: settings.musicSource == "auto", accent: settings.accent) {
                    settings.musicSource = "auto"
                }
                SourceCard(title: "Music", icon: "music.note", sel: settings.musicSource == "Music", accent: settings.accent) {
                    settings.musicSource = "Music"
                }
                SourceCard(title: "Spotify", icon: "waveform", sel: settings.musicSource == "Spotify", accent: settings.accent) {
                    settings.musicSource = "Spotify"
                }
            }
        }
    }

    // MARK: - Datos

    private var dataPage: some View {
        VStack(spacing: 12) {
            SettingsCard(label: tr("set.retention"), icon: "clock.fill", accent: settings.accent) {
                HStack(spacing: 6) {
                    ForEach(retentionPresets, id: \.self) { d in
                        PresetPill(label: tr("set.days", d), selected: Int(settings.historyDays) == d, accent: settings.accent) {
                            settings.historyDays = Double(d)
                        }
                    }
                }
                DurationRow(label: tr("set.retention"), value: $settings.historyDays, range: 7...365, step: 7, accent: settings.accent, suffix: "")
            }
            SettingsCard(label: tr("set.storage"), icon: "externaldrive.fill", accent: settings.accent) {
                HStack {
                    Text(storageSize)
                        .font(.notchMono(20)).foregroundStyle(.white).monospacedDigit()
                    Text(tr("set.storage"))
                        .font(.caption).foregroundStyle(Color.white.opacity(0.45))
                    Spacer()
                    Button(role: .destructive) { confirmClearData() } label: {
                        Text(tr("set.clear"))
                    }
                    .buttonStyle(NotchGhostButton(size: .small))
                }
                Text(dataSummary)
                    .font(.notchMono(9)).foregroundStyle(Color.white.opacity(0.4))
            }
        }
    }

    // MARK: - Idioma

    private var languagePage: some View {
        SettingsCard(label: tr("set.language"), icon: "globe", accent: settings.accent) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("set.languageSub"))
                    .font(.caption2).foregroundStyle(Color.white.opacity(0.45))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(NotchLang.allCases, id: \.self) { lang in
                        let sel = settings.langCode == lang.rawValue
                        Button {
                            settings.langCode = lang.rawValue
                        } label: {
                            HStack(spacing: 8) {
                                Text(lang.rawValue.uppercased())
                                    .font(.notchMono(11)).foregroundStyle(sel ? .white : settings.accent)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Capsule().fill(sel ? settings.accent : settings.accent.opacity(0.15)))
                                Text(lang.label)
                                    .font(.system(size: 12, weight: sel ? .semibold : .regular))
                                    .foregroundStyle(sel ? .white : Color.white.opacity(0.75))
                                Spacer()
                                if sel {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(settings.accent).font(.system(size: 14))
                                }
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(sel ? settings.accent.opacity(0.12) : Color.white.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(sel ? settings.accent.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Privacidad

    private var aboutPage: some View {
        SettingsCard(label: tr("set.privacy"), icon: "lock.fill", accent: settings.accent) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.green.opacity(0.15)).frame(width: 36, height: 36)
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 16)).foregroundStyle(.green)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tr("set.local")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        Text("~/Library/Application Support/NOTCH")
                            .font(.notchMono(8)).foregroundStyle(Color.white.opacity(0.4))
                    }
                }
                Text(tr("set.privacyBody"))
                    .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Acciones datos

    static let palette = ["A550A7", "7C5CFF", "2F9E6E", "D9A514", "E0574B", "3E8BD8"]
    private var opacityPresets: [Double] { [0.65, 0.82, 0.95] }

    private func opacityLabel(_ v: Double) -> String {
        "\(Int(v * 100))%"
    }

    private func isOpacityPreset(_ v: Double) -> Bool {
        abs(settings.panelOpacity - v) < 0.005
    }

    private var retentionPresets: [Int] { [30, 90, 180, 365] }

    private var dataSummary: String {
        let nt = NotchContext.shared.tasks.tasks.count
        let ne = HistoryStore.shared.events.count
        return "\(nt) tasks · \(ne) events"
    }

    private var tabsProgressLabel: String {
        "\(settings.visibleOrder.count) / \(settings.tabOrder.count)"
    }

    private var tabsFraction: CGFloat {
        let total = max(1, settings.tabOrder.count)
        return CGFloat(settings.visibleOrder.count) / CGFloat(total)
    }

    private func refreshStorageSize() {
        DispatchQueue.global(qos: .utility).async {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/NOTCH").path
            let kb = JunkStore.duKB([dir])
            let s = kb >= 1_048_576
                ? String(format: "%.1f GB", Double(kb) / 1_048_576)
                : String(format: "%.1f MB", Double(kb) / 1024)
            DispatchQueue.main.async { storageSize = s }
        }
    }

    private func confirmClearData() {
        let a = NSAlert()
        a.messageText = tr("set.clearTitle")
        a.informativeText = tr("set.clearBody")
        a.addButton(withTitle: tr("set.clearOk"))
        a.addButton(withTitle: tr("mac.cancel"))
        if a.runModal() == .alertFirstButtonReturn {
            HistoryStore.shared.reset()
            NotchContext.shared.tasks.clearAll()
            refreshStorageSize()
        }
    }
}

// MARK: - Piezas del rediseño

/// Tarjeta de sección con rótulo mono y borde sutil.
private struct SettingsCard<Content: View>: View {
    var label: String
    var icon: String
    var accent: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                Text(label.uppercased())
                    .font(.notchMono(10))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .kerning(1.2)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

/// Fila con icono + toggle.
private struct IconToggleRow: View {
    var icon: String
    var label: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var accent: Color
    var onChange: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? accent.opacity(0.2) : Color.white.opacity(0.06))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isOn ? accent : Color.white.opacity(0.45))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.white.opacity(0.9))
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(Color.white.opacity(0.45))
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(NotchToggleStyle(color: accent, mini: true))
                .labelsHidden()
                .onChange(of: isOn) { _ in onChange() }
        }
        .padding(.vertical, 4)
    }
}

/// Stepper con botones −/+ y valor pill.
private struct DurationRow: View {
    var label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 2...10
    var step: Double = 1
    var accent: Color
    var suffix: String = "s"

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.85))
            Spacer()
            Button { value = max(range.lowerBound, value - step) } label: {
                Image(systemName: "minus").font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(NotchGhostButton(size: .mini, tint: accent))
            .disabled(value <= range.lowerBound)
            Text("\(Int(value))\(suffix)")
                .font(.notchMono(12)).foregroundStyle(accent).monospacedDigit()
                .frame(minWidth: 36)
            Button { value = min(range.upperBound, value + step) } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(NotchGhostButton(size: .mini, tint: accent))
            .disabled(value >= range.upperBound)
        }
        .padding(.vertical, 2)
    }
}

/// Píldora de preset: evita el ternario de buttonStyle (rompe el type-checker).
private struct PresetPill: View {
    var label: String
    var selected: Bool
    var accent: Color
    var action: () -> Void

    var body: some View {
        if selected {
            Button(label, action: action)
                .buttonStyle(NotchPrimaryButton(size: .mini, color: accent))
        } else {
            Button(label, action: action)
                .buttonStyle(NotchGhostButton(size: .mini, tint: accent))
        }
    }
}

/// Tarjeta seleccionable de fuente de música.
private struct SourceCard: View {
    var title: String
    var icon: String
    var sel: Bool
    var accent: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(sel ? accent : Color.white.opacity(0.55))
                Text(title)
                    .font(.system(size: 11, weight: sel ? .semibold : .regular))
                    .foregroundStyle(sel ? .white : Color.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(sel ? accent.opacity(0.14) : Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(sel ? accent.opacity(0.7) : Color.white.opacity(0.08), lineWidth: sel ? 1.5 : 1))
        }
        .buttonStyle(.plain)
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
            .fill(Color.black.opacity(0.84))
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
