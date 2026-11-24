#if os(macOS)
import AppKit
import ApplicationServices
import NotchCore

/// Respuesta desde el notch + abrir sesión del agente.
///
/// Niveles, de mejor a peor (todo local):
/// 1. iTerm al frente → AppleScript `write text` (sin Accessibility,
///    solo permiso de Automatización para iTerm).
/// 2. Accessibility concedida → foco + ⌘V sintetizado + Enter si hay
///    auto-send activado (opt-in, como el Claude de Lumio).
/// 3. Sin permisos → path/texto al portapapeles + foco (el usuario pulsa ⌘V).
final class ReplyService {
    static let shared = ReplyService()
    private init() {}

    private let defaults = UserDefaults.standard
    private var autoSendKey: String { "notchAutoSend" }

    var autoSendEnabled: Bool {
        get { defaults.bool(forKey: autoSendKey) }
        set { defaults.set(newValue, forKey: autoSendKey) }
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Pide el permiso con el diálogo del sistema. Solo si el usuario
    /// activa el auto-send (opt-in).
    @discardableResult
    func requestTrust() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    func allow(session: AgentSession) {
        reply(session: session, text: approvalText(for: session.agent))
    }

    func approvalText(for agent: AgentID) -> String {
        switch agent {
        case .claudeCode, .codex, .opencode, .geminiCLI, .qwenCode, .crush, .kimiCode: return "yes"
        default: return "Allow"
        }
    }

    func reply(session: AgentSession, text: String) {
        guard !text.isEmpty else { return }
        copy(text)
        // iTerm: inserción directa sin Accessibility.
        if isItermFrontmost(for: session) {
            HandoffService.osascript("tell application \"iTerm\" to tell current session of current window to write text \(HandoffService.quoted(text))")
            return
        }
        focus(session: session)
        guard isTrusted else { return } // nivel 3: el usuario pulsa ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pressCmdV()
            if self?.autoSendEnabled == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.pressEnter()
                }
            }
        }
    }

    func open(session: AgentSession) {
        focus(session: session)
    }

    // MARK: - Foco

    func focus(session: AgentSession) {
        let candidates = candidateBundleIDs(for: session.agent)
        let running = NSWorkspace.shared.runningApplications
        if let app = candidates.compactMap({ id in running.first(where: { $0.bundleIdentifier == id }) }).first {
            app.activate()
            return
        }
        if let id = candidates.first, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func candidateBundleIDs(for agent: AgentID) -> [String] {
        switch agent {
        case .cursor: return ["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode"]
        case .codex: return ["com.openai.codex", "com.microsoft.VSCode", "com.googlecode.iterm2", "com.apple.Terminal"]
        case .copilot: return ["com.microsoft.VSCode", "com.github.Copilot"]
        case .claudeCode, .opencode, .geminiCLI, .qwenCode, .crush, .kimiCode, .cline, .kilo, .pi, .hermes, .grok, .droid:
            return ["com.googlecode.iterm2", "com.apple.Terminal", "com.microsoft.VSCode", "com.mitchellh.ghostty"]
        case .antigravity: return ["com.google.antigravity"]
        }
    }

    // MARK: - Pegar desde el portapapeles (gestor Win+V)

    /// Copia implícita ya hecha: pega con ⌘V si hay confianza.
    /// Sin confianza no hace nada (el usuario pega con ⌘V a mano).
    func pasteFromClipboard() {
        guard isTrusted else { return }
        pressCmdV()
    }

    // MARK: - Privado

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func isItermFrontmost(for session: AgentSession) -> Bool {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return front == "com.googlecode.iterm2"
            && candidateBundleIDs(for: session.agent).contains("com.googlecode.iterm2")
    }

    private func pressCmdV() {
        keyTap(keyCode: 9, flags: .maskCommand) // V
    }

    private func pressEnter() {
        keyTap(keyCode: 36, flags: []) // Return
    }

    private func keyTap(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
#endif
