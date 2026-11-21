#if os(macOS)
import AppKit
import Darwin
import SwiftUI

// MARK: - Stats estilo Lumio: anillos simples, "what loads the mac",
// agent servers con Open/Stop y huella propia. Sin permisos.

// MARK: - Datos

struct ProcTop {
    var name: String
    var pct: Double // % de capacidad total (ps/núcleos)
    var pid: Int32 = 0
    var memMB: Double = 0
    var user: String = ""
    var etime: String = ""
}

struct BatteryDetails {
    var healthPct: Double = 100
    var cycles: Int = 0
    var watts: Double = 0 // + cargando, - descargando
    var minutesLeft: Int = 0
    var charging: Bool = false
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
    var batt = BatteryDetails()
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
        // Top procesos por CPU (con PID, MEM, usuario y tiempo).
        if let out = run("/bin/ps", ["-Ao", "pcpu,rss,pid,user,etime,comm", "-r", "-c"]) {
            var tops: [ProcTop] = []
            for line in out.split(separator: "\n").dropFirst().prefix(8) {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 6, let raw = num(parts[0]) else { continue }
                let name = String(parts[5]).trimmingCharacters(in: .whitespacesAndNewlines)
                if name == "ps" || name.hasSuffix("(NOTCH)") { continue }
                let memKB = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                tops.append(ProcTop(
                    name: shortProc(name), pct: raw / ncpu,
                    pid: Int32(parts[2]) ?? 0, memMB: memKB / 1024,
                    user: String(parts[3]), etime: String(parts[4])
                ))
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
        // Batería extendida (ioreg, sin sudo).
        s.batt = readBattery()
    }

    /// Salud, ciclos, potencia, tiempo restante y estado de la batería.
    static func readBattery() -> BatteryDetails {
        var b = BatteryDetails()
        guard let out = run("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"]) else { return b }
        func num1(_ pattern: String) -> Double? {
            guard let r = out.range(of: pattern, options: .regularExpression) else { return nil }
            let digits = out[r].replacingOccurrences(of: "[^0-9-]", with: "", options: .regularExpression)
            return Double(digits)
        }
        if let full = num1(#""FullChargeCapacity"=(\d+)"#),
           let design = num1(#""DesignCapacity"=(\d+)"#), design > 0 {
            b.healthPct = full / design * 100
        }
        b.cycles = Int(num1(#""CycleCount" = (\d+)"#) ?? 0)
        let amps = num1(#""Amperage" = (-?\d+)"#) ?? 0
        let volts = num1(#""Voltage" = (\d+)"#) ?? 0
        b.watts = amps * volts / 1_000_000
        b.minutesLeft = Int(num1(#""TimeRemaining" = (\d+)"#) ?? 0)
        b.charging = out.contains(#""IsCharging" = Yes"#)
        return b
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
        // Leer ANTES de esperar: si la salida supera el buffer del pipe
        // (64 KB), esperar primero cuelga al hijo escribiendo (deadlock).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
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
    /// Proceso desplegado (detalle + terminar).
    @State private var expandedPid: Int32 = 0
    @StateObject private var junk = JunkStore()
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
                ForEach(loadTops, id: \.name) { t in
                    Button {
                        expandedPid = expandedPid == t.pid ? 0 : t.pid
                    } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(loadColor(t)).frame(width: 9, height: 9)
                            Text(t.name).font(.notchMono(11)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                            Spacer()
                            Text(verbatim: "\(Int(t.pct.rounded()))%").font(.notchMono(11)).foregroundStyle(.secondary).monospacedDigit()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.3))
                                .rotationEffect(.degrees(expandedPid == t.pid ? 90 : 0))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(expandedPid == t.pid ? Color.white.opacity(0.09) : Color.white.opacity(0.03))
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Detalle de \(t.name)")
                    .help("Detalle del proceso")
                }
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.3)).frame(width: 9, height: 9)
                Text("macOS & the rest").font(.notchMono(11)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                Spacer()
                Text(verbatim: "\(Int(loadRest.rounded()))%").font(.notchMono(11)).foregroundStyle(.secondary).monospacedDigit()
            }
            // Detalle del proceso desplegado: para entender y optimizar.
            if let t = loadTops.first(where: { $0.pid == expandedPid }) {
                HStack(spacing: 8) {
                    Text(verbatim: "PID \(t.pid) · \(Int(t.memMB.rounded())) MB · \(t.user) · \(t.etime)")
                        .font(.notchMono(10)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if t.pid > 500 {
                        Button("Terminar") { confirmStop(t) }
                            .controlSize(.mini).buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
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
            // Batería extendida: salud, ciclos, potencia y tiempo.
            Text("BATERÍA").font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.5)).kerning(1)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                battCell("Salud", battHealthText, battHealthColor)
                battCell("Ciclos", snap.batt.cycles > 0 ? "\(snap.batt.cycles)" : "—", .white.opacity(0.85))
                battCell("Potencia", snap.batt.watts == 0 ? "—" : String(format: "%+.0f W", snap.batt.watts), .white.opacity(0.85))
                battCell("Restan", battTimeText, .white.opacity(0.85))
            }
            // Limpieza de datos temporales de agentes (solo parados).
            JunkSectionView(store: sessions, junk: junk)
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
            junk.scan()
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

    private var loadTops: [ProcTop] { Array(snap.tops.prefix(3)) }

    private var loadRest: Double {
        let sum = loadTops.reduce(0) { $0 + $1.pct }
        return max(0, totalCpu - sum)
    }

    private func loadColor(_ t: ProcTop) -> Color {
        let i = loadTops.firstIndex { $0.name == t.name } ?? 0
        return [Color(hex: "2F9E6E"), Color(hex: "2F9E6E").opacity(0.65), Color(hex: "2F9E6E").opacity(0.4)][i % 3]
    }

    /// Terminar con confirmación (solo PIDs de usuario, nunca sistema).
    private func confirmStop(_ t: ProcTop) {
        let a = NSAlert()
        a.messageText = "Terminar \(t.name)?"
        a.informativeText = "PID \(t.pid) · \(Int(t.memMB.rounded())) MB. Se envía SIGTERM."
        a.addButton(withTitle: "Terminar")
        a.addButton(withTitle: "Cancelar")
        if a.runModal() == .alertFirstButtonReturn {
            MacPanelReader.stopPid(t.pid)
            refreshHeavy()
        }
    }

    // MARK: - batería extendida

    private var battHealthText: String {
        snap.batt.healthPct <= 0 ? "—" : "\(Int(snap.batt.healthPct.rounded()))%"
    }

    private var battHealthColor: Color {
        let h = snap.batt.healthPct
        if h <= 0 { return .white.opacity(0.35) }
        if h >= 80 { return Color(hex: "2F9E6E") }
        if h >= 60 { return Color(hex: "D9A514") }
        return Color(hex: "E0574B")
    }

    private var battTimeText: String {
        let m = snap.batt.minutesLeft
        guard m > 0, m < 60000 else { return "—" }
        return String(format: "%dh %02dm", m / 60, m % 60)
    }

    private func battCell(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.45))
            Spacer()
            Text(value).font(.notchMono(11)).foregroundStyle(color).monospacedDigit()
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
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

// MARK: - Limpieza de datos temporales de agentes

/// Una papelera candidata: etiqueta, rutas y tamaño medido.
struct JunkRow: Identifiable {
    let id: String
    var agent: String
    var label: String
    var paths: [String]
    var bytes: Int64 = 0
}

/// Basura regenerable de los agentes (historiales, snapshots, logs,
/// cachés, worktrees, temporales). Solo existe si la ruta existe.
/// La papelera del Finder lo hace recuperable; además solo se activa
/// con todos los agentes parados.
final class JunkStore: ObservableObject {
    @Published var rows: [JunkRow] = []
    @Published var scanning = false
    @Published var lastCleaned = ""

    /// Destinos conocidos por familia (se filtran los inexistentes).
    static func targets() -> [(agent: String, rows: [(label: String, paths: [String])])] {
        let h = FileManager.default.homeDirectoryForCurrentUser.path
        let tmp = NSTemporaryDirectory()
        return [
            (agent: "OpenCode", rows: [
                ("sesiones", ["\(h)/.local/share/opencode/opencode.db", "\(h)/.local/share/opencode/opencode.db-wal", "\(h)/.local/share/opencode/opencode.db-shm"]),
                ("snapshots", ["\(h)/.local/share/opencode/snapshot"]),
                ("worktrees", ["\(h)/.local/share/opencode/worktree"]),
                ("logs", ["\(h)/.local/share/opencode/log"]),
                ("shell", ["\(h)/.local/share/opencode/shell", "\(h)/.local/share/opencode/tool-output"]),
                ("temporales", ["\(tmp)/opencode-pty-501"]),
            ]),
            (agent: "Codex", rows: [
                ("logs", ["\(h)/.codex/logs_2.sqlite", "\(h)/.codex/logs_2.sqlite-shm", "\(h)/.codex/logs_2.sqlite-wal"]),
                ("cola", ["\(h)/.codex/queue_1.sqlite", "\(h)/.codex/queue_1.sqlite-shm", "\(h)/.codex/queue_1.sqlite-wal"]),
            ]),
            (agent: "Claude", rows: [
                ("sesiones", ["\(h)/.claude/sessions", "\(h)/.claude/session-env"]),
                ("backups", ["\(h)/.claude/backups", "\(h)/.claude/ide"]),
            ]),
            (agent: "Cursor", rows: [
                ("cachés", ["\(h)/Library/Application Support/Cursor/Cache", "\(h)/Library/Application Support/Cursor/logs", "\(h)/Library/Application Support/Cursor/Crashpad"]),
                ("workspaces", ["\(h)/Library/Application Support/Cursor/User/workspaceStorage"]),
            ]),
            (agent: "VS Code", rows: [
                ("cachés", ["\(h)/Library/Application Support/Code/Cache", "\(h)/Library/Application Support/Code/CachedData", "\(h)/Library/Application Support/Code/GPUCache", "\(h)/Library/Application Support/Code/logs", "\(h)/Library/Application Support/Code/Crashpad"]),
                ("workspaces", ["\(h)/Library/Application Support/Code/User/workspaceStorage"]),
            ]),
            (agent: "Gemini", rows: [
                ("temporales", ["\(h)/.gemini/tmp", "\(h)/.gemini/cache"]),
            ]),
        ]
    }

    /// Mide con `du` en background (rápido, sin permisos).
    func scan() {
        scanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var out: [JunkRow] = []
            let fm = FileManager.default
            for fam in Self.targets() {
                for r in fam.rows {
                    let live = r.paths.filter { fm.fileExists(atPath: $0) }
                    guard !live.isEmpty else { continue }
                    let kb = Self.duKB(live)
                    guard kb > 0 else { continue }
                    out.append(JunkRow(id: "\(fam.agent)/\(r.label)", agent: fam.agent,
                                       label: r.label, paths: live, bytes: kb * 1024))
                }
            }
            out.sort { $0.bytes > $1.bytes }
            DispatchQueue.main.async {
                self.rows = out
                self.scanning = false
            }
        }
    }

    static func duKB(_ paths: [String]) -> Int64 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-sk"] + paths
        let pipe = Pipe(); p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return 0 }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").compactMap { Int($0.split(separator: "\t").first ?? "") }.reduce(Int64(0)) { $0 + Int64($1) }
    }

    /// A la papelera del Finder (recuperable). Devuelve movidos y fallos.
    @discardableResult
    static func trash(paths: [String]) -> (moved: Int, failed: Int) {
        var moved = 0, failed = 0
        for path in paths {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                moved += 1
            } catch {
                failed += 1
            }
        }
        return (moved, failed)
    }

    func trashRow(_ row: JunkRow) {
        let r = Self.trash(paths: row.paths)
        lastCleaned = r.failed == 0
            ? "\(row.agent)/\(row.label) → papelera"
            : "\(row.agent)/\(row.label): \(r.failed) fallos"
        scan()
    }

    func trashAll() {
        let all = rows.flatMap(\.paths)
        let r = Self.trash(paths: all)
        lastCleaned = r.failed == 0
            ? "\(Self.formatBytes(allBytes)) → papelera"
            : "Papelera con \(r.failed) fallos"
        scan()
    }

    var allBytes: Int64 { rows.reduce(0) { $0 + $1.bytes } }

    static func formatBytes(_ b: Int64) -> String {
        if b >= 1_073_741_824 { return String(format: "%.1f GB", Double(b) / 1_073_741_824) }
        if b >= 1_048_576 { return String(format: "%.0f MB", Double(b) / 1_048_576) }
        return "\(max(1, Int(b / 1024))) MB"
    }
}

/// Sección LIMPIEZA: qué basura hay por agente y botón para llevarla a
/// la papelera. Solo activo con todos los agentes parados.
struct JunkSectionView: View {
    var store: SessionStore
    @ObservedObject var junk: JunkStore

    private var allIdle: Bool { store.active.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LIMPIEZA").font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.5)).kerning(1)
                Spacer()
                if junk.scanning {
                    Text("midiendo…").font(.notchMono(10)).foregroundStyle(.secondary)
                } else if !junk.rows.isEmpty {
                    Text(JunkStore.formatBytes(junk.allBytes)).font(.notchMono(10)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if junk.rows.isEmpty, !junk.scanning {
                Text("sin basura de agentes").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(junk.rows) { row in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(agentColor(for: row.agent, default: Color.gray))
                            .frame(width: 7, height: 7)
                        Text("\(row.agent) · \(row.label)")
                            .font(.notchMono(11)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                        Spacer()
                        Text(JunkStore.formatBytes(row.bytes))
                            .font(.notchMono(10)).foregroundStyle(.secondary).monospacedDigit()
                        Button {
                            junk.trashRow(row)
                        } label: {
                            Image(systemName: "trash").font(.system(size: 10))
                        }
                        .buttonStyle(.bordered).controlSize(.mini)
                        .disabled(!allIdle)
                        .help(allIdle ? "A la papelera (recuperable)" : "Para cuando paren los agentes")
                    }
                }
                Button(allIdle ? "Limpiar todo → papelera" : "Para cuando paren los agentes") {
                    confirmClean()
                }
                .controlSize(.small).buttonStyle(.borderedProminent).tint(.red)
                .disabled(!allIdle || junk.rows.isEmpty)
            }
            if !junk.lastCleaned.isEmpty {
                Text(junk.lastCleaned).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private func confirmClean() {
        let a = NSAlert()
        a.messageText = "Llevar \(JunkStore.formatBytes(junk.allBytes)) a la papelera?"
        a.informativeText = "Basura regenerable de \(Set(junk.rows.map(\.agent)).sorted().joined(separator: ", ")) (historiales, snapshots, logs, cachés). Recuperable desde la papelera."
        a.addButton(withTitle: "Limpiar")
        a.addButton(withTitle: "Cancelar")
        if a.runModal() == .alertFirstButtonReturn {
            junk.trashAll()
        }
    }
}
#endif
