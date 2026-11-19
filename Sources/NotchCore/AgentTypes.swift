import Foundation

/// Los 16 agentes que Lumio soporta. Este clon los monitorea a todos.
public enum AgentID: String, CaseIterable, Codable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case cursor
    case copilot
    case antigravity
    case geminiCLI = "gemini-cli"
    case opencode
    case kilo
    case pi
    case qwenCode = "qwen-code"
    case cline
    case crush
    case hermes
    case kimiCode = "kimi-code"
    case grok
    case droid

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .copilot: return "GitHub Copilot"
        case .antigravity: return "Antigravity"
        case .geminiCLI: return "Gemini CLI"
        case .opencode: return "OpenCode"
        case .kilo: return "Kilo"
        case .pi: return "Pi"
        case .qwenCode: return "Qwen Code"
        case .cline: return "Cline"
        case .crush: return "Crush"
        case .hermes: return "Hermes Agent"
        case .kimiCode: return "Kimi Code"
        case .grok: return "Grok"
        case .droid: return "Droid"
        }
    }

    /// Color del notch por agente (como Lumio).
    public var notchColorHex: String {
        switch self {
        case .claudeCode: return "#D97757"
        case .codex: return "#FFFFFF"
        case .cursor: return "#007AFF"
        case .copilot: return "#6E40C9"
        case .antigravity: return "#00D4FF"
        case .geminiCLI: return "#4285F4"
        case .opencode: return "#000000"
        case .kilo: return "#FF5C5C"
        case .pi: return "#00C07F"
        case .qwenCode: return "#615CED"
        case .cline: return "#4ADE80"
        case .crush: return "#FF9F0A"
        case .hermes: return "#FFD60A"
        case .kimiCode: return "#34C759"
        case .grok: return "#AAAAAA"
        case .droid: return "#30D158"
        }
    }
}

public enum AgentStatus: String, Codable, Sendable, Equatable {
    case working
    case waiting   // necesita tu "yes"
    case done
    case crashed
    case idle      // instalado pero sin actividad
}

public struct AgentSession: Codable, Sendable, Equatable {
    public var agent: AgentID
    public var sessionID: String
    public var status: AgentStatus
    public var pid: Int32?
    public var cpuPercent: Double?
    public var lastActivity: Date?
    public var projectPath: String?
    public var detail: String?

    public init(agent: AgentID, sessionID: String, status: AgentStatus, pid: Int32? = nil, cpuPercent: Double? = nil, lastActivity: Date? = nil, projectPath: String? = nil, detail: String? = nil) {
        self.agent = agent; self.sessionID = sessionID; self.status = status
        self.pid = pid; self.cpuPercent = cpuPercent; self.lastActivity = lastActivity
        self.projectPath = projectPath; self.detail = detail
    }
}
