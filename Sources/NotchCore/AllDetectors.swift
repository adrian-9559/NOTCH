import Foundation

private struct GenericDetector: AgentDetector {
    let agent: AgentID
    let processHints: [String]
    var processExclusions: [String] = []
    let sessionPaths: [String]
}

/// Los 16 detectores. Rutas verificadas en este Mac donde existen;
/// el resto degrada a detección por proceso (no falla si la ruta no existe).
public enum AllDetectors {
    public static var all: [any AgentDetector] {
        [
            GenericDetector(agent: .claudeCode,
                processHints: ["claude"],
                sessionPaths: ["~/.claude/sessions", "~/.claude/ide", "~/.claude.json", "~/.claude/settings.json"]),
            GenericDetector(agent: .codex,
                processHints: ["codex"],
                sessionPaths: ["~/.codex/logs_2.sqlite", "~/.codex/state_5.sqlite", "~/.codex/ipc", "~/.codex/queue_1.sqlite"]),
            GenericDetector(agent: .cursor,
                processHints: ["cursor.app", "/cursor", "cursor "],
                processExclusions: ["cursoruiviewservice", "cursoruiview", "cursord"],
                sessionPaths: ["~/Library/Application Support/Cursor"]),
            GenericDetector(agent: .copilot,
                processHints: ["copilot-runtime", "copilot"],
                sessionPaths: ["~/.copilot/session-state", "~/.copilot/logs", "~/.copilot/config.json"]),
            GenericDetector(agent: .antigravity,
                processHints: ["antigravity"],
                sessionPaths: ["~/.antigravity", "~/Library/Application Support/Antigravity"]),
            GenericDetector(agent: .geminiCLI,
                processHints: ["gemini"],
                sessionPaths: ["~/.gemini", "~/.config/gemini"]),
            GenericDetector(agent: .opencode,
                processHints: ["opencode"],
                sessionPaths: ["~/.local/share/opencode/opencode.db", "~/.local/share/opencode/shell", "~/.opencode"]),
            GenericDetector(agent: .kilo,
                processHints: ["kilo"],
                sessionPaths: ["~/.kilo", "~/.config/kilo"]),
            GenericDetector(agent: .pi,
                processHints: [" pi ", "/pi ", "pi-mono", "picode"],
                sessionPaths: ["~/.pi"]),
            GenericDetector(agent: .qwenCode,
                processHints: ["qwen"],
                sessionPaths: ["~/.qwen"]),
            GenericDetector(agent: .cline,
                processHints: ["cline"],
                sessionPaths: ["~/.cline", "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"]),
            GenericDetector(agent: .crush,
                processHints: ["crush"],
                sessionPaths: ["~/.crush", "~/.config/crush"]),
            GenericDetector(agent: .hermes,
                processHints: ["hermes"],
                sessionPaths: ["~/.hermes", "~/.config/hermes"]),
            GenericDetector(agent: .kimiCode,
                processHints: ["kimi", "moonshot"],
                sessionPaths: ["~/.kimi"]),
            GenericDetector(agent: .grok,
                processHints: ["grok"],
                sessionPaths: ["~/.grok", "~/.config/grok"]),
            GenericDetector(agent: .droid,
                processHints: ["droid"],
                sessionPaths: ["~/.droid", "~/.config/droid"]),
        ]
    }
}
