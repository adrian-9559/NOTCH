#if os(macOS)
import AppKit
import NotchCore
import SwiftUI

extension Notification.Name {
    /// Cambiar a una pestaña por su id ("notes", "tasks"…).
    static let notchShowTab = Notification.Name("notchShowTab")
}

/// Lanzador + búsqueda global (estilo Raycast/Spotlight del notch):
/// apps, archivos recientes, calculadora y búsqueda en notas,
/// tareas, portapapeles e historial de agentes. Todo local.
struct LauncherView: View {
    @ObservedObject private var settings = NotchSettings.shared
    @State private var query = ""
    @State private var apps: [(name: String, path: String)] = []
    @State private var recents: [URL] = []
    @State private var copied = false
    private let ctx = NotchContext.shared

    private var q: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NotchTextField(
                placeholder: tr("launch.ph"), text: $query,
                icon: "magnifyingglass", color: settings.accent, font: .caption,
                onCommit: commit
            )

            if let r = calcResult {
                calcRow(r)
            }

            if q.isEmpty {
                if !recents.isEmpty {
                    section(tr("launch.files")) {
                        ForEach(recents.prefix(5), id: \.absoluteString) { url in
                            fileRow(url)
                        }
                    }
                }
            } else {
                let apps_ = appResults
                let files_ = fileResults
                let notes_ = noteResults
                let tasks_ = taskResults
                let clips_ = clipResults

                if !apps_.isEmpty {
                    section(tr("launch.apps")) {
                        ForEach(apps_, id: \.path) { a in
                            appRow(a)
                        }
                    }
                }
                if !files_.isEmpty {
                    section(tr("launch.files")) {
                        ForEach(files_.prefix(5), id: \.absoluteString) { url in
                            fileRow(url)
                        }
                    }
                }
                if !notes_.isEmpty {
                    section(tr("launch.notes")) {
                        ForEach(Array(notes_.enumerated()), id: \.offset) { _, line in
                            row(icon: "note.text", text: line) {
                                NotificationCenter.default.post(name: .notchShowTab, object: "notes")
                            }
                        }
                    }
                }
                if !tasks_.isEmpty {
                    section(tr("launch.tasks")) {
                        ForEach(tasks_.prefix(4)) { t in
                            row(icon: "checklist", text: t.title) {
                                NotificationCenter.default.post(name: .notchShowTab, object: "tasks")
                            }
                        }
                    }
                }
                if !clips_.isEmpty {
                    section(tr("launch.clips")) {
                        ForEach(clips_.prefix(3)) { c in
                            row(icon: "doc.on.clipboard", text: String(c.text.prefix(80))) {
                                copyToPasteboard(c.text)
                            }
                        }
                    }
                }

                if apps_.isEmpty, files_.isEmpty, notes_.isEmpty, tasks_.isEmpty,
                   clips_.isEmpty, calcResult == nil {
                    Text(tr("launch.empty"))
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                }
            }

            if copied {
                Text(tr("launch.copied"))
                    .font(.notchMono(10))
                    .foregroundStyle(settings.accent)
            }
        }
        .onAppear {
            loadRecents()
            loadAppsAsync()
        }
        .onChange(of: query) { _ in copied = false }
    }

    // MARK: - Resultados

    /// Calculadora: expresión aritmética pura → resultado.
    private var calcResult: Double? {
        guard q.count > 1,
              q.range(of: "^[0-9+\\-*/(). ]+$", options: .regularExpression) != nil,
              q.range(of: "[+\\-*/]", options: .regularExpression) != nil
        else { return nil }
        // Parser propio: NSExpression lanzaría excepción ObjC con
        // basura como «2++3» y tumba la app entera (¡crash de
        // usuario real!); esto devuelve nil sin excepciones.
        guard let v = Arith.eval(q), v.isFinite else { return nil }
        return v
    }

    private var appResults: [(name: String, path: String)] {
        apps.filter { $0.name.localizedCaseInsensitiveContains(q) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(6)
            .map { $0 }
    }

    private var fileResults: [URL] {
        recents.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(q) }
    }

    private var noteResults: [String] {
        ctx.quickNote.lastSaved
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.localizedCaseInsensitiveContains(q) }
            .prefix(3)
            .map { String($0) }
    }

    private var taskResults: [AgentTask] {
        ctx.tasks.tasks
            .filter { $0.title.localizedCaseInsensitiveContains(q)
                || $0.detail.localizedCaseInsensitiveContains(q) }
            .prefix(4)
            .map { $0 }
    }

    private var clipResults: [ClipEntry] {
        ctx.clips.clips
            .filter { $0.text.localizedCaseInsensitiveContains(q) }
            .prefix(3)
            .map { $0 }
    }

    // MARK: - Filas

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.notchMono(9))
                .foregroundStyle(Color.white.opacity(0.45))
                .kerning(1)
            content()
        }
    }

    private func appRow(_ a: (name: String, path: String)) -> some View {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: a.path))
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: a.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(a.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "return")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fileRow(_ url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(url.lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.notchMono(9))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .lineLimit(1)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(icon: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(settings.accent)
                    .frame(width: 16)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func calcRow(_ r: Double) -> some View {
        Button {
            let s = Self.fmt(r)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
            copied = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "equal.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(settings.accent)
                Text(q)
                    .font(.notchMono(11))
                    .foregroundStyle(Color.white.opacity(0.6))
                Spacer(minLength: 0)
                Text(Self.fmt(r))
                    .font(.notchMono(14))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(settings.accent.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(settings.accent.opacity(0.35), lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static func fmt(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 {
            return String(Int64(v))
        }
        return String(format: "%.4f", v).replacingOccurrences(of: "0+$", with: "",
                                                              options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }

    // MARK: - Datos

    private func commit() {
        if let r = calcResult {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.fmt(r), forType: .string)
            copied = true
            return
        }
        if let a = appResults.first {
            NSWorkspace.shared.open(URL(fileURLWithPath: a.path))
            return
        }
        if let f = fileResults.first {
            NSWorkspace.shared.open(f)
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }

    private func loadRecents() {
        recents = NSDocumentController.shared.recentDocumentURLs
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .prefix(12)
            .map { $0 }
    }

    /// Apps en segundo hilo (cientos de .app): el campo ya está vivo.
    private func loadAppsAsync() {
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [(String, String)] = []
            let dirs = ["/Applications", "/System/Applications",
                        "/Applications/Utilities",
                        NSHomeDirectory() + "/Applications"]
            for d in dirs {
                guard let items = try? FileManager.default.contentsOfDirectory(atPath: d) else { continue }
                for i in items where i.hasSuffix(".app") {
                    let path = (d as NSString).appendingPathComponent(i)
                    let name = FileManager.default.displayName(atPath: path)
                    out.append((name, path))
                }
            }
            DispatchQueue.main.async {
                self.apps = out.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            }
        }
    }
}

#endif
