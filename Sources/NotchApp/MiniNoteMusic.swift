#if os(macOS)
import AppKit
import CoreImage
import SwiftUI

// MARK: - Quick note: tap, type, Enter. A Lumio, Obsidian o carpeta.

final class QuickNoteStore: ObservableObject {
    @Published var lastSaved = ""
    private var monitor: Any?

    /// Tap de ⌥ derecha para pensar en voz alta. Requiere monitor global;
    /// sin permiso, se usa el campo de la vista.
    func installHotKey(onTap: @escaping () -> Void) {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            if event.modifierFlags.contains(.option) && event.keyCode == 61 {
                onTap()
            }
        }
    }

    func save(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(trimmed)\n"
        // 1. Siempre a Lumio.
        append(line, to: lumioFile())
        // 2. Obsidian daily note si hay vault configurado.
        if let vault = UserDefaults.standard.string(forKey: "notchObsidianVault"), !vault.isEmpty {
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            let daily = URL(fileURLWithPath: (vault as NSString).expandingTildeInPath)
                .appendingPathComponent("\(df.string(from: Date())).md")
            append(line, to: daily)
        }
        lastSaved = "Guardado ✓"
    }

    func saveToAppleNotes(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let script = "tell application \"Notes\" to make new note at folder \"Notes\" with properties {body:\(quoted(trimmed))}"
        if HandoffService.osascript(script) {
            lastSaved = "En Apple Notes ✓"
        } else {
            lastSaved = "Notes: permite Automatización en Ajustes"
        }
    }

    private func lumioFile() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("NOTCH-notes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notes.md")
    }

    private func append(_ line: String, to url: URL) {
        if FileManager.default.fileExists(atPath: url.path),
           let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

struct QuickNoteView: View {
    @ObservedObject var store: QuickNoteStore
    @State private var text = ""
    @State private var vaultPath: String = UserDefaults.standard.string(forKey: "notchObsidianVault") ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("una idea? ⌥ der.").font(.notchMono(11)).foregroundStyle(.secondary)
            TextField("Tap, type, Enter…", text: $text, onCommit: {
                store.save(text); text = ""
            })
            .textFieldStyle(.roundedBorder)
            HStack {
                Button("Guardar") { store.save(text); text = "" }.controlSize(.small).buttonStyle(.borderedProminent)
                Button("→ Notes") { store.saveToAppleNotes(text); text = "" }.controlSize(.small)
                Text(store.lastSaved).font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
            TextField("Obsidian vault (opcional)", text: $vaultPath, onCommit: {
                UserDefaults.standard.set(vaultPath, forKey: "notchObsidianVault")
            })
            .textFieldStyle(.roundedBorder).font(.caption)
        }
        .padding(8)
    }
}

/// Mezcla dos colores en RGB (para el degradado del ecualizador).
func blendColor(_ a: Color, _ b: Color, _ t: Double) -> Color {
    func comps(_ c: Color) -> (Double, Double, Double) {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }
    let (r1, g1, b1) = comps(a), (r2, g2, b2) = comps(b)
    let t = min(1, max(0, t))
    return Color(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t)
}

// MARK: - Música: reproducción estilo Lumio + color que ilumina el notch
// (Music.app / Spotify por AppleScript). Trae carátula, progreso y
// controles, y extrae el color dominante de la carátula para el lavado
// del panel: el notch se ilumina con el color de la canción.

final class MusicStore: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var source = ""
    @Published var playing = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var artwork: NSImage?
    /// Hay reproductor abierto (aunque esté en pausa).
    @Published var playerLive = false
    /// Color dominante de la carátula: ilumina el panel del notch.
    @Published var tint: Color?
    /// Segundo color de la carátula: degradado del ecualizador.
    @Published var tint2: Color?

    private var busy = false
    private var artworkToken = 0
    private var timer: Timer?

    init() {
        // Poll propio cada 0.5 s: el color ilumina el notch aunque la
        // pestaña de música no esté seleccionada, y el aviso de canción
        // nueva sale casi al instante.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer?.tolerance = 0.1
        poll()
    }

    deinit { timer?.invalidate() }

    /// Consulta en background (osascript es bloqueante) y publica en main.
    func poll() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let musicApp = Self.isRunning("Music")
            let spotifyApp = Self.isRunning("Spotify")
            var hit: (t: String, a: String, p: Double, d: Double, playing: Bool, app: String)?
            if musicApp, let r = self.query(app: "Music") { hit = (r.0, r.1, r.2, r.3, r.4, "Music") }
            else if spotifyApp, let r = self.query(app: "Spotify") { hit = (r.0, r.1, r.2, r.3, r.4, "Spotify") }
            DispatchQueue.main.async {
                self.busy = false
                self.playerLive = musicApp || spotifyApp
                if let hit {
                    self.apply(hit)
                } else {
                    self.playing = false
                    // Sin reproductor en marcha: el notch vuelve a su color.
                    if !musicApp && !spotifyApp, self.tint != nil {
                        withAnimation(.easeInOut(duration: 1.1)) {
                            self.tint = nil
                            self.tint2 = nil
                        }
                    }
                }
            }
        }
    }

    // MARK: - Controles (mismos comandos AppleScript en ambos apps)

    func back() { command("back track") }
    func togglePlay() { command("playpause") }
    func next() { command("next track") }

    private func command(_ cmd: String) {
        let app = source.isEmpty ? "Music" : source
        guard Self.isRunning(app) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = self?.runOut("tell application \"\(app)\" to \(cmd)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.poll() }
        }
    }

    // MARK: - estado

    private func apply(_ r: (t: String, a: String, p: Double, d: Double, playing: Bool, app: String)) {
        let changed = (title != r.t || artist != r.a || source != r.app)
        title = r.t
        artist = r.a
        source = r.app
        playing = r.playing
        position = r.p
        duration = r.d
        if changed {
            fetchArtwork(app: r.app)
            // Aviso estilo Lumio: sale del notch la canción nueva.
            NotificationCenter.default.post(name: .notchTrackChanged, object: nil)
        }
    }

    /// Devuelve (título, artista, posición, duración, sonando) o nil.
    private func query(app: String) -> (String, String, Double, Double, Bool)? {
        let script = """
        tell application "\(app)"
          try
            set t to name of current track
            if t is "" then return ""
            set a to artist of current track
            set p to player position
            set d to duration of current track
            set s to "stopped"
            if player state is playing then set s to "playing"
            return t & " | " & a & " | " & (p as string) & " | " & (d as string) & " | " & s
          on error
            return ""
          end try
        end tell
        """
        guard let out = runOut(script), !out.isEmpty else { return nil }
        let parts = out.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 5, !parts[0].isEmpty else { return nil }
        var dur = Double(parts[3]) ?? 0
        // Spotify devuelve milisegundos en algunos versiones.
        if dur > 6000 { dur /= 1000 }
        return (parts[0], parts[1], Double(parts[2]) ?? 0, dur, parts[4] == "playing")
    }

    // MARK: - Carátula + color dominante

    private func fetchArtwork(app: String) {
        artworkToken += 1
        let token = artworkToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var image: NSImage?
            if app == "Spotify" {
                // Spotify expone la URL de la carátula.
                if let s = self.runOut("tell application \"Spotify\" to artwork url of current track"),
                   let url = URL(string: s),
                   let data = try? Data(contentsOf: url) {
                    image = NSImage(data: data)
                }
            } else {
                // Music.app: volcar los bytes de la carátula a un fichero.
                let path = NSTemporaryDirectory() + "notch-art.bin"
                let script = """
                tell application "Music"
                  try
                    set artData to data of artwork 1 of current track
                    set f to open for access POSIX file "\(path)" with write permission
                    set eof of f to 0
                    write artData to f
                    close access f
                    return "ok"
                  on error
                    return ""
                  end try
                end tell
                """
                if self.runOut(script) == "ok" {
                    image = NSImage(contentsOfFile: path)
                }
            }
            guard let img = image else { return }
            let color = Self.dominantColor(of: img)
            let color2 = Self.secondaryColor(of: img)
            DispatchQueue.main.async {
                guard token == self.artworkToken else { return }
                self.artwork = img
                // Lavado del panel animado al color de la canción.
                withAnimation(.easeInOut(duration: 1.1)) {
                    self.tint = color
                    self.tint2 = color2
                }
            }
        }
    }

    /// Color promedio de la carátula, realzado para que el lavado del
    /// panel se vea vivo (saturación y brillo acotados).
    static func dominantColor(of image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ci,
            kCIInputExtentKey: CIVector(cgRect: ci.extent)
        ]), let output = filter.outputImage else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: space])
        ctx.render(output, toBitmap: &px, rowBytes: 4, bounds: output.extent,
                   format: .RGBA8, colorSpace: space)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                blue: CGFloat(px[2]) / 255, alpha: 1)
            .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Realce: colores vivos pero no cegadores.
        s = max(0.42, min(s * 1.25, 0.95))
        b = min(max(b, 0.58), 0.82)
        return Color(hue: h, saturation: s, brightness: b)
    }

    /// Segundo color de la carátula para el degradado del ecualizador:
    /// el tono más presente alejado del dominante (como Lumio: dos
    /// colores vivos de la cover). Nil si la imagen es monocroma.
    static func secondaryColor(of image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let n = 24
        guard let ctx = CGContext(
            data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: n * n * 4)
        let bins = 12
        var weight = [Double](repeating: 0, count: bins)
        var accR = [Double](repeating: 0, count: bins)
        var accG = [Double](repeating: 0, count: bins)
        var accB = [Double](repeating: 0, count: bins)
        for i in 0..<(n * n) {
            let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            guard s > 0.18, v > 0.12, v < 0.97 else { continue }
            let bin = min(bins - 1, Int(h * CGFloat(bins)))
            let w = Double(s) * (0.4 + 0.6 * Double(v))
            weight[bin] += w
            accR[bin] += r * w; accG[bin] += g * w; accB[bin] += b * w
        }
        guard let top = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[top] > 0 else { return nil }
        // El mejor tono a distancia circular >= 3 casillas del dominante.
        let dist = { (a: Int, b: Int) in min((a - b + bins) % bins, (b - a + bins) % bins) }
        let second = weight.indices
            .filter { dist($0, top) >= 3 }
            .max(by: { weight[$0] < weight[$1] })
        guard let bin = second, weight[bin] > weight[top] * 0.12 else { return nil }
        let w = weight[bin]
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NSColor(srgbRed: accR[bin] / w, green: accG[bin] / w, blue: accB[bin] / w, alpha: 1)
            .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        s = max(0.5, min(s * 1.3, 1))
        b = min(max(b, 0.6), 0.9)
        return Color(hue: h, saturation: s, brightness: b)
    }

    // MARK: - utilidades

    private static func isRunning(_ app: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.localizedName == app }
    }

    private func runOut(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let pipe = Pipe(); p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Reproducción estilo Lumio: carátula con vinilo asomando, título en
/// mayúsculas, barra de progreso con tiempos, controles y fuente arriba
/// a la derecha. El color de la carátula ilumina el panel del notch.
struct MusicView: View {
    @ObservedObject var store: MusicStore

    private var fraction: Double {
        store.duration > 0 ? min(1, max(0, store.position / store.duration)) : 0
    }
    private var wash: Color { store.tint ?? Color.lumioMagenta }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                artworkStack
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.title.isEmpty ? "SILENCIO" : store.title.uppercased())
                        .font(.notchMono(15))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(store.title.isEmpty ? "Music / Spotify" : (store.artist.isEmpty ? store.source : store.artist))
                        .font(.notchMono(11))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                    progressBar
                        .padding(.top, 10)
                }
                Spacer(minLength: 6)
                controls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) { sourceLabel }
        .onAppear { store.poll() }
    }

    // MARK: - piezas

    private var artworkStack: some View {
        ZStack {
            // Vinilo asomando detrás de la carátula.
            Circle()
                .fill(Color.black.opacity(0.9))
                .frame(width: 62, height: 62)
                .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
                .overlay(
                    Circle().stroke(Color.white.opacity(0.10), lineWidth: 1)
                        .frame(width: 40, height: 40)
                )
                .overlay(
                    Circle().fill(Color.white.opacity(0.25)).frame(width: 6, height: 6)
                )
                .offset(x: 27)
            Group {
                if let art = store.artwork {
                    Image(nsImage: art)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [wash.opacity(0.55), Color.black.opacity(0.8)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        Image(systemName: "music.note")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
            .frame(width: 74, height: 74)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        }
        .frame(width: 104, height: 78)
    }

    private var progressBar: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule()
                        .fill(wash)
                        .frame(width: max(4, geo.size.width * fraction), height: 4)
                }
            }
            .frame(height: 4)
            .animation(.linear(duration: 0.9), value: store.position)
            HStack {
                Text(Self.fmt(store.position))
                Spacer()
                Text("-" + Self.fmt(max(0, store.duration - store.position)))
            }
            .font(.notchMono(9))
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button { store.back() } label: {
                Image(systemName: "backward.fill")
            }
            .help("Anterior")
            Button { store.togglePlay() } label: {
                Image(systemName: store.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 19, weight: .semibold))
            }
            .help(store.playing ? "Pausa" : "Reproducir")
            Button { store.next() } label: {
                Image(systemName: "forward.fill")
            }
            .help("Siguiente")
        }
        .buttonStyle(.plain)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.trailing, 4)
    }

    private var sourceLabel: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(store.title.isEmpty ? Color.white.opacity(0.3) : wash.opacity(store.playing ? 1 : 0.45))
                .frame(width: 5, height: 5)
            Text(store.source.isEmpty ? "MÚSICA" : store.source.uppercased())
                .font(.notchMono(9))
                .kerning(1)
        }
        .foregroundStyle(Color.white.opacity(0.5))
    }

    private static func fmt(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
#endif
