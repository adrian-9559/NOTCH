#if os(macOS)
import AppKit
import Combine
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
    /// Tiempo estimado por capacidad/potencia (macOS da 0 al estar llena).
    var estimated: Bool = false
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

    /// Últimos ticks para la CPU por deltas (los ticks de mach son
    /// acumulados desde el arranque: sin deltas sale la media de toda
    /// la sesión, no el uso actual).
    private static var lastTicks: (u: Double, s: Double, idle: Double, nice: Double)?

    /// Barato (mach + batería + carga): cada 2 s en main.
    static func readLight(into s: inout MacPanelSnapshot) {
        var cpu = host_cpu_load_info_data_t()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        if withUnsafeMutablePointer(to: &cpu, {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }) == KERN_SUCCESS {
            let cur = (u: Double(cpu.cpu_ticks.0), s: Double(cpu.cpu_ticks.1),
                       idle: Double(cpu.cpu_ticks.2), nice: Double(cpu.cpu_ticks.3))
            if let last = lastTicks {
                let du = max(0, cur.u - last.u), ds = max(0, cur.s - last.s)
                let di = max(0, cur.idle - last.idle), dn = max(0, cur.nice - last.nice)
                let total = max(1, du + ds + di + dn)
                s.cpuUser = du / total * 100
                s.cpuSys = ds / total * 100
            }
            lastTicks = cur
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
    /// Si macOS no da tiempo (0 al estar casi llena), se estima con la
    /// capacidad restante y la potencia actual.
    /// La salud sale de system_profiler (lo mismo que enseña Ajustes);
    /// se cachea 15 min porque es lento y casi no cambia.
    private static var cachedHealth: (value: Double, at: Date)?

    static func readBattery() -> BatteryDetails {
        var b = BatteryDetails()
        guard let out = run("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"]) else { return b }
        func num1(_ pattern: String) -> Double? {
            guard let r = out.range(of: pattern, options: .regularExpression) else { return nil }
            let digits = out[r].replacingOccurrences(of: "[^0-9-]", with: "", options: .regularExpression)
            return Double(digits)
        }
        let full = num1(#""FullChargeCapacity"=(\d+)"#) ?? 0
        if let design = num1(#""DesignCapacity"=(\d+)"#), design > 0, full > 0 {
            b.healthPct = full / design * 100
        } else {
            b.healthPct = 0 // sin dato: se muestra "—"
        }
        // system_profiler manda: es el % que enseña Ajustes del sistema.
        // (Ojo: usa NBSP antes del %, que \s no traga.)
        if let cached = cachedHealth, Date().timeIntervalSince(cached.at) < 900 {
            b.healthPct = cached.value
        } else if let profiler = run("/usr/sbin/system_profiler", ["SPPowerDataType"]),
                  let r = profiler.range(of: "Maximum Capacity:[^0-9]*([0-9]+)", options: .regularExpression),
                  let v = Double(profiler[r].replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)) {
            b.healthPct = v
            cachedHealth = (v, Date())
        }
        let remaining = num1(#""RemainingCapacity"=(\d+)"#) ?? 0
        b.cycles = Int(num1(#""CycleCount" = (\d+)"#) ?? 0)
        let amps = num1(#""Amperage" = (-?\d+)"#) ?? 0
        let volts = num1(#""Voltage" = (\d+)"#) ?? 0
        b.watts = amps * volts / 1_000_000
        b.minutesLeft = Int(num1(#""TimeRemaining" = (\d+)"#) ?? 0)
        b.charging = out.contains(#""IsCharging" = Yes"#)
        // Estima cuando macOS no informa (0 o absurdo).
        if (b.minutesLeft <= 0 || b.minutesLeft >= 60000), full > 0, remaining > 0, volts > 0 {
            let rateMA = abs(b.watts) * 1_000_000 / volts
            let deficit = b.charging ? max(0, full - remaining) : remaining
            if rateMA > 50, deficit > 0 {
                let mins = Int((deficit / rateMA * 60).rounded())
                if mins > 0, mins < 24 * 60 {
                    b.minutesLeft = mins
                    b.estimated = true
                }
            }
        }
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
    @ObservedObject private var settings = NotchSettings.shared
    @State private var snap = MacPanelSnapshot()
    @State private var peakCpu: Double = 0
    @State private var peakAt = Date()
    @State private var chip = ""
    @State private var memGB: Double = 16
    @State private var eCores = 0
    @State private var pCores = 0
    /// Secciones plegadas (persisten): menos datos a la vista.
    @AppStorage("macFoldLoads") private var foldLoads = false
    @AppStorage("macFoldServers") private var foldServers = false
    @AppStorage("macFoldJunk") private var foldJunk = false
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
            measurementsCard
            // Qué carga el Mac (plegable).
            sectionHeader(title: tr("mac.loads"), sub: "\(Int(totalCpu.rounded()))% total", folded: $foldLoads)
            if !foldLoads {
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
                    .accessibilityLabel(tr("mac.detail", t.name))
                    .help(tr("mac.detail", t.name))
                }
                }
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.3)).frame(width: 9, height: 9)
                    Text(tr("mac.rest")).font(.notchMono(11)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
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
            }
            // Servidores de agentes (máx. 5 + resto, como Lumio).
            sectionHeader(
                title: snap.servers.count > 5 ? "\(tr("mac.servers")) +\(snap.servers.count - 5)" : tr("mac.servers"),
                folded: $foldServers
            )
            if !foldServers {
                if snap.servers.isEmpty {
                    Text(tr("mac.noServers")).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(snap.servers.prefix(5), id: \.port) { sv in
                        HStack(spacing: 8) {
                            Image(systemName: "square").font(.system(size: 9)).foregroundStyle(.secondary)
                            // verbatim: si no, el Int se localiza ("24.282").
                            Text(verbatim: ":\(sv.port) \(sv.proc)").font(.notchMono(11)).foregroundStyle(.white)
                            Text(sv.agent.map { "\($0) · \(tr("mac.running"))" } ?? tr("mac.process")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button(tr("mac.open")) { MacPanelReader.openPort(sv.port) }.controlSize(.small).buttonStyle(.bordered)
                                .tint(.green)
                            Button(tr("mac.stop")) { MacPanelReader.stopPid(sv.pid); refreshHeavy() }.controlSize(.small).buttonStyle(.bordered)
                        }
                        .font(.caption)
                    }
                }
            }
            // Limpieza de datos temporales de agentes (solo parados).
            JunkSectionView(store: sessions, junk: junk, folded: $foldJunk)
            Text(tr("mac.self", Int(snap.selfCpu.rounded()), Int(snap.selfMB.rounded())))
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

    /// Tarjeta unificada de mediciones: CPU, memoria y batería en tres
    /// carriles con divisores, cada uno con su anillo. El pico y la
    /// presión viven en su carril.
    private var measurementsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Circle().fill(Color(hex: "2F9E6E")).frame(width: 6, height: 6)
                Text(tr("mac.measurements")).font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.5)).kerning(1)
                Spacer()
                Text(chip).font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.35))
            }
            HStack(alignment: .top, spacing: 0) {
                // Carril CPU.
                VStack(spacing: 6) {
                    LaneGauge(value: "\(Int((snap.cpuUser + snap.cpuSys).rounded()))%",
                              fraction: cpuFrac, color: severityColor(fraction: cpuFrac))
                    Text("CPU").font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.45))
                    Text("E \(eCores) · P \(pCores) · \(tr("mac.peak", Int(peakCpu.rounded())))")
                        .font(.notchMono(9)).foregroundStyle(Color.white.opacity(0.45))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                laneDivider
                // Carril memoria.
                VStack(spacing: 6) {
                    LaneGauge(value: "\(Int((memFrac * 100).rounded()))%",
                              fraction: memFrac, color: severityColor(fraction: memFrac))
                    Text("MEMORY").font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.45))
                    Text(String(format: "%.1f of %.0f GB", snap.memUsedGB, snap.memTotalGB))
                        .font(.notchMono(9)).foregroundStyle(Color.white.opacity(0.45))
                    HStack(spacing: 4) {
                        Circle().fill(pressureColor).frame(width: 6, height: 6)
                        Text("\(pressureWord) · swap \(String(format: "%.0f", snap.swapUsedGB)) GB")
                            .font(.notchMono(9)).foregroundStyle(Color.white.opacity(0.45))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                laneDivider
                // Carril batería.
                batteryCard.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.07), Color.white.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
    }

    private var laneDivider: some View {
        Rectangle().fill(Color.white.opacity(0.09)).frame(width: 1)
    }

    private var pressureColor: Color {
        if snap.memFreeFrac > 0.25 { return Color(hex: "2F9E6E") }
        if snap.memFreeFrac > 0.12 { return Color(hex: "D9A514") }
        return Color(hex: "E0574B")
    }

    /// Cabecera de sección plegable (persiste en Ajustes internos).
    private func sectionHeader(title: String, sub: String = "", folded: Binding<Bool>) -> some View {
        Button {
            folded.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.5)).kerning(1)
                if !sub.isEmpty {
                    Text(sub).font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.35))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .rotationEffect(.degrees(folded.wrappedValue ? 0 : 90))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func batteryColor(_ level: Int) -> Color {
        if snap.onAC { return Color(hex: "2F9E6E") }
        return severityColor(fraction: 1 - Double(level) / 100)
    }

    private var battStateWord: String {
        if snap.battery == nil { return "" }
        if (snap.battery ?? 0) >= 99 { return snap.onAC ? tr("mac.mains") : tr("mac.full") }
        return snap.onAC ? tr("mac.charging") : tr("mac.onBattery")
    }

    /// Tarjeta de batería: logo con carga y estado + rejilla de salud.
    private var batteryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.5), lineWidth: 2)
                        .frame(width: 46, height: 23)
                    RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.5)).frame(width: 3, height: 9)
                        .offset(x: 47)
                    if let b = snap.battery {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(batteryColor(b))
                            .frame(width: max(4, 39 * CGFloat(b) / 100), height: 14)
                            .padding(.leading, 4)
                        if snap.onAC {
                            Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(.black)
                                .padding(.leading, 10)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(snap.battery.map { "\($0)%" } ?? "—")
                        .font(.notchMono(17)).foregroundStyle(.white).monospacedDigit()
                    Text(battStateWord)
                        .font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.5))
                }
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.flexible())], spacing: 4) {
                battCell(tr("mac.health"), battHealthText, battHealthColor)
                battCell(tr("mac.cycles"), snap.batt.cycles > 0 ? "\(snap.batt.cycles)" : "—", .white.opacity(0.85))
                battCell(tr("mac.power"), snap.batt.watts == 0 ? "—" : String(format: "%+.0f W", snap.batt.watts), .white.opacity(0.85))
                battCell(snap.onAC ? tr("mac.toFull") : tr("mac.left"), battTimeText, .white.opacity(0.85))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var pressureWord: String {
        if snap.memFreeFrac > 0.25 { return tr("mac.normal") }
        if snap.memFreeFrac > 0.12 { return tr("mac.tight") }
        return tr("mac.critical")
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
        a.messageText = tr("mac.termTitle", t.name)
        a.informativeText = tr("mac.termBody", Int32(t.pid), Int(t.memMB.rounded()))
        a.addButton(withTitle: tr("mac.termOk"))
        a.addButton(withTitle: tr("mac.cancel"))
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
        // Llena: no queda nada que llenar.
        if (snap.battery ?? 0) >= 99 { return "0" }
        let m = snap.batt.minutesLeft
        guard m > 0, m < 60000 else { return "—" }
        let t = String(format: "%dh %02dm", m / 60, m % 60)
        return snap.batt.estimated ? "~" + t : t
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

/// Medidor centrado: anillo grueso con el valor dentro y brillo del
/// color de carga. Para los carriles de CPU y memoria.
struct LaneGauge: View {
    var value: String
    var fraction: Double
    var color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 10)
                .frame(width: 92, height: 92)
            Circle()
                .trim(from: 0, to: max(fraction, 0.015))
                .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .frame(width: 92, height: 92)
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.45), radius: 8)
                .animation(.snappy(duration: 0.55), value: fraction)
            Text(value)
                .font(.notchMono(19))
                .monospacedDigit()
                .foregroundStyle(.white)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 100, height: 100)
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
            ? "\(row.agent)/\(row.label) \(tr("mac.toTrash"))"
            : tr("mac.trashFails", r.failed)
        scan()
    }

    func trashAll() {
        let all = rows.flatMap(\.paths)
        let r = Self.trash(paths: all)
        lastCleaned = r.failed == 0
            ? "\(Self.formatBytes(allBytes)) \(tr("mac.toTrash"))"
            : tr("mac.trashFails", r.failed)
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
/// la papelera. Solo activo con todos los agentes parados. Plegable.
struct JunkSectionView: View {
    var store: SessionStore
    @ObservedObject var junk: JunkStore
    @ObservedObject private var settings = NotchSettings.shared
    var folded: Binding<Bool>

    private var allIdle: Bool { store.active.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                folded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(tr("mac.junk")).font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.5)).kerning(1)
                    if junk.scanning {
                        Text(tr("mac.measuring")).font(.notchMono(10)).foregroundStyle(.secondary)
                    } else if !junk.rows.isEmpty {
                        Text(JunkStore.formatBytes(junk.allBytes)).font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.35)).monospacedDigit()
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .rotationEffect(.degrees(folded.wrappedValue ? 0 : 90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !folded.wrappedValue {
                junkBody
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    @ViewBuilder
    private var junkBody: some View {
        if junk.rows.isEmpty, !junk.scanning {
            Text(tr("mac.noJunk")).font(.caption).foregroundStyle(.secondary)
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
                    .help(allIdle ? tr("mac.toTrash") : tr("mac.waitAgents"))
                }
            }
            Button(allIdle ? tr("mac.cleanAll") : tr("mac.waitAgents")) {
                confirmClean()
            }
            .controlSize(.small).buttonStyle(.borderedProminent).tint(.red)
            .disabled(!allIdle || junk.rows.isEmpty)
        }
        if !junk.lastCleaned.isEmpty {
            Text(junk.lastCleaned).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func confirmClean() {
        let a = NSAlert()
        a.messageText = tr("mac.cleanTitle", JunkStore.formatBytes(junk.allBytes))
        a.informativeText = tr("mac.cleanBody", Set(junk.rows.map(\.agent)).sorted().joined(separator: ", "))
        a.addButton(withTitle: tr("mac.cleanOk"))
        a.addButton(withTitle: tr("mac.cancel"))
        if a.runModal() == .alertFirstButtonReturn {
            junk.trashAll()
        }
    }
}
#endif
