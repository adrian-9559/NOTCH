#if os(macOS)
import Darwin
import SwiftUI

// MARK: - Stats estilo Lumio: anillos simples, "what loads the mac",
// agent servers con Open/Stop y huella propia. Sin permisos.

// MARK: - Datos

struct ProcTop {
    var name: String
    var pct: Double // % de capacidad total (ps/núcleos)
}

struct AgentServer {
    var port: Int
    var proc: String
    var pid: Int32
    var agent: String?
}

struct MacPanelSnapshot {
    var cpuUser = 0.0, cpuSys = 0.0
    var memUsedGB = 0.0, memTotalGB = 0.0
    var memFreeFrac = 0.0
    var swapUsedGB = 0.0
    var battery: Int?
    var onAC = false
    var load1 = 0.0, load5 = 0.0, load15 = 0.0
    var tops: [ProcTop] = []
    var servers: [AgentServer] = []
    var selfCpu = 0.0, selfMB = 0.0
    var chip = ""
    var eCores = 0, pCores = 0
}

enum MacPanelReader {
    /// Fijo una vez (chip, núcleos).
    static func machineInfo() -> (chip: String, memGB: Double, e: Int, p: Int) {
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Apple"
        var total = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        total = (total * 10).rounded() / 10
        let e = Int(sysctlInt("hw.perflevel1.physicalcpu") ?? 0)
        let p = Int(sysctlInt("hw.perflevel0.physicalcpu") ?? 0)
        return (chip, total, e, p)
    }

    /// Barato (mach + batería + carga): cada 2 s en main.
    static func readLight(into s: inout MacPanelSnapshot) {
        var cpu = host_cpu_load_info_data_t()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        if withUnsafeMutablePointer(to: &cpu, {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }) == KERN_SUCCESS {
            let u = Double(cpu.cpu_ticks.0), sys = Double(cpu.cpu_ticks.1)
            let idle = Double(cpu.cpu_ticks.2), nice = Double(cpu.cpu_ticks.3)
            let total = max(1, u + sys + idle + nice)
            s.cpuUser = u / total * 100
            s.cpuSys = sys / total * 100
        }
        var vm = vm_statistics64_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        if withUnsafeMutablePointer(to: &vm, {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }) == KERN_SUCCESS {
            var pageSize: vm_size_t = 0
            host_page_size(mach_host_self(), &pageSize)
            let pg = Double(pageSize)
            let used = Double(vm.active_count + vm.wire_count + vm.compressor_page_count) * pg
            let free = Double(vm.free_count + vm.inactive_count) * pg
            let total = Double(ProcessInfo.processInfo.physicalMemory)
            s.memUsedGB = used / 1_073_741_824
            s.memTotalGB = total / 1_073_741_824
            s.memFreeFrac = free / max(1, total)
        }
        var l = [0.0, 0.0, 0.0]
        if getloadavg(&l, 3) == 3 { s.load1 = l[0]; s.load5 = l[1]; s.load15 = l[2] }
        s.battery = BatteryInfo.level()
        s.onAC = BatteryInfo.onAC()
    }

    /// Caro (ps, lsof, swap, huella): cada 6 s en background.
    static func readHeavy(into s: inout MacPanelSnapshot, agentPids: [Int32: String]) {
        let ncpu = max(1, Double(ProcessInfo.processInfo.activeProcessorCount))
        // Top procesos por CPU.
        if let out = run("/bin/ps", ["-Ao", "pcpu,pid,comm", "-r", "-c"]) {
            var tops: [ProcTop] = []
            for line in out.split(separator: "\n").dropFirst().prefix(6) {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 3, let raw = num(parts[0]) else { continue }
                let name = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
                if name == "ps" || name.hasSuffix("(NOTCH)") { continue }
                tops.append(ProcTop(name: shortProc(name), pct: raw / ncpu))
                if tops.count == 4 { break }
            }
            s.tops = tops
        }
        // Servidores (puertos en escucha) mapeados a agentes por subárbol.
        s.servers = listenServers(agentPids: agentPids)
        // Swap usada ("used = 17474,06M"; coma o punto según locale).
        if let out = run("/usr/sbin/sysctl", ["-n", "vm.swapusage"]) {
            // "total = 18432,00M used = 17474,06M ..." (coma según locale).
            if let r = out.range(of: #"used\s*=\s*([\d,\.]+)M"#, options: .regularExpression) {
                var num = out[r].replacingOccurrences(of: "used", with: "")
                    .replacingOccurrences(of: "=", with: "")
                    .replacingOccurrences(of: "M", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if num.contains(",") { num = num.replacingOccurrences(of: ".", with: "") }
                s.swapUsedGB = (Double(num.replacingOccurrences(of: ",", with: ".")) ?? 0) / 1024
            }
        }
        // Huella propia.
        let pid = ProcessInfo.processInfo.processIdentifier
        if let out = run("/bin/ps", ["-p", "\(pid)", "-o", "%cpu=,rss="]) {
            let parts = out.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, let cpu = num(parts[0]) {
                s.selfCpu = cpu
                s.selfMB = (Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) / 1024
            }
        }
    }

    // MARK: - servidores

    /// Puertos TCP en escucha de procesos de desarrollo, con el agente
    /// dueño si el proceso cuelga de su PID.
    static func listenServers(agentPids: [Int32: String]) -> [AgentServer] {
        guard let lsof = run("/usr/sbin/lsof", ["-iTCP", "-sTCP:LISTEN", "-P", "-n"]) else { return [] }
        // Árbol de procesos para mapear escuchas → agente.
        var children: [Int32: [Int32]] = [:]
        if let ps = run("/bin/ps", ["-Ao", "pid,ppid"]) {
            for line in ps.split(separator: "\n").dropFirst() {
                let p = line.split(separator: " ", omittingEmptySubsequences: true)
                guard p.count >= 2, let pid = Int32(p[0]), let ppid = Int32(p[1]) else { continue }
                children[ppid, default: []].append(pid)
            }
        }
        func subtree(_ pid: Int32) -> Set<Int32> {
            var seen: Set<Int32> = [pid]
            var stack = [pid]
            while let c = stack.popLast() {
                for k in children[c] ?? [] where !seen.contains(k) {
                    seen.insert(k); stack.append(k)
                }
            }
            return seen
        }
        let agentTrees = agentPids.mapValues { _ in Set<Int32>() }
        var trees: [String: Set<Int32>] = [:]
        for (pid, name) in agentPids { trees[name] = subtree(pid) }
        _ = agentTrees
        let devBins: Set<String> = ["node", "python", "php", "ruby", "go", "deno", "bun",
                                   "java", "nginx", "httpd", "caddy", "hugo", "vite", "next-server"]
        var seenPorts = Set<Int>()
        var out: [AgentServer] = []
        for line in lsof.split(separator: "\n").dropFirst() {
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            guard p.count >= 9, let pid = Int32(p[1]) else { continue }
            let name = String(p[0])
            // NAME son dos tokens ("*:8000 (LISTEN)"): el puerto va en el que lleva ':'.
            guard let addr = p.dropFirst(8).first(where: { $0.contains(":") }),
                  let portStr = addr.split(separator: ":").last,
                  let port = Int(portStr), !seenPorts.contains(port) else { continue }
            let owner = trees.first { $0.value.contains(pid) }?.key
            let lower = name.lowercased()
            let isDev = devBins.contains(where: { lower.hasPrefix($0) })
            guard owner != nil || isDev else { continue }
            seenPorts.insert(port)
            out.append(AgentServer(port: port, proc: shortProc(name), pid: pid, agent: owner))
        }
        return out.sorted { $0.port < $1.port }
    }

    // MARK: - utilidades

    /// Número con coma o punto decimal y sin saltos de línea residuales.
    static func num(_ s: Substring) -> Double? {
        Double(s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }

    static func shortProc(_ name: String) -> String {
        var n = name
        if n.hasSuffix(".app") { n = String(n.dropLast(4)) }
        return String(n.prefix(28))
    }

    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    static func sysctlString(_ key: String) -> String? {
        run("/usr/sbin/sysctl", ["-n", key])?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sysctlInt(_ key: String) -> Int64? {
        guard let s = sysctlString(key) else { return nil }
        return Int64(s)
    }

    static func openPort(_ port: Int) {
        if let url = URL(string: "http://localhost:\(port)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func stopPid(_ pid: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/kill")
        p.arguments = ["\(pid)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

// MARK: - Semáforo compartido

/// Verde → ámbar → rojo según uso (batería: según lo que queda).
func severityColor(fraction: Double) -> Color {
    if fraction > 0.8 { return Color(hex: "E0574B") }
    if fraction > 0.5 { return Color(hex: "D9A514") }
    return Color(hex: "2F9E6E")
}

// MARK: - Pestaña Mac estilo Lumio

struct StatsView: View {
    var sessions: SessionStore
    @State private var snap = MacPanelSnapshot()
    @State private var peakCpu: Double = 0
    @State private var peakAt = Date()
    @State private var chip = ""
    @State private var memGB: Double = 16
    @State private var eCores = 0
    @State private var pCores = 0
    private let light = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let heavy = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    private var cpuFrac: Double { min(1, (snap.cpuUser + snap.cpuSys) / 100) }
    private var memFrac: Double {
        snap.memTotalGB > 0 ? min(1, snap.memUsedGB / snap.memTotalGB) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("mac").font(.notchMono(11)).foregroundStyle(.secondary)
                Spacer()
                Text(chip).font(.notchMono(11)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 0) {
                LumioRing(label: "CPU", value: "\(Int((snap.cpuUser + snap.cpuSys).rounded()))%",
                          sub: "E \(eCores) · P \(pCores)", fraction: cpuFrac,
                          color: severityColor(fraction: cpuFrac))
                    .frame(maxWidth: .infinity)
                LumioRing(label: "MEMORY", value: "\(Int((memFrac * 100).rounded()))%",
                          sub: String(format: "%.1f of %.0f GB", snap.memUsedGB, snap.memTotalGB),
                          fraction: memFrac, color: severityColor(fraction: memFrac))
                    .frame(maxWidth: .infinity)
                batteryBlock.frame(maxWidth: .infinity, alignment: .leading)
            }
            // Presión de memoria + pico del último minuto.
            VStack(alignment: .leading, spacing: 3) {
                memoryBar
                HStack {
                    Text("last minute: up to \(Int(peakCpu.rounded()))%")
                    Spacer()
                    Text("\(pressureWord) · swap \(String(format: "%.0f", snap.swapUsedGB)) GB")
                }
                .font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.5))
            }
            // Qué carga el Mac.
            Text("WHAT LOADS THE MAC").font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.5)).kerning(1)
            loadBar
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                ForEach(loadRows, id: \.name) { r in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(r.color).frame(width: 9, height: 9)
                        Text(r.name).font(.notchMono(11)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                        Spacer()
                        Text("\(Int(r.pct.rounded()))%").font(.notchMono(11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            // Servidores de agentes (máx. 5 + resto, como Lumio).
            Text(snap.servers.count > 5 ? "AGENT SERVERS +\(snap.servers.count - 5)" : "AGENT SERVERS")
                .font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.5)).kerning(1)
            if snap.servers.isEmpty {
                Text("sin servidores en escucha").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(snap.servers.prefix(5), id: \.port) { sv in
                    HStack(spacing: 8) {
                        Image(systemName: "square").font(.system(size: 9)).foregroundStyle(.secondary)
                        // verbatim: si no, el Int se localiza ("24.282").
                        Text(verbatim: ":\(sv.port) \(sv.proc)").font(.notchMono(11)).foregroundStyle(.white)
                        Text(sv.agent.map { "\($0) · running" } ?? "proceso").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Open") { MacPanelReader.openPort(sv.port) }.controlSize(.small).buttonStyle(.bordered)
                            .tint(.green)
                        Button("Stop") { MacPanelReader.stopPid(sv.pid); refreshHeavy() }.controlSize(.small).buttonStyle(.bordered)
                    }
                    .font(.caption)
                }
            }
            Text("NOTCH itself uses \(String(format: "%.0f", snap.selfCpu))% · \(String(format: "%.0f", snap.selfMB)) MB")
                .font(.notchMono(9)).foregroundStyle(Color.white.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(8)
        .onAppear {
            let info = MacPanelReader.machineInfo()
            chip = "\(info.chip) · \(String(format: "%.0f", info.memGB)) GB"
            memGB = info.memGB; eCores = info.e; pCores = info.p
            refreshLight()
            refreshHeavy()
        }
        .onReceive(light) { _ in refreshLight() }
        .onReceive(heavy) { _ in refreshHeavy() }
    }

    // MARK: - piezas

    private var batteryBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BATTERY").font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.45))
            HStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.5), lineWidth: 2)
                        .frame(width: 40, height: 20)
                    RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.5)).frame(width: 3, height: 8)
                        .offset(x: 41)
                    if let b = snap.battery {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(batteryColor(b))
                            .frame(width: max(4, 34 * CGFloat(b) / 100), height: 12)
                            .padding(.leading, 3)
                        if snap.onAC {
                            Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(.black)
                                .padding(.leading, 8)
                        }
                    }
                }
                Text(snap.battery.map { "\($0)%" } ?? "—")
                    .font(.notchMono(16)).foregroundStyle(.white).monospacedDigit()
            }
            Text(snap.battery.map { $0 >= 99 ? "llena" : (snap.onAC ? "charging" : "en batería") } ?? "sin batería")
                .font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.5))
        }
    }

    private func batteryColor(_ level: Int) -> Color {
        if snap.onAC { return Color(hex: "2F9E6E") }
        return severityColor(fraction: 1 - Double(level) / 100)
    }

    private var pressureWord: String {
        if snap.memFreeFrac > 0.25 { return "normal" }
        if snap.memFreeFrac > 0.12 { return "tight" }
        return "critical"
    }

    private var memoryBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(severityColor(fraction: memFrac))
                    .frame(width: max(4, geo.size.width * memFrac))
            }
        }
        .frame(height: 6)
    }

    private var totalCpu: Double { (snap.cpuUser + snap.cpuSys) }

    private var loadBar: some View {
        let top = snap.tops.prefix(3)
        let sum = top.reduce(0) { $0 + $1.pct }
        let rest = max(0, totalCpu - sum)
        let all = sum + rest
        return GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(top.enumerated()), id: \.offset) { i, t in
                    RoundedRectangle(cornerRadius: 2)
                        .fill([Color(hex: "2F9E6E"), Color(hex: "2F9E6E").opacity(0.65), Color(hex: "2F9E6E").opacity(0.4)][i % 3])
                        .frame(width: all > 0 ? max(3, geo.size.width * t.pct / all) : 0)
                }
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.18))
            }
        }
        .frame(height: 8)
    }

    private var loadRows: [(name: String, pct: Double, color: Color)] {
        var rows = snap.tops.prefix(3).enumerated().map { i, t in
            (t.name, t.pct, [Color(hex: "2F9E6E"), Color(hex: "2F9E6E").opacity(0.65), Color(hex: "2F9E6E").opacity(0.4)][i % 3])
        }
        let sum = snap.tops.prefix(3).reduce(0) { $0 + $1.pct }
        rows.append(("macOS & the rest", max(0, totalCpu - sum), Color.white.opacity(0.3)))
        return rows
    }

    // MARK: - refrescos

    private func refreshLight() {
        MacPanelReader.readLight(into: &snap)
        let total = snap.cpuUser + snap.cpuSys
        if Date().timeIntervalSince(peakAt) > 60 {
            peakCpu = total; peakAt = Date()
        } else {
            peakCpu = max(peakCpu, total)
        }
    }

    private func refreshHeavy() {
        var copy = snap
        let table: [Int32: String] = sessions.sessions.reduce(into: [:]) { d, s in
            if let p = s.pid { d[p] = s.agent.displayName }
        }
        DispatchQueue.global(qos: .utility).async {
            MacPanelReader.readHeavy(into: &copy, agentPids: table)
            DispatchQueue.main.async { self.snap = copy }
        }
    }
}

/// Anillo simple estilo Lumio: anillo a la izquierda y textos a la
/// derecha (rótulo arriba, valor gigante, sub debajo).
struct LumioRing: View {
    var label: String
    var value: String
    var sub: String
    var fraction: Double
    var color: Color

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.13), lineWidth: 7)
                    .frame(width: 72, height: 72)
                Circle()
                    .trim(from: 0, to: max(fraction, 0.015))
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .frame(width: 72, height: 72)
                    .rotationEffect(.degrees(-90))
                    .animation(.snappy(duration: 0.55), value: fraction)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.45))
                Text(value).font(.notchMono(17)).foregroundStyle(.white).monospacedDigit()
                Text(sub).font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.55)).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }
}
#endif
