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
                self.finishedMessage = "Hora de descansar la vista 👀"
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
    var body: some View {
        VStack(spacing: 6) {
            Text("timer").font(.notchMono(11)).foregroundStyle(.secondary)
            ZStack {
                ProgressView(value: store.progress)
                    .progressViewStyle(.circular)
                    .scaleEffect(2.2)
                    .padding(14)
                Text(store.running ? store.label : "\(store.minutes) min")
                    .font(.notchMono(16))
            }
            Stepper("Minutos: \(store.minutes)", value: $store.minutes, in: 1...180, step: 5)
                .font(.caption).disabled(store.running)
            HStack {
                ForEach([5, 20, 25, 50], id: \.self) { m in
                    Button("\(m)'") { store.minutes = m }.controlSize(.small)
                }
                Spacer()
                if store.running {
                    Button("Parar") { store.stop() }.controlSize(.small)
                } else {
                    Button("Empezar") { store.start() }.controlSize(.small).buttonStyle(.borderedProminent)
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

// MARK: - Keep awake (caffeinate)

final class AwakeStore: ObservableObject {
    @Published var mode = "off" // off | 30m | 1h | 2h | auto
    @Published var active = false
    private var proc: Process?

    func set(_ newMode: String, store: SessionStore? = nil) {
        stop()
        mode = newMode
        switch newMode {
        case "30m": start(seconds: 1800)
        case "1h": start(seconds: 3600)
        case "2h": start(seconds: 7200)
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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        var args = ["-dimsu"]
        if seconds > 0 { args += ["-t", "\(seconds)"] }
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); proc = p; active = true } catch { active = false }
    }

    func stop() {
        autoTimer?.invalidate()
        stopProcOnly()
        mode = "off"
    }

    private func stopProcOnly() {
        proc?.terminate()
        proc = nil
        active = false
    }
}

struct AwakeView: View {
    @ObservedObject var store: AwakeStore
    var sessions: SessionStore?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("keep awake").font(.notchMono(11)).foregroundStyle(.secondary)
            HStack {
                ForEach([("off", "Off"), ("30m", "30m"), ("1h", "1h"), ("2h", "2h"), ("auto", "Auto")], id: \.0) { key, label in
                    if store.mode == key {
                        Button(label) { store.set(key, store: sessions) }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(label) { store.set(key, store: sessions) }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                    }
                }
            }
            if store.active { Text("Despierto").font(.caption2).foregroundStyle(.green) }
        }
        .padding(8)
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
