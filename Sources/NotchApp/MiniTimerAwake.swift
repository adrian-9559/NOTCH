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
    var body: some View {
        VStack(spacing: 8) {
            // Timer | Cronómetro, como Lumio.
            Picker("", selection: $store.stopwatch) {
                Text(tr("focus.timer").capitalized).tag(false)
                Text(tr("focus.stopwatch")).tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .disabled(store.running)
            .onChange(of: store.stopwatch) { _ in store.stop() }

            TimerRing(progress: store.progress, time: store.running ? store.label : store.stopwatch ? "0:00" : "\(store.minutes):00", total: store.running ? store.totalLabel : "\(store.minutes) min")

            if !store.stopwatch {
                // Presets + ajuste fino (±1 min).
                HStack(spacing: 6) {
                    ForEach([15, 25, 50, 90], id: \.self) { m in
                        if store.minutes == m, !store.running {
                            Button("\(m)") {}.controlSize(.small).buttonStyle(.borderedProminent).disabled(true)
                        } else {
                            Button("\(m)") { store.minutes = m }.controlSize(.small).buttonStyle(.bordered)
                                .disabled(store.running)
                        }
                    }
                }
                Stepper(tr("focus.minutes", store.minutes), value: $store.minutes, in: 1...180, step: 1)
                    .font(.caption).disabled(store.running)
            }

            // Controles según estado.
            HStack(spacing: 6) {
                if !store.running {
                    Button {
                        store.start()
                    } label: {
                        Label(tr("focus.start"), systemImage: "play.fill")
                    }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                } else if store.paused {
                    Button(tr("focus.resume")) { store.resume() }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                    Button(tr("focus.stop")) { store.stop() }
                        .controlSize(.small).buttonStyle(.bordered)
                } else {
                    Button(tr("focus.pause")) { store.pause() }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                    Button(tr("focus.stop")) { store.stop() }
                        .controlSize(.small).buttonStyle(.bordered)
                }
                Spacer()
                if !store.stopwatch {
                    Toggle(tr("focus.eyeRest"), isOn: $store.eyeRest)
                        .font(.caption2).toggleStyle(.switch).controlSize(.mini)
                        .tint(.green)
                }
            }
            if !store.finishedMessage.isEmpty {
                HStack(spacing: 6) {
                    Text(store.finishedMessage).font(.callout)
                    Spacer()
                    Button(tr("focus.repeat")) { store.start() }
                        .controlSize(.mini).buttonStyle(.bordered)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("focus.awake")).font(.notchMono(11)).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 10) {
                // Relojito: progreso de la cuenta atrás + tiempo restante.
                ZStack {
                    if let p = store.progress {
                        ProgressView(value: p)
                            .progressViewStyle(.circular)
                            .scaleEffect(1.4)
                    } else {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(1.1)
                            .opacity(store.active ? 1 : 0.35)
                    }
                    Text(clockLabel)
                        .font(.notchMono(9))
                        .monospacedDigit()
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    // Tiempo ajustable del relojito.
                    Stepper(tr("focus.min", store.customMinutes), value: $store.customMinutes, in: 15...720, step: 15)
                        .font(.caption)
                        .onChange(of: store.customMinutes) { _ in
                            if store.mode == "custom" { store.set("custom", store: sessions) }
                        }
                    HStack(spacing: 4) {
                        ForEach(["30m", "1h", "2h", "4h"], id: \.self) { key in
                            chipButton(key, label: key)
                        }
                    }
                    HStack(spacing: 4) {
                        chipButton("forever", label: "∞")
                        chipButton("auto", label: tr("focus.auto"))
                        if store.mode == "off" {
                            Button(tr("focus.go")) { store.set("custom", store: sessions) }
                                .controlSize(.mini).buttonStyle(.borderedProminent)
                        } else {
                            Button(tr("focus.off")) { store.set("off", store: sessions) }
                                .controlSize(.mini).buttonStyle(.bordered)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            // Qué evitar (a libre elección).
            HStack(spacing: 12) {
                Toggle(tr("focus.screen"), isOn: $store.preventDisplay).controlSize(.mini)
                    .onChange(of: store.preventDisplay) { _ in restart() }
                Toggle(tr("focus.screensaver"), isOn: $store.preventScreensaver).controlSize(.mini)
                    .onChange(of: store.preventScreensaver) { _ in restart() }
            }
            .font(.caption)
            .toggleStyle(.switch)
            if store.active {
                HStack(spacing: 3) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text(store.remainingStr.isEmpty ? tr("focus.awakeOn") : store.remainingStr)
                        .font(.notchMono(10)).foregroundStyle(.green).monospacedDigit()
                }
            }
        }
        .padding(8)
    }

    private var clockLabel: String {
        switch store.mode {
        case "forever": return "∞"
        case "auto": return "A"
        case "off": return "zZ"
        default:
            let parts = store.remainingStr.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 3 else { return "" }
            if parts[0] > 0 { return "\(parts[0])h" }
            return "\(parts[1])m"
        }
    }

    private func chipButton(_ key: String, label: String) -> some View {
        Group {
            if store.mode == key {
                Button(label) {}.controlSize(.mini).buttonStyle(.borderedProminent).disabled(true)
            } else {
                Button(label) { store.set(key, store: sessions) }
                    .controlSize(.mini).buttonStyle(.bordered)
            }
        }
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
