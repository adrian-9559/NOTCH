#if os(macOS)
import Combine
import SwiftUI

// MARK: - Timer (reloj grande + cronómetro + pausa + eye rest)

final class FocusTimerStore: ObservableObject {
    @Published var minutes = 20
    @Published var remaining: TimeInterval = 0
    @Published var elapsed: TimeInterval = 0
    @Published var running = false
    @Published var paused = false
    @Published var stopwatch = false
    @Published var eyeRest = true
    @Published var finishedMessage = ""
    private var timer: Timer?

    func start() {
        stopTick()
        if stopwatch {
            elapsed = 0
        } else {
            remaining = TimeInterval(minutes * 60)
        }
        running = true
        paused = false
        finishedMessage = ""
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        if stopwatch {
            elapsed += 1
        } else {
            remaining -= 1
            if remaining <= 0 {
                stop()
                if eyeRest {
                    finishedMessage = tr("focus.rest")
                    NSSound.beep()
                } else {
                    finishedMessage = tr("focus.ready")
                }
            }
        }
    }

    func pause() {
        paused = true
        stopTick()
    }

    func resume() {
        guard running, paused else { return }
        paused = false
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        running = false
        paused = false
        stopTick()
    }

    private func stopTick() {
        timer?.invalidate()
        timer = nil
    }

    /// Fracción del anillo: lo que queda (timer) o barrido del minuto (cronómetro).
    var progress: Double {
        if stopwatch {
            return (elapsed / 60).truncatingRemainder(dividingBy: 1)
        }
        let total = Double(minutes * 60)
        guard total > 0 else { return 0 }
        return max(0, min(1, remaining / total))
    }

    var label: String {
        if stopwatch {
            let e = Int(elapsed)
            if e >= 3600 { return String(format: "%d:%02d:%02d", e / 3600, (e % 3600) / 60, e % 60) }
            return String(format: "%d:%02d", e / 60, e % 60)
        }
        let m = Int(remaining) / 60, s = Int(remaining) % 60
        return String(format: "%d:%02d", m, s)
    }

    var totalLabel: String {
        stopwatch ? "∞" : "\(minutes) min"
    }
}

/// Anillo de reloj grande estilo Lumio: ticks + arco verde + tiempo.
struct TimerRing: View {
    var progress: Double
    var time: String
    var total: String
    var color: Color = Color(hex: "2F9E6E")

    var body: some View {
        ZStack {
            ForEach(0..<60, id: \.self) { i in
                let big = i % 5 == 0
                Capsule()
                    .fill(Color.white.opacity(big ? 0.5 : 0.22))
                    .frame(width: big ? 2.5 : 1.5, height: big ? 9 : 5)
                    .offset(y: -66)
                    .rotationEffect(.degrees(Double(i) * 6))
            }
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 6)
                .frame(width: 124, height: 124)
            Circle()
                .trim(from: 0, to: max(progress, 0.012))
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: 124, height: 124)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.9), value: progress)
            VStack(spacing: 1) {
                Text(time)
                    .font(.notchMono(24))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(total)
                    .font(.notchMono(10))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .frame(width: 148, height: 148)
    }
}

struct TimerView: View {
    @ObservedObject var store: FocusTimerStore
    @ObservedObject private var settings = NotchSettings.shared
    /// Verde Lumio del timer (el keep awake usa el color del usuario).
    private let timerGreen = Color(hex: "2F9E6E")
    var body: some View {
        VStack(spacing: 8) {
            // Timer | Cronómetro, como Lumio.
            NotchSegments(
                selection: $store.stopwatch,
                options: [(false, tr("focus.timer").capitalized), (true, tr("focus.stopwatch"))],
                color: timerGreen,
                disabledAll: store.running
            )
            .onChange(of: store.stopwatch) { _ in store.stop() }

            TimerRing(progress: store.progress, time: store.running ? store.label : store.stopwatch ? "0:00" : "\(store.minutes):00", total: store.running ? store.totalLabel : "\(store.minutes) min")

            if !store.stopwatch {
                // Presets + ajuste fino (±1 min).
                HStack(spacing: 6) {
                    ForEach([15, 25, 50, 90], id: \.self) { m in
                        if store.minutes == m, !store.running {
                            Button("\(m)") {}.buttonStyle(NotchPrimaryButton(size: .small, color: timerGreen)).disabled(true)
                        } else {
                            Button("\(m)") { store.minutes = m }.buttonStyle(NotchGhostButton(size: .small, tint: timerGreen))
                                .disabled(store.running)
                        }
                    }
                }
                NotchStepper(label: tr("focus.minutes", store.minutes), value: $store.minutes, range: 1...180, step: 1, color: timerGreen)
                    .disabled(store.running)
            }

            // Controles según estado.
            HStack(spacing: 6) {
                if !store.running {
                    Button {
                        store.start()
                    } label: {
                        Label(tr("focus.start"), systemImage: "play.fill")
                    }
                    .buttonStyle(NotchPrimaryButton(size: .small, color: timerGreen))
                } else if store.paused {
                    Button(tr("focus.resume")) { store.resume() }
                        .buttonStyle(NotchPrimaryButton(size: .small, color: timerGreen))
                    Button(tr("focus.stop")) { store.stop() }
                        .buttonStyle(NotchGhostButton(size: .small))
                } else {
                    Button(tr("focus.pause")) { store.pause() }
                        .buttonStyle(NotchPrimaryButton(size: .small, color: timerGreen))
                    Button(tr("focus.stop")) { store.stop() }
                        .buttonStyle(NotchGhostButton(size: .small))
                }
                Spacer()
                if !store.stopwatch {
                    Toggle(tr("focus.eyeRest"), isOn: $store.eyeRest)
                        .font(.caption2).toggleStyle(NotchToggleStyle(color: timerGreen, mini: true))
                }
            }
            if !store.finishedMessage.isEmpty {
                HStack(spacing: 6) {
                    Text(store.finishedMessage).font(.callout)
                    Spacer()
                    Button(tr("focus.repeat")) { store.start() }
                        .buttonStyle(NotchGhostButton(size: .mini))
                }
            }
        }
        .padding(8)
    }
}

// MARK: - Keep awake (caffeinate, configurable)
//
// A libre elección: evita el reposo de pantalla y/o el salvapantallas,
// con duración (30m, 1h, 2h, 4h, sin fin) o Auto mientras trabajan.
// - Pantalla: `caffeinate -d` (display sleep).
// - Salvapantallas: `caffeinate -u -t` (actividad de usuario acotada;
//   en modo sin fin se re-afirma cada pocos minutos).

final class AwakeStore: ObservableObject {
    @Published var mode = "off" // off | 30m | 1h | 2h | 4h | forever | auto
    @Published var active = false
    @Published var preventDisplay = true
    @Published var preventScreensaver = true
    @Published var remainingStr = ""
    private var proc: Process?
    private var endAt: Date?
    private var countdown: Timer?
    private var uRefresh: Timer?

    static let durations: [(key: String, label: String, seconds: Int)] = [
        ("off", "Off", 0),
        ("30m", "30m", 1800),
        ("1h", "1h", 3600),
        ("2h", "2h", 7200),
        ("4h", "4h", 14400),
        ("forever", "∞", 0),
        ("auto", "Auto", 0),
    ]
    /// Minutos del relojito ajustable (modo personalizado).
    @Published var customMinutes = 60

    /// Progreso 0…1 de la cuenta atrás (nil si no hay cuenta: ∞/auto/off).
    var progress: Double? {
        guard let end = endAt, mode == "custom" || timedKeys.contains(mode) else { return nil }
        let total = Double((mode == "custom" ? customMinutes * 60 : Self.durations.first { $0.key == mode }?.seconds) ?? 0)
        guard total > 0 else { return nil }
        return max(0, min(1, end.timeIntervalSince(Date()) / total))
    }

    private var timedKeys: [String] { ["30m", "1h", "2h", "4h"] }

    func set(_ newMode: String, store: SessionStore? = nil) {
        stop()
        mode = newMode
        switch newMode {
        case "30m", "1h", "2h", "4h":
            let secs = Self.durations.first { $0.key == newMode }?.seconds ?? 0
            start(seconds: secs)
        case "custom":
            start(seconds: customMinutes * 60)
        case "forever":
            start(seconds: 0)
        case "auto":
            active = true
            lastStore = store
            autoTimer?.invalidate()
            autoTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                self?.autoTick()
            }
            autoTick()
        default: break
        }
    }

    private weak var lastStore: SessionStore?
    private var autoTimer: Timer?

    /// Mientras los agentes trabajan, mantiene despierto salvo batería baja.
    private func autoTick() {
        let working = !(lastStore?.active.isEmpty ?? true)
        let batteryOK = BatteryInfo.level() == nil || (BatteryInfo.level() ?? 0) > 20 || BatteryInfo.onAC()
        if working && batteryOK {
            if proc == nil { start(seconds: 0) } // indefinido hasta parar
        } else {
            stopProcOnly()
        }
    }

    private func start(seconds: Int) {
        var args = ["-i"]
        if preventDisplay { args.append("-d") }
        if preventScreensaver {
            args.append("-u")
            if seconds > 0 { args += ["-t", "\(seconds)"] }
        } else if seconds > 0 {
            args += ["-t", "\(seconds)"]
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run(); proc = p; active = true
        } catch { active = false; return }
        // Sin fin + salvapantallas: re-afirma la actividad cada 200 s.
        if seconds <= 0, preventScreensaver {
            uRefresh?.invalidate()
            uRefresh = Timer.scheduledTimer(withTimeInterval: 200, repeats: true) { _ in
                let u = Process()
                u.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
                u.arguments = ["-u", "-t", "240"]
                u.standardOutput = FileHandle.nullDevice
                u.standardError = FileHandle.nullDevice
                try? u.run()
            }
        }
        // Cuenta atrás visible en los modos con tiempo.
        if seconds > 0 {
            endAt = Date().addingTimeInterval(TimeInterval(seconds))
            countdown?.invalidate()
            countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.tickCountdown()
            }
            tickCountdown()
        } else {
            remainingStr = mode == "auto" ? tr("focus.auto") : tr("focus.forever")
        }
    }

    private func tickCountdown() {
        guard let end = endAt else { return }
        let left = Int(end.timeIntervalSince(Date()))
        if left <= 0 {
            stop()
            return
        }
        remainingStr = String(format: "%d:%02d:%02d", left / 3600, (left % 3600) / 60, left % 60)
    }

    func stop() {
        autoTimer?.invalidate()
        countdown?.invalidate()
        uRefresh?.invalidate()
        countdown = nil; uRefresh = nil; autoTimer = nil
        stopProcOnly()
        mode = "off"
        endAt = nil
        remainingStr = ""
    }

    private func stopProcOnly() {
        proc?.terminate()
        proc = nil
        active = false
    }
}

struct AwakeView: View {
    @ObservedObject var store: AwakeStore
    @ObservedObject private var settings = NotchSettings.shared
    var sessions: SessionStore?

    /// Familia seleccionada: temporizado | sin fin | auto (como Timer|Cronómetro).
    private var family: Int {
        if store.mode == "forever" { return 1 }
        if store.mode == "auto" { return 2 }
        return 0
    }

    /// ¿Hay cuenta atrás en marcha?
    private var timedActive: Bool {
        store.active && (store.mode == "custom" || ["30m", "1h", "2h", "4h"].contains(store.mode))
    }

    private var ringTime: String {
        if timedActive, !store.remainingStr.isEmpty { return store.remainingStr }
        if store.mode == "forever" { return "∞" }
        if store.mode == "auto" { return "A" }
        if store.active { return store.remainingStr.isEmpty ? "∞" : store.remainingStr }
        return "\(store.customMinutes):00"
    }

    private var ringTotal: String {
        switch store.mode {
        case "forever": return tr("focus.forever")
        case "auto": return tr("focus.auto")
        default:
            if timedActive { return modeLabel }
            return "\(store.customMinutes) min"
        }
    }

    private var modeLabel: String {
        switch store.mode {
        case "30m", "1h", "2h", "4h": return store.mode
        case "custom": return "\(store.customMinutes) min"
        case "forever": return "∞"
        case "auto": return tr("focus.auto")
        default: return tr("focus.off")
        }
    }

    /// Minutos del preset correspondiente (30m→30, 1h→60…), para resaltar.
    private var presetMinutes: Int? {
        switch store.mode {
        case "30m": return 30
        case "1h": return 60
        case "2h": return 120
        case "4h": return 240
        case "custom": return store.customMinutes
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            // Selector de modo, espejo del Timer|Cronómetro.
            NotchSegments(
                selection: Binding(get: { family }, set: { pickFamily($0) }),
                options: [(0, tr("focus.timed")), (1, "∞"), (2, tr("focus.auto"))],
                color: settings.accent,
                disabledAll: store.active && timedActive
            )

            TimerRing(
                progress: store.progress ?? (store.active ? 1 : 0),
                time: ringTime,
                total: ringTotal,
                color: settings.accent
            )

            if family == 0 {
                // Presets + ajuste fino, igual que el timer.
                HStack(spacing: 6) {
                    ForEach([30, 60, 120, 240], id: \.self) { m in
                        let label = m >= 60 ? "\(m / 60)h" : "\(m)m"
                        if presetMinutes == m, !store.active {
                            Button(label) {}.buttonStyle(NotchPrimaryButton(size: .small, color: settings.accent)).disabled(true)
                        } else {
                            Button(label) { store.customMinutes = m }
                                .buttonStyle(NotchGhostButton(size: .small, tint: settings.accent))
                                .disabled(store.active)
                        }
                    }
                }
                NotchStepper(label: tr("focus.minutes", store.customMinutes), value: $store.customMinutes, range: 15...720, step: 15, color: settings.accent)
                    .disabled(store.active)
            } else {
                Text(family == 1 ? tr("focus.forever") : tr("set.autosendSub"))
                    .font(.caption2).foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(2).multilineTextAlignment(.center)
                    .frame(height: 28)
            }

            // Controles según estado, como el timer.
            HStack(spacing: 6) {
                if !store.active {
                    Button {
                        store.set(family == 0 ? "custom" : (family == 1 ? "forever" : "auto"), store: sessions)
                    } label: {
                        Label(tr("focus.start"), systemImage: "play.fill")
                    }
                    .buttonStyle(NotchPrimaryButton(size: .small, color: settings.accent))
                } else {
                    Button(tr("focus.stop")) { store.set("off", store: sessions) }
                        .buttonStyle(NotchPrimaryButton(size: .small, color: settings.accent))
                }
                Spacer()
                if store.active {
                    Text(modeLabel)
                        .font(.notchMono(10)).foregroundStyle(settings.accent)
                }
            }
            // Qué evitar (a libre elección).
            HStack(spacing: 12) {
                Toggle(tr("focus.screen"), isOn: $store.preventDisplay)
                    .onChange(of: store.preventDisplay) { _ in restart() }
                Toggle(tr("focus.screensaver"), isOn: $store.preventScreensaver)
                    .onChange(of: store.preventScreensaver) { _ in restart() }
            }
            .font(.caption)
            .toggleStyle(NotchToggleStyle(color: settings.accent, mini: true))
            if store.active {
                HStack(spacing: 3) {
                    Circle().fill(settings.accent).frame(width: 6, height: 6)
                    Text(store.remainingStr.isEmpty ? tr("focus.awakeOn") : store.remainingStr)
                        .font(.notchMono(10)).foregroundStyle(settings.accent).monospacedDigit()
                    Spacer()
                }
            }
        }
        .padding(8)
    }

    private func pickFamily(_ f: Int) {
        if f == 1 { store.set("forever", store: sessions) }
        else if f == 2 { store.set("auto", store: sessions) }
        else if store.active { store.set("off", store: sessions) }
    }

    /// Cambiar qué se evita reinicia el modo actual con la nueva mezcla.
    private func restart() {
        let m = store.mode
        guard m != "off" else { return }
        store.set(m, store: sessions)
    }
}

// MARK: - Batería (pmset, sin IOKit)

enum BatteryInfo {
    static func level() -> Int? {
        guard let out = runPmset() else { return nil }
        // "... (id=12345678)\t 85%; ..." → solo los dígitos pegados al %.
        guard let r = out.range(of: #"\d{1,3}(?=%)"#, options: .regularExpression) else { return nil }
        return Int(out[r])
    }

    static func onAC() -> Bool {
        (runPmset() ?? "").contains("AC Power")
    }

    private static func runPmset() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "batt"]
        let pipe = Pipe(); p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}
#endif
