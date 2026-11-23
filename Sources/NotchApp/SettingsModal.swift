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

/// Páginas del sidebar:7 apartados temáticos (antes12, con varias
/// páginas de una sola tarjeta). Orden: lo esencial → lo visible →
/// lo que hace → lo que avisa → lo que se conecta → lo que guarda.
private enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, behavior, alerts, connections, data, news
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "house.fill"
        case .appearance: return "paintpalette.fill"
        case .behavior: return "cursorarrow.click.2"
        case .alerts: return "bell.fill"
        case .connections: return "link"
        case .data: return "externaldrive.fill"
        case .news: return "newspaper.fill"
        }
    }

    var titleKey: String {
        switch self {
        case .general: return "set.general"
        case .appearance: return "set.appearance"
        case .behavior: return "set.behavior"
        case .alerts: return "set.alerts"
        case .connections: return "set.connections"
        case .data: return "set.data"
        case .news: return "set.news"
        }
    }
}

struct SettingsModalView: View {
    @ObservedObject var settings = NotchSettings.shared
    @State private var page: SettingsPage = .general
    @State private var hoveredPage: SettingsPage? = nil
    @State private var hoverClose = false
    @State private var hoverOpen = UserDefaults.standard.object(forKey: "notchHoverOpen") as? Bool ?? true
    @State private var autoSend = ReplyService.shared.autoSendEnabled
    @State private var trustState = ReplyService.shared.isTrusted
    @State private var vaultPath: String = UserDefaults.standard.string(forKey: "notchObsidianVault") ?? ""
    @State private var launchLogin = false
    @State private var storageSize = "—"
    @ObservedObject private var calService = CalService.shared
    @State private var tgToken = ""
    @State private var tgChat = ""
    @State private var tgStatus = ""
    @State private var tgOk = false
    @State private var waOpen = false

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
                        .fill(
                            LinearGradient(colors: [settings.accent, settings.accent.opacity(0.65)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        .frame(width: 32, height: 32)
                        .shadow(color: settings.accent.opacity(0.45), radius: 9, y: 3)
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("NOTCH")
                        .font(.notchMono(13))
                        .foregroundStyle(.white)
                        .kerning(1.5)
                    Text(tr("set.subtitle"))
                        .font(.notchMono(8))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ForEach(SettingsPage.allCases) { p in
                let sel = page == p
                Button {
                    page = p
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: p.icon)
                            .font(.system(size: 12))
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(sel ? settings.accent.opacity(0.28)
                                           : (hoveredPage == p ? Color.white.opacity(0.09) : Color.white.opacity(0.06)))
                            )
                            .foregroundStyle(sel ? .white : Color.white.opacity(0.6))
                        Text(tr(p.titleKey).capitalized)
                            .font(.system(size: 12, weight: sel ? .semibold : .regular))
                            .foregroundStyle(sel ? .white : Color.white.opacity(0.7))
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(sel ? Color.white.opacity(0.10)
                                   : (hoveredPage == p ? Color.white.opacity(0.05) : Color.clear))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(sel ? settings.accent.opacity(0.40) : Color.clear, lineWidth: 1)
                    )
                    .overlay(alignment: .leading) {
                        // Indicador de selección pegado al filo izquierdo.
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(sel ? settings.accent : Color.clear)
                            .frame(width: 3, height: 20)
                            .padding(.leading, -6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { h in if h { hoveredPage = p } else if hoveredPage == p { hoveredPage = nil } }
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                    .shadow(color: Color.green.opacity(0.6), radius: 4)
                Text(tr("set.local"))
                    .font(.notchMono(8))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(width: 212)
        .background(Color.white.opacity(0.028))
    }

    // MARK: - Contenido

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(tr(page.titleKey).capitalized)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(settings.accent)
                            .frame(width: 18, height: 3)
                    }
                    Text(pageSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                Spacer()
                Button {
                    SettingsWindowController.shared.hide()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(hoverClose ? 0.9 : 0.55))
                        .frame(width: 26, height: 26)
                        .background(
                            Circle().fill(hoverClose ? Color.white.opacity(0.10) : Color.white.opacity(0.05))
                        )
                }
                .buttonStyle(.plain)
                .onHover { hoverClose = $0 }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch page {
                    case .general: generalPage
                    case .appearance: appearancePage
                    case .behavior: behaviorPage
                    case .alerts: alertsPage
                    case .connections: connectionsPage
                    case .data: dataPage
                    case .news: newsPage
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, 28)
            }
        }
    }

    private var pageSubtitle: String {
        switch page {
        case .general: return NotchNews.version
        default: return tr("set.subtitle")
        }
    }

    // MARK: - General

    /// Lo esencial junto: marca y enlaces, idioma, música y arranque.
    private var generalPage: some View {
        VStack(spacing: 12) {
            homePage
            languagePage
            musicPage
            SettingsCard(label: tr("set.startup"), icon: "power", accent: settings.accent) {
                IconToggleRow(icon: "power", label: tr("set.login"), subtitle: tr("set.loginSub"), isOn: $launchLogin, accent: settings.accent) {
                    LaunchAtLogin.set(launchLogin)
                    launchLogin = LaunchAtLogin.isEnabled()
                }
            }
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
            // Modo Liquid Glass de Apple (emulado): brillos de cristal
            // en el panel y en todas las tarjetas.
            SettingsCard(label: tr("set.liquid"), icon: "drop.fill", accent: settings.accent) {
                IconToggleRow(icon: "drop.halffull",
                              label: tr("set.liquid").capitalized,
                              subtitle: tr("set.liquidSub"),
                              isOn: $settings.liquidGlass, accent: settings.accent) {}
            }
            tabsPage
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
                }
            }
            clipboardPage
            SettingsCard(label: tr("set.vault"), icon: "folder.fill", accent: settings.accent) {
                NotchTextField(
                    placeholder: tr("set.vaultPh"), text: $vaultPath,
                    icon: "folder", color: settings.accent, font: .callout,
                    onCommit: {
                        UserDefaults.standard.set(vaultPath, forKey: "notchObsidianVault")
                    }
                )
            }
        }
    }

    // MARK: - Avisos

    /// Todo el ruido en un solo sitio: qué se avisa, cuánto dura y
    /// hacia fuera (Telegram/WhatsApp). Antes repartido entre
    /// Comportamiento y Conexiones.
    private var alertsPage: some View {
        VStack(spacing: 12) {
            // Apartado: qué avisos (sin duraciones mezcladas).
            SettingsCard(label: tr("set.alerts"), icon: "bell.fill", accent: settings.accent) {
                VStack(spacing: 2) {
                    IconToggleRow(icon: "music.note", label: tr("set.songToast"), subtitle: tr("set.songToastSub"), isOn: $settings.songToastEnabled, accent: settings.accent) {}
                    Divider().background(Color.white.opacity(0.07))
                    IconToggleRow(icon: "person.fill.checkmark", label: tr("set.agentToast"), subtitle: tr("set.agentToastSub"), isOn: $settings.agentToastEnabled, accent: settings.accent) {}
                    Divider().background(Color.white.opacity(0.07))
                    IconToggleRow(icon: "hand.raised.fill", label: tr("set.waitToast"), subtitle: tr("set.waitToastSub"), isOn: $settings.waitToastEnabled, accent: settings.accent) {}
                    Divider().background(Color.white.opacity(0.07))
                    IconToggleRow(icon: "bell.badge.fill", label: tr("set.reminders"), subtitle: tr("set.remindersSub"), isOn: $settings.remindersEnabled, accent: settings.accent) {}
                }
            }
            // Apartado: cuánto dura cada aviso.
            SettingsCard(label: tr("set.durations"), icon: "stopwatch.fill", accent: settings.accent) {
                VStack(spacing: 2) {
                    DurationRow(label: tr("set.durSong"), value: $settings.songToastSeconds, accent: settings.accent)
                    Divider().background(Color.white.opacity(0.07))
                    DurationRow(label: tr("set.durAgent"), value: $settings.agentToastSeconds, accent: settings.accent)
                    Divider().background(Color.white.opacity(0.07))
                    DurationRow(label: tr("set.durWait"), value: $settings.waitToastSeconds, range: 3...15, accent: settings.accent)
                }
            }
            // Notificaciones externas: Telegram (envía) y WhatsApp (abre).
            SettingsCard(label: tr("set.notifExt"), icon: "paperplane.fill", accent: settings.accent) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        NotchTextField(
                            placeholder: tr("set.tgToken"), text: $tgToken,
                            icon: "key.fill", color: settings.accent, font: .caption,
                            onCommit: { ExternalNotify.shared.setToken(tgToken) })
                        NotchTextField(
                            placeholder: tr("set.tgChat"), text: $tgChat,
                            icon: "number", color: settings.accent, font: .caption,
                            onCommit: { ExternalNotify.shared.tgChatId = tgChat })
                    }
                    HStack(spacing: 8) {
                        Button(tr("set.tgTest")) { testTelegram() }
                            .buttonStyle(NotchPrimaryButton(size: .small, color: settings.accent))
                        if !tgStatus.isEmpty {
                            HStack(spacing: 4) {
                                Circle().fill(tgOk ? Color.green : Color(hex: "E0574B"))
                                    .frame(width: 6, height: 6)
                                Text(tgStatus).font(.notchMono(10)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { ExternalNotify.shared.tgEnabled },
                                                 set: { ExternalNotify.shared.tgEnabled = $0 }))
                            .toggleStyle(NotchToggleStyle(color: settings.accent, mini: true))
                            .labelsHidden()
                    }
                    Divider().background(Color.white.opacity(0.07))
                    // Qué eventos salen por Telegram.
                    IconToggleRow(icon: "checkmark.circle.fill", label: tr("set.agentToast"),
                                  isOn: Binding(get: { ExternalNotify.shared.tgEvtDone },
                                                set: { ExternalNotify.shared.tgEvtDone = $0 }),
                                  accent: settings.accent) {}
                    Divider().background(Color.white.opacity(0.07))
                    IconToggleRow(icon: "hand.raised.fill", label: tr("set.waitToast"),
                                  isOn: Binding(get: { ExternalNotify.shared.tgEvtWaiting },
                                                set: { ExternalNotify.shared.tgEvtWaiting = $0 }),
                                  accent: settings.accent) {}
                    Divider().background(Color.white.opacity(0.07))
                    IconToggleRow(icon: "bell.badge.fill", label: tr("set.reminders"),
                                  isOn: Binding(get: { ExternalNotify.shared.tgEvtReminder },
                                                set: { ExternalNotify.shared.tgEvtReminder = $0 }),
                                  accent: settings.accent) {}
                    Divider().background(Color.white.opacity(0.07))
                    // WhatsApp: sin API personal, solo abre el chat.
                    IconToggleRow(icon: "bubble.left.fill", label: tr("set.waOpen"),
                                  subtitle: tr("set.waOpenSub"),
                                  isOn: $waOpen, accent: settings.accent) {
                        ExternalNotify.shared.waOpenDone = waOpen
                    }
                    HStack(spacing: 6) {
                        Button(tr("set.waTest")) { ExternalNotify.shared.openWhatsApp(tr("set.testMsg")) }
                            .buttonStyle(NotchGhostButton(size: .small, tint: settings.accent))
                        Spacer()
                    }
                    Text(tr("set.notifHint"))
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    // MARK: - Portapapeles

    private var clipboardPage: some View {
        VStack(spacing: 12) {
            SettingsCard(label: tr("set.clipboard"), icon: "clipboard.fill", accent: settings.accent) {
                VStack(spacing: 2) {
                    IconToggleRow(icon: "command", label: tr("set.clipHotkey"), subtitle: tr("set.clipHotkeySub"), isOn: $settings.clipHotkeyEnabled, accent: settings.accent) {}
                    Divider().background(Color.white.opacity(0.07))
                    IconToggleRow(icon: "doc.on.clipboard.fill", label: tr("set.clipAutoPaste"), subtitle: tr("set.clipAutoPasteSub"), isOn: $settings.clipAutoPaste, accent: settings.accent) {
                        if settings.clipAutoPaste, !ReplyService.shared.isTrusted {
                            ReplyService.shared.requestTrust()
                        }
                        trustState = ReplyService.shared.isTrusted
                    }
                    HStack {
                        Circle().fill(trustState ? Color.green : Color.orange).frame(width: 7, height: 7)
                        Text(trustState ? tr("set.trustOk") : tr("set.trustPending"))
                            .font(.notchMono(9)).foregroundStyle(Color.white.opacity(0.5))
                        Spacer()
                    }
                    Divider().background(Color.white.opacity(0.07))
                    DurationRow(label: tr("set.clipMax"), value: $settings.clipMax, range: 10...100, step: 5, accent: settings.accent, suffix: "")
                }
            }
            // Apartado: permiso de entrada (atajo global).
            SettingsCard(label: tr("set.inputPerm"), icon: "keyboard.fill", accent: settings.accent) {
                HStack {
                    Text(tr("set.inputMon"))
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(tr("set.openSettings")) { openPrivacySettings() }
                        .controlSize(.small).buttonStyle(NotchGhostButton(size: .small, tint: settings.accent))
                }
            }
        }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Conexiones

    private var connectionsPage: some View {
        VStack(spacing: 12) {
            SettingsCard(label: tr("set.connections"), icon: "link", accent: settings.accent) {
                VStack(spacing: 2) {
                    ConnRow(
                        icon: "calendar", title: tr("set.appleCal"), subtitle: tr("set.appleCalSub"),
                        status: calService.auth == .granted ? tr("set.connected") : tr("set.disconnected"),
                        ok: calService.auth == .granted,
                        actionTitle: tr("set.connect"), accent: settings.accent
                    ) {
                        CalService.shared.requestAccess()
                    }
                    Divider().background(Color.white.opacity(0.07))
                    IconToggleRow(icon: "calendar.badge.checkmark", label: tr("set.useSystemCal"), subtitle: tr("set.useSystemCalSub"), isOn: $settings.useSystemCalendar, accent: settings.accent) {}
                    Divider().background(Color.white.opacity(0.07))
                    ConnRow(
                        icon: "location.fill", title: tr("set.location"), subtitle: tr("set.locationSub"),
                        status: settings.useLocation ? tr("set.on") : tr("set.off"),
                        ok: settings.useLocation,
                        actionTitle: settings.useLocation ? tr("set.off") : tr("set.on"), accent: settings.accent
                    ) {
                        settings.useLocation.toggle()
                    }
                    Divider().background(Color.white.opacity(0.07))
                    // Unidad térmica: ºC o ºF (cambia todo el clima).
                    HStack(spacing: 8) {
                        Image(systemName: "thermometer.medium")
                            .font(.system(size: 11))
                            .foregroundStyle(settings.accent)
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(settings.accent.opacity(0.14))
                            )
                        Text(tr("set.tempUnit"))
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.7))
                        Spacer()
                        NotchSegments(
                            selection: $settings.tempUnit,
                            options: [("C", "°C"), ("F", "°F")],
                            color: settings.accent
                        )
                    }
                    .padding(.vertical, 4)
                }
            }
            SettingsCard(label: tr("set.externalCals"), icon: "envelope.fill", accent: settings.accent) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("set.externalCalsSub"))
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button("Google") { openInternetAccounts() }
                            .buttonStyle(NotchGhostButton(size: .small, tint: settings.accent))
                        Button("Outlook") { openInternetAccounts() }
                            .buttonStyle(NotchGhostButton(size: .small, tint: settings.accent))
                        Button("Exchange") { openInternetAccounts() }
                            .buttonStyle(NotchGhostButton(size: .small, tint: settings.accent))
                    }
                }
            }
        }
        .onAppear {
            CalService.shared.refreshStatus()
            tgToken = ExternalNotify.shared.token ?? ""
            tgChat = ExternalNotify.shared.tgChatId
            waOpen = ExternalNotify.shared.waOpenDone
        }
    }

    private func testTelegram() {
        ExternalNotify.shared.send(tr("set.testMsg"), event: .done, force: true) { ok in
            tgOk = ok
            tgStatus = ok ? tr("set.tgOk") : tr("set.tgFail")
        }
    }

    private func openInternetAccounts() {
        // Cuentas de Internet: lo sincronizado aparece en Calendario.
        if let url = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(url)
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
            // Texto legal junto a los datos (antes, dos páginas sueltas).
            aboutPage
            termsPage
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
            VStack(alignment: .leading, spacing: 12) {
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
                privSection("priv.data", "priv.dataBody")
                privDivider
                privSection("priv.permissions", "priv.permissionsBody")
                privDivider
                privSection("priv.network", "priv.networkBody")
                privDivider
                privSection("priv.storage", "priv.storageBody")
            }
        }
    }

    private var privDivider: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
    }

    /// Apartado de texto: rótulo mono + párrafo.
    private func privSection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr(title).capitalized)
                .font(.notchMono(10))
                .foregroundStyle(settings.accent.opacity(0.9))
                .kerning(1)
            Text(tr(body))
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.65))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Inicio

    static let featureIcons = ["sparkles", "music.note", "chart.bar", "checklist",
                               "note.text", "cloud.sun", "timer", "lock.shield"]

    private var homePage: some View {
        VStack(spacing: 12) {
            SettingsCard(label: "NOTCH", icon: "house.fill", accent: settings.accent) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(LinearGradient(colors: [settings.accent, settings.accent.opacity(0.6)],
                                                     startPoint: .top, endPoint: .bottom))
                                .frame(width: 40, height: 40)
                                .shadow(color: settings.accent.opacity(0.4), radius: 10, y: 3)
                            Image(systemName: "rectangle.topthird.inset.filled")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("NOTCH")
                                    .font(.notchMono(15)).foregroundStyle(.white).kerning(2)
                                Text(NotchNews.version)
                                    .font(.notchMono(9)).foregroundStyle(settings.accent)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(settings.accent.opacity(0.15)))
                            }
                            Text(tr("home.tagline"))
                                .font(.caption2).foregroundStyle(Color.white.opacity(0.5))
                        }
                    }
                    Text(tr("home.body"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsCard(label: tr("home.features"), icon: "square.grid.2x2.fill", accent: settings.accent) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(Array(Self.featureIcons.enumerated()), id: \.offset) { i, icon in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: icon)
                                .font(.system(size: 11))
                                .foregroundStyle(settings.accent)
                                .frame(width: 24, height: 24)
                                .background(RoundedRectangle(cornerRadius: 6).fill(settings.accent.opacity(0.14)))
                            Text(tr("home.f\(i + 1)"))
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(0.8))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            SettingsCard(label: tr("home.links"), icon: "link", accent: settings.accent) {
                HStack(spacing: 8) {
                    Button { openURL("https://github.com/adrian-9559/NOTCH") } label: {
                        Label("GitHub", systemImage: "link")
                    }
                    .buttonStyle(NotchGhostButton(size: .small, tint: settings.accent))
                    Button { openURL("https://github.com/adrian-9559/NOTCH/issues") } label: {
                        Label(tr("home.issues"), systemImage: "exclamationmark.bubble")
                    }
                    .buttonStyle(NotchGhostButton(size: .small, tint: settings.accent))
                    Spacer()
                }
            }
        }
    }

    private func openURL(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    // MARK: - Novedades

    private var newsPage: some View {
        VStack(spacing: 16) {
            ForEach(NotchNews.releases) { r in
                SettingsCard(label: r.version, icon: "newspaper.fill", accent: settings.accent) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(r.date)
                            .font(.notchMono(9))
                            .foregroundStyle(Color.white.opacity(0.4))
                        ForEach(r.bullets, id: \.self) { key in
                            HStack(alignment: .top, spacing: 7) {
                                Circle().fill(settings.accent).frame(width: 4, height: 4).padding(.top, 5)
                                Text(tr(key))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.white.opacity(0.75))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Condiciones de uso

    private var termsPage: some View {
        SettingsCard(label: tr("set.terms"), icon: "doc.text.fill", accent: settings.accent) {
            VStack(alignment: .leading, spacing: 10) {
                let clauses = ["terms.t1", "terms.t2", "terms.t3", "terms.t4", "terms.t5", "terms.t6"]
                ForEach(Array(clauses.enumerated()), id: \.offset) { i, key in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1).")
                            .font(.notchMono(10))
                            .foregroundStyle(settings.accent)
                            .frame(width: 16, alignment: .trailing)
                        Text(tr(key))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.7))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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

/// Tarjeta de sección con rótulo mono y borde sutil (mismo material
/// que las tarjetas del panel: degradado, filo en degradado, sombra).
private struct SettingsCard<Content: View>: View {
    var label: String
    var icon: String
    var accent: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(accent.opacity(0.16))
                    )
                Text(label.uppercased())
                    .font(.notchMono(10))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .kerning(1.2)
                Spacer()
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.058), Color.white.opacity(0.028)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.13), Color.white.opacity(0.055)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .liquidGlass(NotchSettings.shared.liquidGlass, radius: 14)
        .shadow(color: .black.opacity(0.20), radius: 10, y: 5)
    }
}

/// Fila con icono + toggle (con hover sutil).
private struct IconToggleRow: View {
    var icon: String
    var label: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var accent: Color
    var onChange: () -> Void
    @State private var hover = false

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
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hover ? Color.white.opacity(0.045) : Color.clear)
        )
        .onHover { hover = $0 }
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

/// Fila de conexión: icono + nombre + estado + botón de acción.
private struct ConnRow: View {
    var icon: String
    var title: String
    var subtitle: String
    var status: String
    var ok: Bool
    var actionTitle: String
    var accent: Color
    var action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(ok ? accent.opacity(0.2) : Color.white.opacity(0.06))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(ok ? accent : Color.white.opacity(0.45))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.white.opacity(0.9))
                Text(subtitle).font(.caption2).foregroundStyle(Color.white.opacity(0.45))
            }
            Spacer()
            Text(status)
                .font(.notchMono(9))
                .foregroundStyle(ok ? Color.green : Color.white.opacity(0.45))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(ok ? Color.green.opacity(0.12) : Color.white.opacity(0.07)))
            Button(actionTitle, action: action)
                .buttonStyle(NotchGhostButton(size: .mini, tint: accent))
        }
        .padding(.vertical, 4)
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

/// Novedades versionadas (se muestra en Ajustes → Novedades).
private enum NotchNews {
    static let version = "v0.7.0"

    struct Release: Identifiable {
        let version: String
        let date: String
        let bullets: [String] // claves i18n
        var id: String { version }
    }

    static let releases: [Release] = [
        Release(version: "v0.7.0", date: "22 nov 2026", bullets: [
            "news.v070a", "news.v070b", "news.v070c", "news.v070d"]),
        Release(version: "v0.6.0", date: "22 nov 2026", bullets: [
            "news.v060a", "news.v060b", "news.v060c", "news.v060d"]),
        Release(version: "v0.5.0", date: "21 nov 2026", bullets: [
            "news.v050a", "news.v050b", "news.v050c", "news.v050d"]),
        Release(version: "v0.4.0", date: "21 nov 2026", bullets: [
            "news.v040a", "news.v040b", "news.v040c", "news.v040d"]),
        Release(version: "v0.3.0", date: "20 nov 2026", bullets: [
            "news.v030a", "news.v030b"]),
        Release(version: "v0.2.0", date: "19 nov 2026", bullets: [
            "news.v020a", "news.v020b", "news.v020c"]),
        Release(version: "v0.1.0", date: "19 nov 2026", bullets: [
            "news.v010a", "news.v010b"]),
    ]
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
