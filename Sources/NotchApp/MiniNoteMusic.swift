#if os(macOS)
import AppKit
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
            Text("una idea? ⌥ der.").font(.caption).foregroundStyle(.secondary)
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

// MARK: - Música: qué suena (Music.app / Spotify por AppleScript)

final class MusicStore: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var source = ""
    @Published var playing = false

    func poll() {
        if let t = query(app: "Music", trackCmd: "name of current track", artistCmd: "artist of current track") {
            apply(t, source: "Music")
        } else if let t = query(app: "Spotify", trackCmd: "name of current track", artistCmd: "artist of current track") {
            apply(t, source: "Spotify")
        } else {
            playing = false
        }
    }

    private func apply(_ t: (String, String, Bool), source: String) {
        title = t.0; artist = t.1; playing = t.2; self.source = source
    }

    private func query(app: String, trackCmd: String, artistCmd: String) -> (String, String, Bool)? {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == app }) else { return nil }
        let script = """
        tell application "\(app)"
            if player state is playing then
                return (\(trackCmd) as string) & " | " & (\(artistCmd) as string) & " | playing"
            else
                return " |  | stopped"
            end if
        end tell
        """
        guard let out = runOut(script), !out.isEmpty else { return nil }
        let parts = out.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, !parts[0].isEmpty else { return nil }
        return (parts[0], parts[1], parts[2] == "playing")
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

struct MusicView: View {
    @ObservedObject var store: MusicStore
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @State private var wave = 0
    private let waveTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.playing ? store.title : "Silencio")
                    .font(.callout).lineLimit(1)
                Text(store.playing ? "\(store.artist) · \(store.source)" : "Music / Spotify")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            // Onda con sus colores.
            HStack(spacing: 2) {
                ForEach(0..<12, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(waveColor)
                        .frame(width: 3, height: waveHeight(i))
                }
            }
        }
        .padding(8)
        .onAppear { store.poll() }
        .onReceive(timer) { _ in store.poll() }
        .onReceive(waveTimer) { _ in wave += 1 }
    }

    // Subexpresiones aparte: el type-checker de CI (Swift 6.1) no
    // resuelve el body entero en un plazo razonable.
    private var icon: String { store.playing ? "music.note" : "music.note.list" }
    private var waveColor: Color { store.playing ? .accentColor : .gray.opacity(0.4) }
    private func waveHeight(_ i: Int) -> CGFloat {
        store.playing ? CGFloat(4 + ((i * 7 + wave) % 14)) : 4
    }
}
#endif
