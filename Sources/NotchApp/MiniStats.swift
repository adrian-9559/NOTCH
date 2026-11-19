#if os(macOS)
import Darwin
import SwiftUI

// MARK: - Stats: CPU, memoria, batería y qué agente carga el Mac

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
}

struct StatsView: View {
    var sessions: SessionStore
    @State private var stats = MachineStats()
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var topAgent: String {
        let ranked = sessions.sessions.sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }
        guard let top = ranked.first, (top.cpuPercent ?? 0) > 0.5 else { return "—" }
        return "\(top.agent.displayName) (\(String(format: "%.1f", top.cpuPercent ?? 0))%)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("mac").font(.notchMono(11)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text("CPU").font(.caption2).foregroundStyle(.secondary)
                    Text(String(format: "%.0f%%", stats.cpuUser + stats.cpuSys)).font(.notchMono(15))
                }
                VStack(alignment: .leading) {
                    Text("Mem").font(.caption2).foregroundStyle(.secondary)
                    Text(String(format: "%.1f/%.0f GB", stats.memUsedGB, stats.memTotalGB)).font(.notchMono(15))
                }
                VStack(alignment: .leading) {
                    Text("Bat").font(.caption2).foregroundStyle(.secondary)
                    Text(stats.battery.map { "\($0)%\(stats.onAC ? " ⚡" : "")" } ?? "—").font(.notchMono(15))
                }
                Spacer()
            }
            Text("Carga: \(topAgent)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .onAppear { stats = StatsReader.read() }
        .onReceive(timer) { _ in stats = StatsReader.read() }
    }
}
#endif
