#if os(macOS)
import Combine
import SwiftUI

// MARK: - Timer (rueda/ajuste + anillo + pausa para ojos)

final class FocusTimerStore: ObservableObject {
    @Published var minutes = 20
    @Published var remaining: TimeInterval = 0
    @Published var running = false
    @Published var finishedMessage = ""
    private var timer: Timer?

    func start() {
        remaining = TimeInterval(minutes * 60)
        running = true
        finishedMessage = ""
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.remaining -= 1
            if self.remaining <= 0 {
                self.stop()
                self.finishedMessage = tr("focus.rest")
                NSSound.beep()
            }
        }
    }

    func stop() {
        running = false
        timer?.invalidate()
    }

    var progress: Double {
        let total = Double(minutes * 60)
        guard total > 0 else { return 0 }
        return max(0, min(1, remaining / total))
    }

    var label: String {
        let m = Int(remaining) / 60, s = Int(remaining) % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct TimerView: View {
    @ObservedObject var store: FocusTimerStore
    @ObservedObject private var settings = NotchSettings.shared
    var body: some View {
        VStack(spacing: 6) {
            Text(tr("focus.timer")).font(.notchMono(11)).foregroundStyle(.secondary)
            ZStack {
                ProgressView(value: store.progress)
                    .progressViewStyle(.circular)
                    .scaleEffect(1.7)
                    .padding(10)
                Text(store.running ? store.label : tr("focus.min", store.minutes))
                    .font(.notchMono(14))
            }
            Stepper(tr("focus.minutes", store.minutes), value: $store.minutes, in: 1...180, step: 5)
                .font(.caption).disabled(store.running)
            HStack {
                ForEach([5, 20, 25, 50], id: \.self) { m in
                    Button("\(m)'") { store.minutes = m }.controlSize(.mini)
                }
                Spacer()
                if store.running {
                    Button(tr("focus.stop")) { store.stop() }.controlSize(.small)
                } else {
                    Button(tr("focus.start")) { store.start() }.controlSize(.small).buttonStyle(.borderedProminent)
                }
            }
            .buttonStyle(.bordered)
            if !store.finishedMessage.isEmpty {
                Text(store.finishedMessage).font(.callout)
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
                            Button("Go") { store.set("custom", store: sessions) }
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
