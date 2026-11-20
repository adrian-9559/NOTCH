#if os(macOS)
import Darwin
import SwiftUI

// MARK: - Stats: CPU, memoria, batería (mach + getloadavg, sin permisos)

struct MachineStats {
    var cpuUser = 0.0, cpuSys = 0.0
    var memUsedGB = 0.0, memTotalGB = 0.0
    var battery: Int?
    var onAC = false
}

enum StatsReader {
    static func read() -> MachineStats {
        var s = MachineStats()
        // CPU
        var cpu = host_cpu_load_info_data_t()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let cpuOK = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        } == KERN_SUCCESS
        if cpuOK {
            let u = Double(cpu.cpu_ticks.0), sys = Double(cpu.cpu_ticks.1)
            let idle = Double(cpu.cpu_ticks.2), nice = Double(cpu.cpu_ticks.3)
            let total = max(1, u + sys + idle + nice)
            s.cpuUser = u / total * 100
            s.cpuSys = sys / total * 100
        }
        // Memoria
        var vm = vm_statistics64_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let vmOK = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        } == KERN_SUCCESS
        if vmOK {
            var pageSize: vm_size_t = 0
            host_page_size(mach_host_self(), &pageSize)
            let used = Double(vm.active_count + vm.wire_count + vm.compressor_page_count) * Double(pageSize)
            let total = Double(ProcessInfo.processInfo.physicalMemory)
            s.memUsedGB = used / 1_073_741_824
            s.memTotalGB = total / 1_073_741_824
        }
        s.battery = BatteryInfo.level()
        s.onAC = BatteryInfo.onAC()
        return s
    }

    /// Carga media 1/5/15 min (Darwin getloadavg, sin permisos).
    static func loadAverage() -> (Double, Double, Double) {
        var l = [0.0, 0.0, 0.0]
        guard getloadavg(&l, 3) == 3 else { return (0, 0, 0) }
        return (l[0], l[1], l[2])
    }
}

// MARK: - Pestaña Mac: medidores tipo reloj con semáforo de uso

struct StatsView: View {
    var sessions: SessionStore
    @State private var stats = MachineStats()
    @State private var load: (Double, Double, Double) = (0, 0, 0)
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var cpuFrac: Double { min(1, (stats.cpuUser + stats.cpuSys) / 100) }
    private var memFrac: Double {
        stats.memTotalGB > 0 ? min(1, stats.memUsedGB / stats.memTotalGB) : 0
    }
    private var batFrac: Double { stats.battery.map { Double($0) / 100 } ?? 0 }

    private var topAgent: String {
        let ranked = sessions.sessions.sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }
        guard let top = ranked.first, (top.cpuPercent ?? 0) > 0.5 else { return "—" }
        return "\(top.agent.displayName) \(String(format: "%.1f", top.cpuPercent ?? 0))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Tres relojes: uso con color según carga.
            HStack(spacing: 0) {
                UsageGauge(
                    label: "cpu",
                    value: "\(Int((stats.cpuUser + stats.cpuSys).rounded()))%",
                    sub: String(format: "u%.0f · s%.0f", stats.cpuUser, stats.cpuSys),
                    fraction: cpuFrac
                )
                .frame(maxWidth: .infinity)

                UsageGauge(
                    label: "mem",
                    value: String(format: "%.0f%%", memFrac * 100),
                    sub: String(format: "%.1f/%.0f GB", stats.memUsedGB, stats.memTotalGB),
                    fraction: memFrac
                )
                .frame(maxWidth: .infinity)

                UsageGauge(
                    label: "bat",
                    value: stats.battery.map { "\($0)%" } ?? "—",
                    sub: stats.battery.map { $0 >= 99 ? "llena" : (stats.onAC ? "cargando ⚡" : "en batería") } ?? "sin batería",
                    fraction: batFrac,
                    available: stats.battery != nil
                )
                .frame(maxWidth: .infinity)
            }

            // Fila de datos: carga media + agente que más carga.
            HStack(spacing: 8) {
                StatChip(
                    title: "carga 1/5/15",
                    value: String(format: "%.1f  %.1f  %.1f", load.0, load.1, load.2),
                    tint: UsageGauge.severity(fraction: min(1, load.0 / Double(max(1, ProcessInfo.processInfo.activeProcessorCount))))
                )
                StatChip(title: "carga del mac", value: topAgent, tint: Color(hex: "7C5CFF"))
            }
        }
        .padding(.vertical, 4)
        .onAppear { refresh() }
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        stats = StatsReader.read()
        load = StatsReader.loadAverage()
    }
}

/// Reloj circular: ticks alrededor + arco con color de semáforo
/// (verde ≤50%, ámbar ≤80%, rojo >80%) y valor gigante en el centro.
/// Estilo: medidores del timer/awake de Lumio.
struct UsageGauge: View {
    var label: String
    var value: String
    var sub: String
    var fraction: Double
    var available: Bool = true

    private let ticks = 40

    /// Semáforo: verde → ámbar → rojo según uso.
    static func severity(fraction: Double) -> Color {
        if fraction > 0.8 { return Color(hex: "E0574B") }
        if fraction > 0.5 { return Color(hex: "D9A514") }
        return Color(hex: "2F9E6E")
    }

    private var severity: Color {
        available ? Self.severity(fraction: fraction) : Color.white.opacity(0.35)
    }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                // Anillo de ticks: encendidos hasta el valor actual.
                ForEach(0..<ticks, id: \.self) { i in
                    let f = Double(i) / Double(ticks)
                    Capsule()
                        .fill(f <= fraction ? severity : Color.white.opacity(0.13))
                        .frame(width: 2, height: 6)
                        .offset(y: -43)
                        .rotationEffect(.degrees(f * 360))
                }
                // Pista + arco de progreso con punta redonda.
                Circle()
                    .stroke(Color.white.opacity(0.07), lineWidth: 3)
                    .frame(width: 74, height: 74)
                Circle()
                    .trim(from: 0, to: max(fraction, 0.012))
                    .stroke(
                        severity,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .frame(width: 74, height: 74)
                    .rotationEffect(.degrees(-90))
                    .animation(.snappy(duration: 0.55), value: fraction)
                // Valor en el centro.
                VStack(spacing: 1) {
                    Text(value)
                        .font(.notchMono(16))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text(label)
                        .font(.notchMono(9))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
            .frame(width: 92, height: 92)

            Text(sub)
                .font(.notchMono(9))
                .monospacedDigit()
                .foregroundStyle(severity.opacity(0.95))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .help("\(label): \(value)")
    }
}

/// Chip de dato orgánico: tarjeta tintada con rótulo mono y valor grande.
private struct StatChip: View {
    var title: String
    var value: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.notchMono(9))
                .kerning(1)
                .foregroundStyle(Color.white.opacity(0.45))
            Text(value)
                .font(.notchMono(12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        )
    }
}
#endif
