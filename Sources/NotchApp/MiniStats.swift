#if os(macOS)
import AppKit
import Combine
import Darwin
import NotchCore
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
                if tops.count == 8 { break }
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
        // En batería ioreg a veces devuelve un crudo absurdo (acumulador
        // sin signo): fuera de rango = sin dato (se muestra "—").
        if abs(b.watts) > 500 { b.watts = 0 }
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

/// Altura natural de cada columna de la pareja (loads/servers).
private struct ColHeightKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        for (k, v) in nextValue() { value[k] = v }
    }
}

struct StatsView: View {
    var sessions: SessionStore
    @ObservedObject private var settings = NotchSettings.shared
    @ObservedObject private var history = HistoryStore.shared
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
    @AppStorage("macFoldDay") private var foldDay = false
    /// Proceso desplegado (detalle + terminar).
    @State private var expandedPid: Int32 = 0
    @StateObject private var junk = JunkStore()
    /// Orden y búsqueda de la tabla de procesos.
    @State private var sortByCpu = true
    @State private var procQuery = ""
    /// Alturas naturales de las dos columnas (para igualarlas).
    @State private var naturalHeights: [String: CGFloat] = [:]
    /// "Ver más": expandir la pareja a altura libre.
    @State private var expandPair = false
    /// Sparklines de 90 s (una muestra por refresco ligero).
    @State private var cpuHist: [Double] = []
    @State private var memHist: [Double] = []
    private let light = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let heavy = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    private var cpuFrac: Double { min(1, (snap.cpuUser + snap.cpuSys) / 100) }
    private var memFrac: Double {
        snap.memTotalGB > 0 ? min(1, snap.memUsedGB / snap.memTotalGB) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            measurementsCard
            // Arriba: la actividad de las últimas 24 h.
            foldCard(title: tr("mac.last24"), icon: "chart.bar.fill", folded: $foldDay) {
                DayChart(hours: history.last24h())
            }
            // Qué carga el Mac y los servidores: uno al lado del otro,
            // a la MISMA altura (la de la columna más baja); si uno
            // desborda, su "Ver más" lo expande.
            let loadsNat = naturalHeights["loads"] ?? 0
            let serversNat = naturalHeights["servers"] ?? 0
            let pairCap: CGFloat? = {
                guard !expandPair, loadsNat > 0, serversNat > 0 else { return nil }
                let lo = min(loadsNat, serversNat)
                return max(loadsNat, serversNat) > lo + 4 ? lo : nil
            }()
            HStack(alignment: .top, spacing: 10) {
                // Qué carga el Mac (plegable): tabla ordenable con buscador.
                foldCard(title: tr("mac.loads"), sub: "\(Int(totalCpu.rounded()))% total",
                         icon: "list.bullet.rectangle", folded: $foldLoads,
                         compact: !expandPair) {
                    // Compacto: sin filtros; «ver más» los devuelve
                    // junto con la cabecera, al expandir lo de dentro.
                    if expandPair {
                        HStack(spacing: 6) {
                            NotchSegments(
                                selection: $sortByCpu,
                                options: [(true, "CPU"), (false, "MEM")],
                                color: settings.accent
                            )
                            NotchTextField(
                                placeholder: tr("mac.search"), text: $procQuery,
                                icon: "magnifyingglass",
                                color: settings.accent, font: .caption
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    if sortedProcs.isEmpty {
                        Text(tr("mac.noMatch")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        // Ranking compacto con barra proporcional detrás:
                        // se entiende de un vistazo qué carga la máquina.
                        let maxMem = max(1, sortedProcs.map(\.memMB).max() ?? 1)
                        ForEach(sortedProcs.prefix(6), id: \.pid) { t in
                            ProcRow(
                                t: t, color: procColor(t),
                                value: sortByCpu ? "\(Int(t.pct.rounded()))%" : memMBString(t.memMB),
                                fraction: CGFloat(min(1, sortByCpu
                                    ? t.pct / max(1, totalCpu)
                                    : t.memMB / maxMem)),
                                expanded: expandedPid == t.pid,
                                onToggle: { expandedPid = expandedPid == t.pid ? 0 : t.pid }
                            )
                        }
                    }
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.3)).frame(width: 9, height: 9)
                        Text(tr("mac.rest")).font(.notchMono(11)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                        Spacer()
                        Text(verbatim: "\(Int(loadRest.rounded()))%").font(.notchMono(11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    // Detalle del proceso desplegado: para entender y optimizar.
                    if let t = snap.tops.first(where: { $0.pid == expandedPid }) {
                        HStack(spacing: 8) {
                            Text(verbatim: "PID \(t.pid) · \(Int(t.memMB.rounded())) MB · \(t.user) · \(t.etime)")
                                .font(.notchMono(10)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            if t.pid > 500 {
                                Button(tr("mac.terminate")) { confirmStop(t) }
                                    .buttonStyle(NotchGhostButton(size: .mini))
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
                    }
                }
                .background(heightReporter("loads"))
                .frame(height: pairCap)
                .clipped()
                .overlay(alignment: .bottom) { pairMore(loadsNat, cap: pairCap, force: !expandPair) }
                // Servidores de agentes (máx. 5 + resto, como Lumio).
                foldCard(
                    title: tr("mac.servers"),
                    sub: snap.servers.count > 5 ? "+\(snap.servers.count - 5)" : "",
                    icon: "network", folded: $foldServers
                ) {
                    if snap.servers.isEmpty {
                        Text(tr("mac.noServers")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(snap.servers.prefix(5), id: \.port) { sv in
                            HStack(spacing: 8) {
                                Image(systemName: "square").font(.system(size: 9)).foregroundStyle(.secondary)
                                // verbatim: si no, el Int se localiza ("24.282").
                                Text(verbatim: ":\(sv.port) \(sv.proc)").font(.notchMono(11)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
                                Text(sv.agent.map { "\($0) · \(tr("mac.running"))" } ?? tr("mac.process")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Button(tr("mac.open")) { MacPanelReader.openPort(sv.port) }.buttonStyle(NotchGhostButton(size: .small, tint: Color(hex: "2F9E6E")))
                                Button(tr("mac.stop")) { MacPanelReader.stopPid(sv.pid); refreshHeavy() }.buttonStyle(NotchGhostButton(size: .small))
                            }
                            .font(.caption)
                        }
                    }
                }
                .background(heightReporter("servers"))
                .frame(height: pairCap)
                .clipped()
                .overlay(alignment: .bottom) { pairMore(serversNat, cap: pairCap) }
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
            history.load()
            refreshLight()
            refreshHeavy()
            junk.scan()
        }
        .onReceive(light) { _ in refreshLight() }
        .onReceive(heavy) { _ in refreshHeavy() }
        // Al plegar cambia la altura natural: se vuelve a medir.
        .onChange(of: foldLoads) { _ in naturalHeights = [:] }
        .onChange(of: expandPair) { _ in naturalHeights = [:] }
        .onChange(of: foldServers) { _ in naturalHeights = [:] }
        .onPreferenceChange(ColHeightKey.self) { add in
            naturalHeights.merge(add) { old, new in max(old, new) }
        }
    }

    /// Mide la altura natural de una columna (se queda con el máximo
    /// para que el tope no entre en bucle con la medida recortada).
    private func heightReporter(_ id: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: ColHeightKey.self, value: [id: geo.size.height])
        }
    }

    /// Botón flotante "Ver más" para la columna que desborda.
    @ViewBuilder
    private func pairMore(_ nat: CGFloat, cap: CGFloat?, force: Bool = false) -> some View {
        // `force`: loads lo muestra SIEMPRE (para expandir lo de
        // dentro), aunque su columna no desborde la pareja.
        if force || (cap.map { nat > $0 + 4 } ?? false) {
            VStack {
                Spacer(minLength: 0)
                Button {
                    withAnimation(.snappy(duration: 0.25)) { expandPair = true }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                        Text(tr("mac.verMas"))
                            .font(.notchMono(10))
                    }
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.72)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - piezas

    /// Tarjeta plegable con cabecera clicable (icono + rótulo + dato).
    private func foldCard<Content: View>(
        title: String, sub: String = "", icon: String,
        folded: Binding<Bool>, compact: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NotchCard {
            // Una sola vista (ver NotchCard): cabecera + contenido.
            // Modo compacto: SIN cabecera, el contenido empieza arriba
            // del todo (What loads hasta pulsar «ver más»).
            VStack(alignment: .leading, spacing: 8) {
                if !compact { foldHeader(title: title, sub: sub, icon: icon, folded: folded) }
                if compact || !folded.wrappedValue {
                    content()
                        .padding(.top, compact ? 0 : 8)
                }
            }
        }
    }

    /// Cabecera plegable de foldCard (icono + rótulo + dato + chevron).
    private func foldHeader(
        title: String, sub: String, icon: String, folded: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { folded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                    )
                Text(title.uppercased())
                    .font(.notchMono(10))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .kerning(1.2)
                if !sub.isEmpty {
                    Text(sub)
                        .font(.notchMono(10))
                        .foregroundStyle(Color.white.opacity(0.38))
                        .monospacedDigit()
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

    /// Tarjeta de mediciones: tres mini-tarjetas (CPU, memoria y
    /// batería) con fondo propio y SIN separadores detrás: cada dato
    /// vive en su bloque, sin líneas de por medio.
    private var measurementsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            NotchTag(icon: "gauge.with.needle", text: tr("mac.measurements"),
                     color: Color(hex: "2F9E6E"), trailing: chip)
            HStack(alignment: .top, spacing: 8) {
                // Carril CPU (bloque propio, sin divisor). Altura fija
                // igual que el de memoria; la batería queda libre.
                VStack(spacing: 6) {
                    LaneGauge(value: "\(Int((snap.cpuUser + snap.cpuSys).rounded()))%",
                              fraction: cpuFrac, color: severityColor(fraction: cpuFrac))
                    Text("CPU").font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.45))
                    Sparkline(values: cpuHist, color: severityColor(fraction: cpuFrac))
                    Spacer(minLength: 0)
                    Text("E \(eCores) · P \(pCores) · \(tr("mac.peak", Int(peakCpu.rounded())))")
                        .font(.notchMono(9)).foregroundStyle(Color.white.opacity(0.45))
                }
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(laneBg)
                // Carril memoria: misma altura que CPU.
                VStack(spacing: 6) {
                    LaneGauge(value: "\(Int((memFrac * 100).rounded()))%",
                              fraction: memFrac, color: severityColor(fraction: memFrac))
                    Text("MEMORY").font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.45))
                    Sparkline(values: memHist, color: severityColor(fraction: memFrac))
                    Text(String(format: "%.1f of %.0f GB", snap.memUsedGB, snap.memTotalGB))
                        .font(.notchMono(9)).foregroundStyle(Color.white.opacity(0.45))
                    HStack(spacing: 4) {
                        Circle().fill(pressureColor).frame(width: 6, height: 6)
                        Text("\(pressureWord) · swap \(String(format: "%.0f", snap.swapUsedGB)) GB")
                            .font(.notchMono(9)).foregroundStyle(Color.white.opacity(0.45))
                    }
                }
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(laneBg)
                // Carril batería: NO se iguala (queda a su altura).
                batteryCard.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.058), Color.white.opacity(0.028)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.13), Color.white.opacity(0.055)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.20), radius: 10, y: 5)
    }

    /// Fondo de carril: bloque propio (sin líneas separadoras).
    private var laneBg: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
    }

    private var pressureColor: Color {
        if snap.memFreeFrac > 0.25 { return Color(hex: "2F9E6E") }
        if snap.memFreeFrac > 0.12 { return Color(hex: "D9A514") }
        return Color(hex: "E0574B")
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
            // Dos columnas: la batería deja de ser el bloque más alto
            // de la tarjeta (menos saturación, mismo dato).
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
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

    private var loadRest: Double {
        let sum = sortedProcs.prefix(6).reduce(0) { $0 + $1.pct }
        return max(0, totalCpu - sum)
    }

    /// Tabla completa ordenable (CPU/MEM) con buscador.
    private var sortedProcs: [ProcTop] {
        let q = procQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let list = snap.tops.filter { q.isEmpty || $0.name.lowercased().contains(q) }
        if sortByCpu { return list.sorted { $0.pct > $1.pct } }
        return list.sorted { $0.memMB > $1.memMB }
    }

    private func procColor(_ t: ProcTop) -> Color {
        let i = sortedProcs.firstIndex { $0.pid == t.pid } ?? 0
        return [Color(hex: "2F9E6E"), Color(hex: "2F9E6E").opacity(0.65), Color(hex: "2F9E6E").opacity(0.4)][i % 3]
    }

    private func verbatimPct(_ v: Double) -> Text {
        Text(verbatim: "\(Int(v.rounded()))%")
    }

    private func memMBString(_ v: Double) -> String {
        v >= 1024 ? String(format: "%.1f GB", v / 1024) : "\(Int(v.rounded())) MB"
    }

    private func verbatimMB(_ v: Double) -> Text {
        Text(verbatim: memMBString(v))
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
        // Etiqueta sobre valor: en media columna no se parte la palabra.
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.notchMono(9))
                .foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(value)
                .font(.notchMono(11)).foregroundStyle(color).monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        cpuHist.append(total)
        memHist.append(snap.memTotalGB > 0 ? snap.memUsedGB / snap.memTotalGB * 100 : 0)
        if cpuHist.count > 45 { cpuHist.removeFirst(cpuHist.count - 45) }
        if memHist.count > 45 { memHist.removeFirst(memHist.count - 45) }
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

/// Barras de actividad por hora (últimas 24 h rodantes).
struct DayChart: View {
    var hours: [Int]
    @ObservedObject private var settings = NotchSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(hours.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(settings.accent.opacity(hours[i] > 0 ? 0.85 : 0.18))
                        .frame(maxWidth: .infinity, minHeight: 4, maxHeight: barH(hours[i]))
                }
            }
            .frame(height: 44)
            HStack {
                ForEach([23, 18, 12, 6, 0], id: \.self) { back in
                    Text(hourLabel(back)).font(.notchMono(8)).foregroundStyle(Color.white.opacity(0.35))
                    if back != 0 { Spacer() }
                }
            }
        }
    }

    private func barH(_ v: Int) -> CGFloat {
        let peak = max(CGFloat(hours.max() ?? 1), 1)
        return max(4, 40 * CGFloat(v) / peak)
    }

    private func hourLabel(_ back: Int) -> String {
        // back = horas hacia atrás desde ahora (0 = hora actual).
        let d = Date().addingTimeInterval(-Double(back) * 3600)
        return NotchDateFmt.hourOnly.string(from: d) + "h"
    }
}

/// Fila de proceso: barra proporcional detrás (qué parte del total
/// consume) + valor + expansión al detalle.
struct ProcRow: View {
    var t: ProcTop
    var color: Color
    var value: String
    var fraction: CGFloat = 0
    var expanded: Bool
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
                Text(t.name).font(.notchMono(11)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                Spacer()
                Text(verbatim: value).font(.notchMono(11)).foregroundStyle(.white.opacity(0.7)).monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.3))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(expanded ? 0.07 : 0.03))
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(color.opacity(0.18))
                            .frame(width: max(8, geo.size.width * fraction))
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr("mac.detail", t.name))
        .help(tr("mac.detail", t.name))
    }
}

/// Minigráfica de 90 s (una muestra por refresco ligero).
struct Sparkline: View {
    var values: [Double]
    var color: Color

    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                let peak = max(values.max() ?? 1, 0.001)
                let pts = values.enumerated().map { i, v in
                    CGPoint(
                        x: geo.size.width * CGFloat(i) / CGFloat(values.count - 1),
                        y: geo.size.height - geo.size.height * CGFloat(v / peak)
                    )
                }
                Path { p in
                    p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                    p.addLines(pts)
                    p.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(color.opacity(0.12))
                Path { p in
                    p.move(to: pts[0])
                    p.addLines(Array(pts.dropFirst()))
                }
                .stroke(color.opacity(0.85), lineWidth: 1.5)
            }
        }
        .frame(height: 22)
        .frame(maxWidth: 180)
        .clipped()
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
    enum Kind {
        case trash       // papelera normal
        case vacuum      // compactar SQLite sin perder datos
        case worktree    // exige git status limpio
        case huge        // fichero enorme: papelera o borrado definitivo
    }
    let id: String
    var agent: String
    var label: String
    var paths: [String]
    var bytes: Int64 = 0
    var level: JunkLevel = .safe
    var kind: Kind = .trash
}

/// Nivel de seguridad: decide si entra en "Limpiar todo" y qué
/// confirmación pide al usuario.
enum JunkLevel: Int {
    case safe = 0        // temporales y logs: papelera directa
    case redownload = 1  // cachés: se vuelven a descargar
    case destructive = 2 // datos reales: jamás en "Limpiar todo"
}

/// Basura de agentes y herramientas de desarrollo. Ampliación con los
/// sitios reales encontrados en este Mac (temporales de OpenCode y
/// Playwright, cachés de Puppeteer/Serena/Codegraph, worktrees…).
/// Reglas: solo rutas dentro de $HOME, $TMPDIR o /tmp (canonizadas,
/// sin ".."), y solo se activa con todos los agentes parados.
final class JunkStore: ObservableObject {
    @Published var rows: [JunkRow] = []
    @Published var scanning = false
    @Published var lastCleaned = ""

    typealias TargetRow = (label: String, paths: [String], level: JunkLevel, kind: JunkRow.Kind)

    /// Destinos conocidos por familia (se filtran los inexistentes).
    static func targets() -> [(agent: String, rows: [TargetRow])] {
        let h = FileManager.default.homeDirectoryForCurrentUser.path
        let tmp = NSTemporaryDirectory() // /private/var/folders/…/T/
        return [
            (agent: "OpenCode", rows: [
                (tr("mac.dbLabel"),
                 ["\(h)/.local/share/opencode/opencode.db",
                  "\(h)/.local/share/opencode/opencode.db-wal",
                  "\(h)/.local/share/opencode/opencode.db-shm"],
                 .destructive, .vacuum),
                ("snapshots", ["\(h)/.local/share/opencode/snapshot"], .safe, .trash),
                ("logs", ["\(h)/.local/share/opencode/log"], .safe, .trash),
                ("shell", ["\(h)/.local/share/opencode/shell",
                           "\(h)/.local/share/opencode/tool-output"], .safe, .trash),
                ("cachés", ["\(h)/.cache/opencode"], .safe, .trash),
                ("temporales", ["\(tmp)/opencode-pty-501",
                                "\(tmp)/opencode/backend-dev.log",
                                "\(tmp)/opencode/bigint",
                                "\(tmp)/opencode/dzprobe",
                                "\(tmp)/opencode/norm2",
                                "\(tmp)/opencode/tutorials-backup",
                                "\(tmp)/opencode/partimos-pw-venv"], .safe, .trash),
            ]),
            (agent: "Opencode Desktop", rows: [
                ("cli", ["\(h)/Library/Application Support/ai.opencode.desktop/cli"], .redownload, .trash),
                ("caché", ["\(h)/Library/Application Support/ai.opencode.desktop/Cache"], .safe, .trash),
            ]),
            (agent: "Codex", rows: [
                ("logs", ["\(h)/.codex/logs_2.sqlite", "\(h)/.codex/logs_2.sqlite-shm", "\(h)/.codex/logs_2.sqlite-wal"], .safe, .trash),
                ("cola", ["\(h)/.codex/queue_1.sqlite", "\(h)/.codex/queue_1.sqlite-shm", "\(h)/.codex/queue_1.sqlite-wal"], .safe, .trash),
                ("historial", ["\(h)/.codex/sessions", "\(h)/.codex/history.jsonl"], .safe, .trash),
                ("runtimes", ["\(h)/.cache/codex-runtimes"], .redownload, .trash),
            ]),
            (agent: "Claude", rows: [
                ("sesiones", ["\(h)/.claude/sessions", "\(h)/.claude/session-env"], .safe, .trash),
                ("backups", ["\(h)/.claude/backups", "\(h)/.claude/ide"], .safe, .trash),
                ("historial", ["\(h)/.claude/projects", "\(h)/.claude/shell-snapshots", "\(h)/.claude/todos"], .safe, .trash),
                ("cachés", ["\(h)/Library/Application Support/Claude/Cache",
                            "\(h)/Library/Application Support/Claude/Code Cache",
                            "\(h)/Library/Application Support/Claude/GPUCache",
                            "\(h)/Library/Application Support/Claude/DawnWebGPUCache",
                            "\(h)/Library/Application Support/Claude/DawnGraphiteCache"], .safe, .trash),
            ]),
            (agent: "Cursor", rows: [
                ("cachés", ["\(h)/Library/Application Support/Cursor/Cache",
                            "\(h)/Library/Application Support/Cursor/logs",
                            "\(h)/Library/Application Support/Cursor/Crashpad"], .safe, .trash),
                ("workspaces", ["\(h)/Library/Application Support/Cursor/User/workspaceStorage"], .safe, .trash),
            ]),
            (agent: "VS Code", rows: [
                ("cachés", ["\(h)/Library/Application Support/Code/Cache",
                            "\(h)/Library/Application Support/Code/CachedData",
                            "\(h)/Library/Application Support/Code/GPUCache",
                            "\(h)/Library/Application Support/Code/logs",
                            "\(h)/Library/Application Support/Code/Crashpad"], .safe, .trash),
                ("workspaces", ["\(h)/Library/Application Support/Code/User/workspaceStorage"], .safe, .trash),
                ("cpptools", ["\(h)/Library/Caches/vscode-cpptools"], .redownload, .trash),
            ]),
            (agent: "Copilot", rows: [
                ("chats", ["\(h)/Library/Application Support/Copilot",
                           "\(h)/Library/Application Support/Code/User/globalStorage/github.copilot-chat"], .safe, .trash),
            ]),
            (agent: "Antigravity", rows: [
                ("cachés", ["\(h)/.antigravity/cache", "\(h)/.antigravity/logs", "\(h)/.antigravity/tmp"], .safe, .trash),
            ]),
            (agent: "Gemini", rows: [
                ("temporales", ["\(h)/.gemini/tmp", "\(h)/.gemini/cache"], .safe, .trash),
                ("logs", ["\(h)/.gemini/logs", "\(h)/.gemini/history"], .safe, .trash),
            ]),
            (agent: "Cline", rows: [
                ("chats", ["\(h)/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"], .safe, .trash),
            ]),
            (agent: "Kilo", rows: [("cachés", ["\(h)/.kilo/cache", "\(h)/.kilo/logs"], .safe, .trash)]),
            (agent: "Crush", rows: [("logs", ["\(h)/.crush/logs", "\(h)/.crush/cache"], .safe, .trash)]),
            (agent: "Qwen", rows: [("cachés", ["\(h)/.qwen/cache", "\(h)/.qwen/logs"], .safe, .trash)]),
            (agent: "Pi", rows: [("cachés", ["\(h)/.pi/cache", "\(h)/.pi/logs"], .safe, .trash)]),
            (agent: "Hermes", rows: [("cachés", ["\(h)/.hermes/cache", "\(h)/.hermes/logs"], .safe, .trash)]),
            (agent: "Kimi", rows: [("cachés", ["\(h)/.kimi/cache", "\(h)/.kimi/logs"], .safe, .trash)]),
            (agent: "Grok", rows: [("cachés", ["\(h)/.grok/cache", "\(h)/.grok/logs"], .safe, .trash)]),
            (agent: "Droid", rows: [("cachés", ["\(h)/.droid/cache", "\(h)/.droid/logs", "\(h)/.factory/tool-logs"], .safe, .trash)]),
            (agent: "Serena", rows: [
                ("logs", ["\(h)/.serena/logs"], .safe, .trash),
                ("language servers", ["\(h)/.serena/language_servers/static"], .redownload, .trash),
            ]),
            (agent: "Codegraph", rows: [
                ("binario", ["\(h)/.codegraph/versions"], .redownload, .trash),
            ]),
            (agent: "Playwright", rows: [
                ("artifacts", ["\(tmp)/playwright-artifacts-*"], .safe, .trash),
                ("navegadores", ["\(h)/Library/Caches/ms-playwright"], .redownload, .trash),
                ("mcp", ["\(h)/Library/Caches/ms-playwright-mcp"], .redownload, .trash),
            ]),
            (agent: "Puppeteer", rows: [
                ("chrome", ["\(h)/.cache/puppeteer/chrome",
                            "\(h)/.cache/puppeteer/chrome-headless-shell"], .redownload, .trash),
            ]),
            (agent: "Metro", rows: [
                ("caché", ["\(tmp)/metro-cache"], .safe, .trash),
                ("logs", ["/tmp/metro-*.log"], .safe, .trash),
            ]),
            (agent: "Node", rows: [
                ("temporales", ["\(tmp)/node-compile-cache", "\(tmp)/jest_dx",
                                "\(tmp)/tsx-501", "\(tmp)/scoped_dir*"], .safe, .trash),
                ("gyp", ["\(h)/Library/Caches/node-gyp", "\(h)/Library/Caches/typescript",
                         "\(h)/Library/Caches/next-swc", "\(h)/Library/Caches/bun"], .redownload, .trash),
                ("uv", ["\(h)/.cache/uv"], .redownload, .trash),
            ]),
            (agent: "Cachés", rows: [
                ("paquetes", ["\(h)/Library/Caches/pnpm", "\(h)/Library/Caches/CocoaPods",
                              "\(h)/Library/Caches/electron"], .redownload, .trash),
                ("ollama", ["\(h)/Library/Caches/ollama"], .redownload, .trash),
                ("homebrew", ["\(h)/Library/Caches/Homebrew"], .redownload, .trash),
                ("actualizadores", ["\(h)/Library/Caches/com.microsoft.VSCode.ShipIt",
                                    "\(h)/Library/Caches/@opencode-aidesktop-updater"], .redownload, .trash),
            ]),
            (agent: "Tmp", rows: [
                ("logs", ["/tmp/porfolio-backend.log", "/tmp/spa.log", "/tmp/serve.log"], .safe, .trash),
                ("datos", ["/tmp/pre_*.sql", "/tmp/b.js", "/tmp/bundle.js", "/tmp/*.yaml"], .safe, .trash),
                ("vídeo", ["/tmp/bubble.mp4", "/tmp/bubble.mp4.sb-*"], .destructive, .huge),
            ]),
        ]
    }

    /// Expande globs y filtra rutas seguras (ver `JunkPaths` en
    /// NotchCore: zonas permitidas = $HOME, $TMPDIR y /tmp).
    static func safeExpand(_ raw: String) -> [String] {
        JunkPaths.expand(raw)
    }

    /// Worktrees de OpenCode (contienen `.git`): dos filas por cada uno —
    /// regenerables (node_modules/dist/build/png sueltos) y el completo.
    static func worktreeRows() -> [JunkRow] {
        let fm = FileManager.default
        let h = fm.homeDirectoryForCurrentUser.path
        let root = "\(h)/.local/share/opencode/worktree"
        guard let en = fm.enumerator(atPath: root) else { return [] }
        var roots: [String] = []
        for case let rel as String in en {
            let parts = rel.split(separator: "/")
            guard parts.count <= 5, parts.last == ".git" else { continue }
            var dir = String(rel)
            dir.removeLast(4) // quita ".git" (fichero en worktrees)
            let full = (root as NSString).appendingPathComponent(dir)
            if !roots.contains(full) { roots.append(full) }
        }
        var out: [JunkRow] = []
        for w in roots {
            let name = (w as NSString).lastPathComponent
            var regen = ["node_modules", "dist", "build"]
                .map { (w as NSString).appendingPathComponent($0) }
                .filter { fm.fileExists(atPath: $0) }
            if let kids = try? fm.contentsOfDirectory(atPath: w) {
                regen += kids.filter { $0.lowercased().hasSuffix(".png") }
                    .map { (w as NSString).appendingPathComponent($0) }
            }
            if !regen.isEmpty {
                let kb = duKB(regen)
                if kb > 0 {
                    out.append(JunkRow(id: w + "#regen", agent: "OpenCode",
                                       label: "\(tr("mac.wtRegen")) · \(name)",
                                       paths: regen, bytes: kb * 1024,
                                       level: .redownload, kind: .trash))
                }
            }
            let kbAll = duKB([w])
            if kbAll > 0 {
                out.append(JunkRow(id: w, agent: "OpenCode",
                                   label: "\(tr("mac.wtCode")) · \(name)",
                                   paths: [w], bytes: kbAll * 1024,
                                   level: .destructive, kind: .worktree))
            }
        }
        return out
    }

    /// Mide con `du` en background (rápido, sin permisos). Con TTL:
    /// entrar en la pestaña Mac no relanza `du` cada vez.
    func scan(force: Bool = false) {
        guard !scanning, force || Date().timeIntervalSince(lastScan) > 60 else { return }
        scanning = true
        lastScan = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var out: [JunkRow] = []
            let fm = FileManager.default
            for fam in Self.targets() {
                for r in fam.rows {
                    let live = r.paths.flatMap { Self.safeExpand($0) }
                        .filter { fm.fileExists(atPath: $0) }
                    guard !live.isEmpty else { continue }
                    let kb = Self.duKB(live)
                    guard kb > 0 else { continue }
                    out.append(JunkRow(id: "\(fam.agent)/\(r.label)",
                                       agent: fam.agent, label: r.label,
                                       paths: live, bytes: kb * 1024,
                                       level: r.level, kind: r.kind))
                }
            }
            out += Self.worktreeRows()
            out.sort { $0.bytes > $1.bytes }
            DispatchQueue.main.async {
                self.rows = out
                self.scanning = false
            }
        }
    }

    private var lastScan = Date.distantPast

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
        scan(force: true)
    }

    /// Compacta la base SQLite con VACUUM: reduce el tamaño SIN perder
    /// sesiones (el WAL se integra).
    func vacuum(_ row: JunkRow) {
        guard let db = row.paths.first else { return }
        let before = row.bytes
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            p.arguments = [db, "VACUUM;"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            var ran = false
            if (try? p.run()) != nil { ran = true; p.waitUntilExit() }
            let ok = ran && p.terminationStatus == 0
            let after = Self.duKB([db]) * 1024
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastCleaned = ok
                    ? "✓ \(row.agent)/\(row.label) \(Self.formatBytes(before)) → \(Self.formatBytes(after))"
                    : "✗ \(row.agent)/\(row.label)"
                self.scan(force: true)
            }
        }
    }

    /// Borra DEFINITIVAMENTE (sin papelera): para ficheros enormes.
    func deleteForever(_ row: JunkRow) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var failed = 0
            for path in row.paths {
                do { try FileManager.default.removeItem(atPath: path) } catch { failed += 1 }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastCleaned = failed == 0
                    ? "✓ \(row.agent)/\(row.label)"
                    : tr("mac.trashFails", failed)
                self.scan(force: true)
            }
        }
    }

    /// ¿El worktree tiene cambios sin commitear? Si falla el comando
    /// (sin git…), se bloquea por seguridad.
    static func worktreeIsDirty(_ path: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", path, "status", "--porcelain"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return true }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return true }
        return !data.isEmpty
    }

    /// "Limpiar todo": solo papelera y no-destructivos (nunca la base
    /// de datos ni el código de un worktree).
    var cleanableRows: [JunkRow] {
        rows.filter { $0.kind == .trash && $0.level != .destructive }
    }

    var cleanableBytes: Int64 { cleanableRows.reduce(0) { $0 + $1.bytes } }

    var cleanableHasRedownload: Bool { cleanableRows.contains { $0.level == .redownload } }

    var allBytes: Int64 { rows.reduce(0) { $0 + $1.bytes } }

    func cleanAll() {
        let all = cleanableRows.flatMap(\.paths)
        guard !all.isEmpty else { return }
        let r = Self.trash(paths: all)
        lastCleaned = r.failed == 0
            ? "\(Self.formatBytes(cleanableBytes)) \(tr("mac.toTrash"))"
            : tr("mac.trashFails", r.failed)
        scan(force: true)
    }

    static func formatBytes(_ b: Int64) -> String {
        if b >= 1_073_741_824 { return String(format: "%.1f GB", Double(b) / 1_073_741_824) }
        if b >= 1_048_576 { return String(format: "%.0f MB", Double(b) / 1_048_576) }
        return "\(max(1, Int(b / 1024))) MB"
    }
}

/// Sección LIMPIEZA: qué basura hay, por nivel de riesgo, con acciones
/// especiales (compactar, worktree con git, borrado definitivo).
/// Solo activo con todos los agentes parados. Plegable.
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
                HStack(spacing: 7) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(0.10))
                        )
                    Text(tr("mac.junk").uppercased())
                        .font(.notchMono(10))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .kerning(1.2)
                    if junk.scanning {
                        Text(tr("mac.measuring")).font(.notchMono(10)).foregroundStyle(.secondary)
                    } else if !junk.rows.isEmpty {
                        Text(JunkStore.formatBytes(junk.allBytes)).font(.notchMono(10)).foregroundStyle(Color.white.opacity(0.38)).monospacedDigit()
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
                junkBody.padding(.top, 6)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.058), Color.white.opacity(0.028)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.13), Color.white.opacity(0.055)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.20), radius: 10, y: 5)
    }

    /// Insignia de nivel: ✓ seguro · ↓ se re-descarga · ! destructivo.
    private func levelBadge(_ level: JunkLevel) -> some View {
        let icon: String
        let color: Color
        switch level {
        case .safe: icon = "checkmark"; color = Color(hex: "2F9E6E")
        case .redownload: icon = "arrow.down"; color = Color(hex: "4C8FD8")
        case .destructive: icon = "exclamationmark"; color = Color(hex: "F2B33D")
        }
        return Image(systemName: icon)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(color.opacity(0.15))
            )
    }

    @ViewBuilder
    private func rowButtons(_ row: JunkRow) -> some View {
        switch row.kind {
        case .trash:
            Button {
                junk.trashRow(row)
            } label: {
                Image(systemName: "trash").font(.system(size: 10))
            }
            .buttonStyle(NotchGhostButton(size: .mini))
            .disabled(!allIdle)
            .help(allIdle ? tr("mac.toTrash") : tr("mac.waitAgents"))
        case .vacuum:
            HStack(spacing: 4) {
                Button(tr("mac.vacuum")) { junk.vacuum(row) }
                    .buttonStyle(NotchGhostButton(size: .mini, tint: Color(hex: "4C8FD8")))
                    .disabled(!allIdle)
                Button { confirmRow(row, forever: false) } label: {
                    Image(systemName: "trash").font(.system(size: 10))
                }
                .buttonStyle(NotchGhostButton(size: .mini, tint: Color(hex: "F2B33D")))
                .disabled(!allIdle)
            }
        case .worktree:
            Button { worktreeAction(row) } label: {
                Image(systemName: "trash").font(.system(size: 10))
            }
            .buttonStyle(NotchGhostButton(size: .mini, tint: Color(hex: "F2B33D")))
            .disabled(!allIdle)
            .help(allIdle ? tr("mac.toTrash") : tr("mac.waitAgents"))
        case .huge:
            HStack(spacing: 4) {
                Button { confirmRow(row, forever: false) } label: {
                    Image(systemName: "trash").font(.system(size: 10))
                }
                .buttonStyle(NotchGhostButton(size: .mini, tint: Color(hex: "F2B33D")))
                .disabled(!allIdle)
                Button { confirmRow(row, forever: true) } label: {
                    Image(systemName: "xmark.bin.fill").font(.system(size: 10))
                }
                .buttonStyle(NotchGhostButton(size: .mini, tint: Color(hex: "E0574B")))
                .disabled(!allIdle)
                .help(tr("mac.deleteForever"))
            }
        }
    }

    @ViewBuilder
    private var junkBody: some View {
        if junk.rows.isEmpty, !junk.scanning {
            Text(tr("mac.noJunk")).font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(junk.rows) { row in
                HStack(spacing: 6) {
                    levelBadge(row.level)
                    Circle()
                        .fill(agentColor(for: row.agent, default: Color.gray))
                        .frame(width: 7, height: 7)
                    Text("\(row.agent) · \(row.label)")
                        .font(.notchMono(11)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                    Spacer()
                    Text(JunkStore.formatBytes(row.bytes))
                        .font(.notchMono(10)).foregroundStyle(.secondary).monospacedDigit()
                    rowButtons(row)
                }
            }
            // Limpiar todo: solo papelera + re-descargables (jamás
            // datos destructivos: base de datos ni código).
            Button(allIdle ? tr("mac.cleanAll") : tr("mac.waitAgents")) {
                confirmClean()
            }
            .buttonStyle(NotchPrimaryButton(size: .small, color: Color(hex: "E0574B")))
            .disabled(!allIdle || junk.cleanableRows.isEmpty)
        }
        if !junk.lastCleaned.isEmpty {
            Text(junk.lastCleaned).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// Papelera con confirmación explícita (datos destructivos).
    private func confirmRow(_ row: JunkRow, forever: Bool) {
        let a = NSAlert()
        a.messageText = tr("mac.dangerTitle")
        a.informativeText = tr(forever ? "mac.deleteBody" : "mac.dangerBody",
                               row.label, JunkStore.formatBytes(row.bytes))
        a.addButton(withTitle: tr(forever ? "mac.deleteForever" : "mac.toTrash"))
        a.addButton(withTitle: tr("mac.cancel"))
        if a.runModal() == .alertFirstButtonReturn {
            if forever {
                // Doble confirmación para el borrado definitivo.
                let b = NSAlert()
                b.messageText = row.label
                b.informativeText = tr("mac.deleteBody", row.label, JunkStore.formatBytes(row.bytes))
                b.addButton(withTitle: tr("mac.deleteForever"))
                b.addButton(withTitle: tr("mac.cancel"))
                if b.runModal() == .alertFirstButtonReturn {
                    junk.deleteForever(row)
                }
            } else {
                junk.trashRow(row)
            }
        }
    }

    /// Worktree: bloqueado si hay cambios sin commitear.
    private func worktreeAction(_ row: JunkRow) {
        let path = row.paths.first ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            let dirty = JunkStore.worktreeIsDirty(path)
            DispatchQueue.main.async {
                if dirty {
                    let a = NSAlert()
                    a.messageText = tr("mac.wtDirty")
                    a.informativeText = row.label
                    a.addButton(withTitle: tr("mac.cancel"))
                    a.runModal()
                } else {
                    self.confirmRow(row, forever: false)
                }
            }
        }
    }

    private func confirmClean() {
        let rows = junk.cleanableRows
        guard !rows.isEmpty else { return }
        let a = NSAlert()
        a.messageText = tr("mac.cleanTitle", JunkStore.formatBytes(junk.cleanableBytes))
        var body = tr("mac.cleanBody", Set(rows.map(\.agent)).sorted().joined(separator: ", "))
        if junk.cleanableHasRedownload {
            body += "\n\n" + tr("mac.cleanRedownload")
        }
        a.informativeText = body
        a.addButton(withTitle: tr("mac.cleanOk"))
        a.addButton(withTitle: tr("mac.cancel"))
        if a.runModal() == .alertFirstButtonReturn {
            junk.cleanAll()
        }
    }
}
#endif
