#if os(macOS)
import AppKit
import NotchCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Modelo

struct ShelfItem: Identifiable {
    let id = UUID()
    var url: URL
    var addedAt = Date()
    var autoScreenshot = false
    var displayName: String { url.lastPathComponent }
}

// MARK: - Store

final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published var lastAction: String = ""
    @Published var pendingPathForNotch = "" // para "va al reply del notch"
    private var watcher: Timer?
    private var knownScreenshots: Set<String> = []

    init() {
        startScreenshotWatcher()
    }

    func add(urls: [URL]) {
        for u in urls where !items.contains(where: { $0.url == u }) {
            items.append(ShelfItem(url: u))
        }
        lastAction = urls.count == 1 ? tr("shelf.added", urls[0].lastPathComponent) : tr("shelf.addedN", urls.count)
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
    }

    /// Como Lumio ("kept for a day"): lo que lleva 24 h se retira solo.
    /// El original nunca se toca: solo sale de la estantería.
    static let keepHours: TimeInterval = 24 * 3600

    func purgeExpired() {
        let cutoff = Date().addingTimeInterval(-Self.keepHours)
        let n = items.count
        items.removeAll { $0.addedAt < cutoff }
        if items.count != n {
            lastAction = tr("shelf.retiredN", n - items.count)
        }
    }

    /// Cuánto le queda en la estantería ("se borra en 5h").
    func remaining(_ item: ShelfItem) -> String {
        let left = item.addedAt.addingTimeInterval(Self.keepHours).timeIntervalSince(Date())
        guard left > 0 else { return tr("shelf.retiring") }
        let h = Int(left) / 3600
        if h > 0 { return tr("shelf.expiryH", h) }
        return tr("shelf.expiryM", max(1, Int(left) / 60))
    }

    // MARK: - Screenshots automáticos

    private func screenshotDirs() -> [URL] {
        let fm = FileManager.default
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
        var dirs = [desktop].compactMap { $0 }
        // Respeta el destino configurado de screencapture.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", "com.apple.screencapture", "location"]
        let pipe = Pipe(); task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        if (try? task.run()) != nil {
            task.waitUntilExit()
            let loc = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !loc.isEmpty {
                let expanded = (loc as NSString).expandingTildeInPath
                dirs.append(URL(fileURLWithPath: expanded))
            }
        }
        return dirs
    }

    private func startScreenshotWatcher() {
        seedKnownScreenshots()
        watcher = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.collectNewScreenshots()
        }
    }

    private func seedKnownScreenshots() {
        knownScreenshots = Set(currentScreenshots().map(\.path))
    }

    private func currentScreenshots() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for dir in screenshotDirs() {
            let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            for k in kids where Self.isScreenshot(k) {
                out.append(k)
            }
        }
        return out
    }

    static func isScreenshot(_ url: URL) -> Bool {
        let n = url.lastPathComponent.lowercased()
        guard ["png", "jpg", "jpeg", "tiff"].contains(url.pathExtension.lowercased()) else { return false }
        return n.contains("screenshot") || n.contains("screen shot") || n.contains("captura de pantalla") || n.contains("grabaci")
    }

    private func collectNewScreenshots() {
        purgeExpired()
        for u in currentScreenshots() where !knownScreenshots.contains(u.path) {
            knownScreenshots.insert(u.path)
            // Solo las recientes (últimos 60s) entran solas.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
               let m = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(m) < 120 {
                var item = ShelfItem(url: u)
                item.autoScreenshot = true
                if !items.contains(where: { $0.url == u }) { items.append(item) }
                lastAction = tr("shelf.shot", u.lastPathComponent)
            }
        }
    }

    // MARK: - Acciones (el original nunca modifica el archivo)

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func shareViaAirDrop(_ item: ShelfItem) {
        guard let svc = NSSharingService(named: .sendViaAirDrop) else {
            lastAction = tr("shelf.noAirdrop"); return
        }
        svc.perform(withItems: [item.url])
        lastAction = tr("shelf.sharing")
    }

    func compress(_ item: ShelfItem) {
        let dst = item.url.deletingPathExtension().appendingPathExtension("zip")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-c", "-k", "--sequesterRsrc", item.url.path, dst.path]
        do {
            try task.run(); task.waitUntilExit()
            if task.terminationStatus == 0 {
                add(urls: [dst]); lastAction = tr("shelf.compressed", dst.lastPathComponent)
            } else { lastAction = tr("shelf.noCompress") }
        } catch { lastAction = tr("shelf.noCompress") }
    }

    func convertToJPG(_ item: ShelfItem) {
        guard let img = NSImage(contentsOf: item.url),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            lastAction = tr("shelf.badFormat", "JPG"); return
        }
        let dst = item.url.deletingPathExtension().appendingPathExtension("jpg")
        do {
            try jpg.write(to: dst)
            add(urls: [dst]); lastAction = tr("shelf.jpg", dst.lastPathComponent)
        } catch { lastAction = tr("shelf.noCreate", "JPG") }
    }

    func convertToPDF(_ item: ShelfItem) {
        guard let img = NSImage(contentsOf: item.url) else {
            lastAction = tr("shelf.badFormat", "PDF"); return
        }
        // Una página con la imagen encajada.
        let page = NSRect(x: 0, y: 0, width: 595, height: 842) // A4 @72dpi
        let pdf = NSMutableData()
        var mediaBox = page
        guard let consumer = CGDataConsumer(data: pdf as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            lastAction = tr("shelf.noCreate", "PDF"); return
        }
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
            let scale = min((page.width - 72) / iw, (page.height - 72) / ih)
            let w = iw * scale, h = ih * scale
            ctx.draw(cg, in: CGRect(x: (page.width - w) / 2, y: (page.height - h) / 2, width: w, height: h))
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage(); ctx.closePDF()
        let dst = item.url.deletingPathExtension().appendingPathExtension("pdf")
        do {
            try (pdf as Data).write(to: dst)
            add(urls: [dst]); lastAction = "PDF: \(dst.lastPathComponent)"
        } catch { lastAction = tr("shelf.noCreate", "PDF") }
    }

    // MARK: - "To agent": entregar a la sesión elegida

    func sendToAgent(_ item: ShelfItem, session: AgentSession) {
        let ok = HandoffService.deliver(path: item.url.path, to: session)
        if ok {
            lastAction = tr("shelf.delivered", session.agent.displayName)
        } else {
            // Fallback: path en portapapeles + ventana al frente, pulsa ⌘V.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(item.url.path, forType: .string)
            ReplyService.shared.focus(session: session)
            lastAction = tr("shelf.pathHint", session.agent.displayName)
        }
    }
}

// MARK: - Handoff por terminal

enum HandoffService {
    /// true si el path quedó insertado en el prompt del agente.
    static func deliver(path: String, to session: AgentSession) -> Bool {
        let running = NSWorkspace.shared.runningApplications
        let isRunning: (String) -> Bool = { id in running.contains { $0.bundleIdentifier == id } }

        if isRunning("com.googlecode.iterm2") {
            // En iTerm el path aparece en el prompt por sí solo.
            return osascript("tell application \"iTerm\" to tell current session of current window to write text \(quoted(path))")
        }
        if session.agent == .codex || session.agent == .claudeCode,
           isRunning("com.microsoft.VSCode") || isRunning("com.openai.codex") {
            // Codex app y Claude en VS Code: va al reply del notch.
            NotificationCenter.default.post(name: .notchPrefillReply, object: path)
            ReplyService.shared.focus(session: session)
            return true
        }
        return false
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    @discardableResult
    static func osascript(_ source: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run(); task.waitUntilExit(); return task.terminationStatus == 0 }
        catch { return false }
    }
}

extension Notification.Name {
    static let notchPrefillReply = Notification.Name("notchPrefillReply")
}

// MARK: - Vista estilo Lumio: dropzone punteada + kept for a day

/// Personaje de pie junto a la dropzone, como el de Lumio.
struct ShelfBuddy: View {
    var body: some View {
        VStack(spacing: 0) {
            // Cabeza + pelo.
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.85, green: 0.68, blue: 0.55)).frame(width: 22, height: 22)
                RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.3, green: 0.2, blue: 0.12)).frame(width: 24, height: 10).offset(y: -7)
                // Ojos.
                HStack(spacing: 6) {
                    Circle().fill(Color.black).frame(width: 2.5, height: 2.5)
                    Circle().fill(Color.black).frame(width: 2.5, height: 2.5)
                }
                .offset(y: 1)
            }
            // Cazadora negra + camisa.
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color(red: 0.12, green: 0.12, blue: 0.14)).frame(width: 34, height: 40)
                RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 10, height: 30)
                // Brazos.
                HStack(spacing: 30) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.12, green: 0.12, blue: 0.14)).frame(width: 8, height: 34)
                    RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.12, green: 0.12, blue: 0.14)).frame(width: 8, height: 34)
                }
            }
            // Vaqueros + zapatos.
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.2, green: 0.3, blue: 0.5)).frame(width: 11, height: 34)
                RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.2, green: 0.3, blue: 0.5)).frame(width: 11, height: 34)
            }
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 2).fill(Color.black).frame(width: 13, height: 6)
                RoundedRectangle(cornerRadius: 2).fill(Color.black).frame(width: 13, height: 6)
            }
        }
    }
}

struct ShelfView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var shelf: ShelfStore
    @ObservedObject private var settings = NotchSettings.shared
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("shelf").font(.notchMono(11)).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "tray").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(tr("shelf.kept")).font(.notchMono(10)).foregroundStyle(.secondary)
                }
                .help(tr("shelf.kept"))
            }
            HStack(alignment: .bottom, spacing: 10) {
                ShelfBuddy()
                // Dropzone punteada verde, como Lumio.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "basket").font(.system(size: 13)).foregroundStyle(Color(hex: "2F9E6E"))
                        Text(tr("shelf.drop"))
                            .font(.notchMono(12)).foregroundStyle(.white)
                    }
                    Text(tr("shelf.dropSub"))
                        .font(.caption).foregroundStyle(Color.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isTargeted ? Color(hex: "2F9E6E").opacity(0.18) : Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(hex: "2F9E6E").opacity(isTargeted ? 0.9 : 0.5),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                )
            }
            if !shelf.lastAction.isEmpty {
                Text(shelf.lastAction).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            ForEach(shelf.items) { item in
                ShelfRow(item: item, store: store, shelf: shelf)
            }
        }
        .padding(8)
        .onAppear { shelf.purgeExpired() }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { shelf.add(urls: [url]) } }
                }
            }
            return true
        }
    }
}

private struct ShelfRow: View {
    var item: ShelfItem
    @ObservedObject var store: SessionStore
    @ObservedObject var shelf: ShelfStore

    var live: [AgentSession] {
        store.sessions.filter { $0.status == .working || $0.status == .waiting }
    }

    /// Miniatura si es imagen; icono del sistema si no.
    private var thumb: some View {
        Group {
            if let img = NSImage(contentsOf: item.url) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08))
                    Image(systemName: "doc")
                        .font(.system(size: 14)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            thumb
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.displayName).font(.notchMono(12)).lineLimit(1)
                    Spacer()
                    Text(shelf.remaining(item)).font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Button(tr("shelf.airdrop")) { shelf.shareViaAirDrop(item) }
                    Button("Zip") { shelf.compress(item) }
                    Button("JPG") { shelf.convertToJPG(item) }
                    Button("PDF") { shelf.convertToPDF(item) }
                }
                .controlSize(.mini)
                .buttonStyle(.bordered)
                HStack(spacing: 4) {
                    Button(tr("shelf.view")) { shelf.reveal(item) }
                    Button(tr("shelf.path")) {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(item.url.path, forType: .string)
                        shelf.lastAction = tr("shelf.pathCopied")
                    }
                    Button(tr("shelf.delete")) { shelf.remove(item) }
                    if !live.isEmpty {
                        Menu(tr("shelf.toAgent")) {
                            ForEach(live, id: \.agent) { s in
                                Button(s.agent.displayName) { shelf.sendToAgent(item, session: s) }
                            }
                        }
                    }
                }
                .controlSize(.mini)
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background))
    }
}
#endif
