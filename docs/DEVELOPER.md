# NOTCH — Guía de desarrollo

Arquitectura, cómo compilar/testear y **modelo de ramas** (lectura obligatoria
antes de tu primer commit).

## Mapa del repo

```
Sources/NotchCore/      # Motor puro (Foundation). Testeable, sin AppKit.
  AgentTypes.swift      # AgentID x16 + colores, AgentStatus, AgentSession
  AgentDetector.swift   # Protocolo + heurística working/waiting/done/crashed
  AllDetectors.swift    # Los 16 GenericDetector (hints, exclusiones, rutas)
  MonitorEngine.swift   # ProcessMonitor (ps sin deadlock) + poll()
Sources/NotchApp/       # App AppKit/SwiftUI (solo macOS 14+)
  main.swift            # --monitor-once (CLI) o NSApplication
  SessionStore.swift    # Fuente de verdad ObservableObject
  NotchWindow.swift     # NSPanel flotante + controlador
  NotchRootView.swift   # Luces + tarjetas waiting (callbacks inyectados)
  Shelf.swift           # ShelfStore + HandoffService + vistas + screenshots
  ReplyService.swift    # Allow/reply/open (iTerm → AX → clipboard)
  OfficeHotKey.swift    # Doble-tap ⌘ derecha
  MiniTabs.swift        # NotchContext + registro de pestañas
  MiniTimerAwake.swift  # Timer + caffeinate + BatteryInfo
  MiniStats.swift       # host_statistics + top agente
  MiniNoteMusic.swift   # Quick-note + Music/Spotify por AppleScript
  MiniHistorySettings.swift # JSONL + vistas día/semana + ajustes
Tests/NotchCoreTests/   # DetectorTests (6 tests, mocks de snapshot)
```

Reglas de dependencias: `NotchApp → NotchCore`. Nada en Core importa AppKit.
La UI nunca lee el motor directamente: todo pasa por `SessionStore`.

## Build y test

```sh
swift build
swift test
./.build/debug/NotchApp --monitor-once   # humo del motor con datos reales
```

La app (`./.build/debug/NotchApp`) es accessory: vive en la barra de menús.
Para depurar la UI, ábrela y usa "Abrir notch".

Casos reales que ya nos mordieron (tests que lo cubren):

- `ps` con cientos de procesos llena el pipe → leer **antes** de `waitUntilExit`.
- Locale es_ES: `%CPU` con coma (`5,5`) → normalizar a punto al parsear.
- Falsos positivos de `cursor`: `HideCursorWhileTyping`, `CursorUIViewService`
  → `processExclusions` + hints estrictos + preferencia por basename.
- Ternarios de estilos distintos (`.bordered` vs `.borderedProminent`) cuelgan
  a este compilador en algunos `body` → usar `if/else`.

## Añadir un agente nuevo

1. Nuevo `case` en `AgentID` (+ nombre y `notchColorHex`).
2. Nuevo `GenericDetector` en `AllDetectors.all` con:
   - `processHints` en minúsculas (prefiere el nombre del binario),
   - `processExclusions` si hay colisiones conocidas,
   - `sessionPaths` con `~` (pueden no existir: hay degradado a proceso).
3. Añade su bundle ID en `ReplyService.candidateBundleIDs`.
4. Test en `DetectorTests` con `SystemSnapshot(tuples: [...])`.
5. Verifica con `--monitor-once` teniendo el agente corriendo.

## Modelo de ramas (obligatorio)

```
main                  # estable, lo que está publicado
develop               # integración, TODO nace de aquí
  feature/<nombre>    # nueva implementación
  fix/<nombre>        # arreglo
```

- **`main`**: solo recibe merges desde `develop` cuando hay release.
  Nunca se commitea directo.
- **`develop`**: rama de integración. Todo `feature/*` y `fix/*` sale de aquí
  y vuelve aquí vía pull request.
- **`feature/<nombre-nueva-implementacion>`**: para funcionalidad nueva.
  Ej.: `feature/pixel-office`, `feature/shelf-handoff`, `feature/notch-window`.
- **`fix/<nombre-de-arreglo>`**: para arreglos. Ej.: `fix/ps-pipe-deadlock`,
  `fix/comma-decimal-locale`, `fix/cursor-false-positive`.

### Flujo de trabajo

```sh
git checkout develop && git pull
git checkout -b feature/mi-cambio        # o fix/mi-arreglo
# ... commits pequeños y verificados ...
swift build && swift test                # verde antes de abrir PR
git push -u origin feature/mi-cambio
# PR contra develop → revisión → merge → borrar la rama
```

Commits: imperativo en español, alcance primero.
Ej.: `Shelf: prefill del reply al entregar a Codex`,
`Motor: exclusiones para CursorUIViewService`.

### CI

`.github/workflows/ci.yml` corre `swift build` + `swift test` en macos-14
en cada push y PR. Un PR con CI en rojo no se mergea.

## Privacidad por diseño

Nada sale del Mac: sin cuentas, sin analytics, sin Screen Recording.
Accessibility y Automatización son opt-in y con degradado documentado
(clipboard + `⌘V`). No añadas red sin discutirlo primero en un issue.
