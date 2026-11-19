# NOTCH — clon de Lumio para macOS

Control room en el notch para tus agentes de IA. Monitorea **todos los agentes activos dentro del Mac**, sin Screen Recording, todo local.

Agentes soportados (16): Claude Code, Codex, Cursor, GitHub Copilot, Antigravity, Gemini CLI, OpenCode, Kilo, Pi, Qwen Code, Cline, Crush, Hermes Agent, Kimi Code, Grok, Droid.

## Cómo detecta (verificado en este Mac)

- `ps aux` + `NSWorkspace.runningApplications` para procesos vivos (`opencode`, `opencode serve`, `codex app-server`, `copilot-runtime`, etc.)
- Archivos de sesión locales con `mtime` reciente:
  - Claude: `~/.claude/sessions`, `~/.claude/ide`, `~/.claude.json`
  - Codex: `~/.codex/logs_2.sqlite`, `~/.codex/state_5.sqlite`, `~/.codex/ipc`
  - Copilot: `~/.copilot/session-state`, `~/.copilot/logs`
  - OpenCode: `~/.local/share/opencode/opencode.db`, `~/.local/share/opencode/shell`
  - Cursor/VSCode: `~/Library/Application Support/Code/User/workspaceStorage`
  - Resto: `~/.gemini`, `~/.qwen`, `~/.cline`, `~/.crush`, `~/.hermes`, `~/.kimi`, `~/.grok`, `~/.droid`, `~/.antigravity`, `~/.kilo`, `~/.pi` + nombre de proceso. Si no existen, degrada a detección por proceso.
- Estado: `working` (CPU alta o mtime < 60s), `waiting` (patrón approval/permission en log reciente), `done` (idle > 5 min), `crashed` (sesión reciente pero proceso muerto), `idle` resto.

## Estructura

```
Sources/NotchCore/      # lógica pura, testeable (sin AppKit)
Sources/NotchApp/       # NSStatusItem + NSPanel notch + office/shelf/mini
Sources/NotchOffice/    # pixel office (en NotchApp por ahora, stubs)
Tests/NotchCoreTests/
Scripts/install.sh
.github/workflows/ci.yml
```

## Build

```sh
swift build
swift test
swift run NotchApp -- --monitor-once   # imprime agentes activos y sale
```

App completa (notch UI) requiere Xcode 15+, macOS 14+:

```sh
open Package.swift   # genera proyecto Xcode
```

## GitHub

```sh
gh repo create NOTCH --public --source=. --push
```

MIT.
