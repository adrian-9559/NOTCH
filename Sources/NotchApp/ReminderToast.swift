#if os(macOS)
import AppKit
import NotchCore
import SwiftUI
import UserNotifications

/// Aviso de recordatorio: la tarea vence. Clicable (abre Tareas) y con
/// notificación del sistema si el evento lo pide. Una vez por evento.

// MARK: - Aviso para ir a la pestaña de tareas

extension Notification.Name {
    static let notchShowTasks = Notification.Name("notchShowTasks")
}

/// Píldora de recordatorio: tarea + hora, con el acento.
struct ReminderToastView: View {
    @ObservedObject var state: ReminderToastState
    var onTap: () -> Void = {}

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                if state.visible {
                    Button(action: onTap) {
                        pill
                    }
                    .buttonStyle(.plain)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .animation(.snappy(duration: 0.35), value: state.visible)
    }

    private var pill: some View {
        HStack(spacing: 10) {
            // Avatar tipo app (cuadrado redondeado) con campana.
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(NotchSettings.shared.accent)
                    .frame(width: 30, height: 30)
                Image(systemName: "bell.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(state.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(state.time)
                        .font(.notchMono(9))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .monospacedDigit()
                }
                Text(state.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(2)
            }
            Spacer(minLength: 2)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .frame(width: 340, height: 64)
        .background(toastGlass)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var toastGlass: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let accent = NotchSettings.shared.accent
        return ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(Color.black.opacity(0.55))
            shape.fill(
                LinearGradient(
                    colors: [accent.opacity(0.32), accent.opacity(0.08)],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
        .overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(radius: 16)
    }
}

final class ReminderToastState: ObservableObject {
    @Published var visible = false
    @Published var title = ""
    @Published var subtitle = ""
    /// Hora del mensaje (estilo notificación), se fija al mostrar.
    @Published var time = ""
    private var hideWork: DispatchWorkItem?
    private var gen = 0

    func announce(title: String, subtitle: String) {
        gen += 1
        let g = gen
        hideWork?.cancel()
        self.title = title
        self.subtitle = subtitle
        self.time = NotchDateFmt.hourMinute.string(from: Date())
        visible = true
        let secs = NotchSettings.shared.waitToastSeconds
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

final class ReminderToastController {
    let state = ReminderToastState()
    private var panels: [NSPanel] = []
    var isPanelVisible: (() -> Bool)?
    var onTap: (() -> Void)?
    func rebuild(notches: [ScreenNotch]) {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        for entry in notches where entry.layout.hasNotch {
            let n = entry.layout.notchRect
            let w: CGFloat = 340, h: CGFloat = 64
            let frame = NSRect(x: n.midX - w / 2, y: n.minY - h - 10, width: w, height: h)
            fputs("NOTCH-REMINDERTOAST frame=\(frame)\n", stderr)
            panels.append(makePanel(frame: frame))
        }
        panels.forEach { $0.orderFrontRegardless() }
    }

    func show(title: String, subtitle: String) {
        guard isPanelVisible?() != true else { return }
        state.announce(title: title, subtitle: subtitle)
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
        p.ignoresMouseEvents = false
        p.contentView = FirstMouseHostingView(rootView: ReminderToastView(state: state) { [weak self] in
            self?.onTap?()
        })
        return p
    }
}

// MARK: - Planificador (cada 30 s) + sistema

/// Revisa vencimientos y dispara píldora y/o sistema según cada evento.
final class ReminderScheduler {
    private var timer: Timer?

    func start(tasks: TaskStore, fire: @escaping ([AgentTask]) -> Void) {
        stop()
        // Primera pasada a los 10 s (deja arrancar), luego cada 30 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.tick(tasks: tasks, fire: fire)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            self.tick(tasks: tasks, fire: fire)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick(tasks: TaskStore, fire: @escaping ([AgentTask]) -> Void) {
        let due = tasks.dueReminders()
        fputs("NOTCH-DBG reminder-tick n=\(tasks.tasks.count) due=\(due.count)\n", stderr)
        guard !due.isEmpty else { return }
        fire(due)
    }
}

/// Texto del aviso de recordatorio (píldora y sistema comparten).
enum ReminderText {
    static func subtitle(for task: AgentTask) -> String {
        if !task.detail.isEmpty { return task.detail }
        guard let r = task.remindAt else { return "" }
        let f = DateFormatter(); f.locale = .current
        if Calendar.current.isDateInToday(r) {
            f.dateFormat = "HH:mm"
            return tr("task.remind") + " " + f.string(from: r)
        }
        f.dateStyle = .short; f.timeStyle = .short
        return tr("task.remind") + " " + f.string(from: r)
    }
}

/// Notificación del sistema para recordatorios (conTap abre Tareas).
enum ReminderSystem {
    /// Solo con .app empaquetada: el binario suelto de desarrollo no
    /// tiene bundle y UNUserNotificationCenter revienta sin él.
    static var available: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static func send(_ task: AgentTask) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = task.title
            c.body = ReminderText.subtitle(for: task)
            c.sound = .default
            c.userInfo = ["taskID": task.id.uuidString]
            let req = UNNotificationRequest(
                identifier: "notch-reminder-\(task.id.uuidString)",
                content: c, trigger: nil
            )
            center.add(req)
        }
    }
}
#endif
