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
        lastAction = urls.count == 1 ? "Añadido: \(urls[0].lastPathComponent)" : "Añadidos \(urls.count) archivos"
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
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
        for u in currentScreenshots() where !knownScreenshots.contains(u.path) {
            knownScreenshots.insert(u.path)
            // Solo las recientes (últimos 60s) entran solas.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
               let m = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(m) < 120 {
                var item = ShelfItem(url: u)
                item.autoScreenshot = true
                if !items.contains(where: { $0.url == u }) { items.append(item) }
                lastAction = "Screenshot: \(u.lastPathComponent)"
            }
        }
    }

    // MARK: - Acciones (el original nunca modifica el archivo)

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func shareViaAirDrop(_ item: ShelfItem) {
        guard let svc = NSSharingService(named: .sendViaAirDrop) else {
            lastAction = "AirDrop no disponible"; return
        }
        svc.perform(withItems: [item.url])
        lastAction = "Compartiendo por AirDrop…"
    }

    func compress(_ item: ShelfItem) {
        let dst = item.url.deletingPathExtension().appendingPathExtension("zip")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-c", "-k", "--sequesterRsrc", item.url.path, dst.path]
        do {
            try task.run(); task.waitUntilExit()
            if task.terminationStatus == 0 {
                add(urls: [dst]); lastAction = "Comprimido: \(dst.lastPathComponent)"
            } else { lastAction = "No se pudo comprimir" }
        } catch { lastAction = "No se pudo comprimir" }
    }

    func convertToJPG(_ item: ShelfItem) {
        guard let img = NSImage(contentsOf: item.url),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            lastAction = "JPG: formato no soportado"; return
        }
        let dst = item.url.deletingPathExtension().appendingPathExtension("jpg")
        do {
            try jpg.write(to: dst)
            add(urls: [dst]); lastAction = "JPG: \(dst.lastPathComponent)"
        } catch { lastAction = "No se pudo crear el JPG" }
    }

    func convertToPDF(_ item: ShelfItem) {
        guard let img = NSImage(contentsOf: item.url) else {
            lastAction = "PDF: formato no soportado"; return
        }
        // Una página con la imagen encajada.
        let page = NSRect(x: 0, y: 0, width: 595, height: 842) // A4 @72dpi
        let pdf = NSMutableData()
        var mediaBox = page
        guard let consumer = CGDataConsumer(data: pdf as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            lastAction = "No se pudo crear el PDF"; return
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
        } catch { lastAction = "No se pudo crear el PDF" }
    }

    // MARK: - "To agent": entregar a la sesión elegida

    func sendToAgent(_ item: ShelfItem, session: AgentSession) {
        let ok = HandoffService.deliver(path: item.url.path, to: session)
        if ok {
            lastAction = "Entregado a \(session.agent.displayName)"
        } else {
            // Fallback: path en portapapeles + ventana al frente, pulsa ⌘V.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(item.url.path, forType: .string)
            ReplyService.shared.focus(session: session)
            lastAction = "Path copiado — pulsa ⌘V en \(session.agent.displayName)"
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

// MARK: - Vista

struct ShelfView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var shelf: ShelfStore
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("shelf").font(.notchMono(11)).foregroundStyle(.secondary)
                Spacer()
                Text(shelf.lastAction).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if shelf.items.isEmpty {
                Text("Arrastra un archivo al notch")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.25)))
            } else {
                ForEach(shelf.items) { item in
                    ShelfRow(item: item, store: store, shelf: shelf)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(isTargeted ? Color.blue.opacity(0.15) : Color.gray.opacity(0.2)))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: item.autoScreenshot ? "camera" : "doc")
                Text(item.displayName).font(.notchMono(13)).lineLimit(1)
                Spacer()
                Button("Ver") { shelf.reveal(item) }.buttonStyle(.link).font(.caption)
                Button("Borrar") { shelf.remove(item) }.buttonStyle(.link).font(.caption)
            }
            HStack {
                Button("AirDrop") { shelf.shareViaAirDrop(item) }.controlSize(.small)
                Button("Zip") { shelf.compress(item) }.controlSize(.small)
                Button("JPG") { shelf.convertToJPG(item) }.controlSize(.small)
                Button("PDF") { shelf.convertToPDF(item) }.controlSize(.small)
            }
            .buttonStyle(.bordered)
            if !live.isEmpty {
                HStack {
                    Text("To agent:").font(.caption).foregroundStyle(.secondary)
                    ForEach(live, id: \.agent) { s in
                        Button(s.agent.displayName) { shelf.sendToAgent(item, session: s) }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background))
    }
}
#endif
