#if os(macOS)
import AppKit
import Combine
import NotchCore
import SwiftUI

// MARK: - Portapapeles local (solo memoria, como Win+V)
//
// Historial de lo copiado sin salir del Mac: se vigila el pasteboard
// general y se guardan los últimos N textos EN MEMORIA (nada en disco,
// se vacía al salir). Clic = copiar (+ pegar directo con auto-pegar y
// permiso de Accesibilidad). El atajo global lo abre junto al cursor.

// MARK: - Modelo

struct ClipEntry: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var date = Date()
}

final class ClipStore: ObservableObject {
    @Published private(set) var clips: [ClipEntry] = []
    @Published var justCopied: UUID?

    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var flashWork: DispatchWorkItem?

    var maxItems: Int {
        max(5, Int(UserDefaults.standard.object(forKey: "notchClipMax") as? Double ?? 30))
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Lee el pasteboard si cambió (llamado por el timer y al mostrar).
    func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard let s = pb.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !s.isEmpty else { return }
        push(s)
    }

    /// Mete un texto arriba (evita duplicados seguidos, p. ej. re-copias).
    func push(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if clips.first?.text == t { return }
        clips.insert(ClipEntry(text: t), at: 0)
        if clips.count > maxItems {
            clips = Array(clips.prefix(maxItems))
        }
    }

    /// Copia un clip (y pega si está activado + hay confianza).
    func copy(_ clip: ClipEntry, paste: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(clip.text, forType: .string)
        lastChange = pb.changeCount
        flashWork?.cancel()
        justCopied = clip.id
        let w = DispatchWorkItem { [weak self] in self?.justCopied = nil }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
        if paste {
            ReplyService.shared.pasteFromClipboard()
        }
    }

    func clear() {
        clips = []
        justCopied = nil
    }
}

// MARK: - Vista en la pestaña Notas

struct ClipboardView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject private var settings = NotchSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                NotchTag(
                    icon: "clipboard.fill", text: tr("clip.title"),
                    color: settings.accent,
                    trailing: store.clips.isEmpty ? nil : "\(store.clips.count)"
                )
                Button(tr("clip.clear")) { store.clear() }
                    .buttonStyle(NotchGhostButton(size: .mini))
                    .disabled(store.clips.isEmpty)
            }
            if store.clips.isEmpty {
                VStack(spacing: 6) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.06)).frame(width: 34, height: 34)
                        Image(systemName: "clipboard")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.white.opacity(0.35))
                    }
                    Text(tr("clip.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.clips.prefix(12)) { clip in
                        Button {
                            store.copy(clip, paste: settings.clipAutoPaste)
                        } label: {
                            let copied = store.justCopied == clip.id
                            HStack(spacing: 8) {
                                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                                    .font(.system(size: copied ? 11 : 10))
                                    .foregroundStyle(copied ? .green : Color.white.opacity(0.35))
                                Text(clip.text)
                                    .font(.caption)
                                    .foregroundStyle(Color.white.opacity(0.85))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 6)
                                Text(shortWhen(clip.date))
                                    .font(.notchMono(9))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.white.opacity(0.07)))
                            }
                            .padding(.horizontal, 9).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(copied ? Color(hex: "2F9E6E").opacity(0.12) : Color.white.opacity(0.035))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(copied ? Color(hex: "2F9E6E").opacity(0.45) : Color.white.opacity(0.06), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text(tr("clip.hint"))
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(8)
        .onAppear { store.poll() }
    }

    private func shortWhen(_ d: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter(); f.locale = .current
        if cal.isDateInToday(d) { f.dateFormat = "HH:mm"; return f.string(from: d) }
        if cal.isDateInYesterday(d) { return tr("act.yesterday") }
        f.dateStyle = .short; f.timeStyle = .none
        return f.string(from: d)
    }
}

// MARK: - Atajo global: doble ⌘ derecho

/// Doble pulsación de Command derecho en <0,35 s. Requiere Input
/// Monitoring (sin él, macOS no entrega el monitor global).
final class ClipHotKey {
    var onFire: (() -> Void)?
    private var monitor: Any?
    private var lastDown: Date?

    func start() {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return }
            if event.type == .keyDown {
                self.lastDown = nil // otra tecla rompe la doble pulsación
                return
            }
            guard event.keyCode == 54, event.modifierFlags.contains(.command) else {
                if event.type == .flagsChanged { self.lastDown = nil }
                return
            }
            let now = Date()
            if let prev = self.lastDown, now.timeIntervalSince(prev) < 0.35 {
                self.lastDown = nil
                DispatchQueue.main.async { self.onFire?() }
            } else {
                self.lastDown = now
            }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

// MARK: - Mini popup estilo Win+V junto al cursor

/// Panel que sí coge teclado (a diferencia del notch): navegar con
/// ↑↓+Enter, 1-8 atajo directo, Esc cierra. Se esconde solo al
/// desactivarse la app (clic fuera).
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class ClipPopupController {
    private var panel: KeyPanel?
    private var frontApp: NSRunningApplication?
    var onPick: ((ClipEntry) -> Void)?

    func toggle(store: ClipStore) {
        if panel?.isVisible == true { hide(); return }
        show(store: store)
    }

    func show(store: ClipStore) {
        store.poll()
        frontApp = NSWorkspace.shared.frontmostApplication
        let count = min(max(store.clips.count, 1), 8)
        let h = CGFloat(52 + count * 46)
        let w: CGFloat = 360
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - h - 12)
        if let scr = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            let vf = scr.visibleFrame
            origin.x = min(max(origin.x, vf.minX), vf.maxX - w)
            origin.y = min(max(origin.y, vf.minY), vf.maxY - h)
        }
        if panel == nil {
            let p = KeyPanel(
                contentRect: NSRect(x: origin.x, y: origin.y, width: w, height: h),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.hidesOnDeactivate = true
            panel = p
        }
        guard let p = panel else { return }
        p.setFrame(NSRect(x: origin.x, y: origin.y, width: w, height: h), display: true)
        p.contentView = NSHostingView(rootView:
            ClipPopupView(store: store) { [weak self] clip in
                self?.pick(clip, store: store)
            }
            .environment(\.colorScheme, .dark)
        )
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func pick(_ clip: ClipEntry, store: ClipStore) {
        hide()
        let paste = NotchSettings.shared.clipAutoPaste
        store.copy(clip, paste: false)
        // Devuelve el foco a donde estaba y pega si toca.
        if let front = frontApp {
            front.activate()
            if paste {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    ReplyService.shared.pasteFromClipboard()
                }
            }
        } else if paste {
            ReplyService.shared.pasteFromClipboard()
        }
    }
}

/// Lista del popup: selección con teclado + clic.
struct ClipPopupView: View {
    @ObservedObject var store: ClipStore
    var onPick: (ClipEntry) -> Void
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var items: [ClipEntry] { Array(store.clips.prefix(8)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "clipboard.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotchSettings.shared.accent)
                Text(tr("clip.title"))
                    .font(.notchMono(10))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .kerning(1.2)
                Spacer()
                Text("esc")
                    .font(.notchMono(9))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
            }
            .padding(.horizontal, 10).padding(.top, 8)
            if items.isEmpty {
                Text(tr("clip.empty"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 14)
            } else {
                ForEach(items.indices, id: \.self) { i in
                    Button { onPick(items[i]) } label: {
                        HStack(spacing: 8) {
                            Text("\(i + 1)")
                                .font(.notchMono(9))
                                .foregroundStyle(Color.white.opacity(0.35))
                                .frame(width: 12)
                            Text(items[i].text)
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.9))
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(i == selected ? NotchSettings.shared.accent.opacity(0.22) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { h in if h { selected = i } }
                }
            }
        }
        .padding(.bottom, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.upArrow) { selected = max(0, selected - 1); return .handled }
        .onKeyPress(.downArrow) {
            selected = min(max(items.count - 1, 0), selected + 1)
            return .handled
        }
        .onKeyPress(.return) {
            if items.indices.contains(selected) { onPick(items[selected]) }
            return .handled
        }
        .onKeyPress(.escape) {
            ClipPopupCenter.shared.hide()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "12345678")) { press in
            if let n = Int(press.characters), items.indices.contains(n - 1) {
                onPick(items[n - 1])
            }
            return .handled
        }
    }
}

/// Acceso global al popup (teclas Esc y atajo lo usan).
enum ClipPopupCenter {
    static let shared = ClipPopupController()
}
#endif
