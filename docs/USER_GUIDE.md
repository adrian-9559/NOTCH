# NOTCH — Guía de usuario

Clon de Lumio para macOS: tu notch se convierte en la sala de control de tus
agentes de IA (Claude Code, Codex, Cursor, Copilot, OpenCode y 11 más).
Todo ocurre en tu Mac. Sin cuentas, sin tracking, sin Screen Recording.

## Requisitos

- macOS 14 Sonoma o posterior (Apple silicon o Intel).
- Uno o varios agentes instalados: Claude Code, Codex, Cursor, Copilot,
  Antigravity, Gemini CLI, OpenCode, Kilo, Pi, Qwen Code, Cline, Crush,
  Hermes, Kimi, Grok o Droid.

## Instalación

Opción A — compilar tú mismo:

```sh
git clone https://github.com/adrian-9559/NOTCH.git
cd NOTCH
swift build -c release
```

El binario queda en `.build/release/NotchApp`. Cópialo a Aplicaciones
o ejecútalo desde ahí: aparece el icono `● NOTCH` en la barra de menús.

Opción B — release (cuando haya una publicada):

```sh
REPO=adrian-9559/NOTCH sh Scripts/install.sh
```

## Primer arranque

1. Abre NOTCH: verás `○ NOTCH` en la barra de menús.
2. Cuando un agente trabaje, el icono cambia a `● NOTCH (N)`.
3. Elige **Abrir notch** en el menú para ver el panel bajo el notch.
4. Si no tienes notch físico, el panel aparece centrado arriba:
   funciona igual (notch virtual).

## El notch

- **Fila de luces**: un punto por agente con su color. Brillante = activo,
  apagado = inactivo, anillo amarillo = te necesita, anillo verde = trabajando.
- **Aviso "te necesita"**: cuando un agente espera tu "yes" verás su tarjeta
  con tres botones:
  - **Allow**: aprueba con un clic (`yes` en CLIs, `Allow` en el resto).
  - **Responder…**: escribe y pulsa Enviar. En iTerm el texto entra directo;
    en Codex/VS Code cae en el campo del notch; en el resto queda copiado
    y solo tienes que pulsar `⌘V` en la ventana del agente.
  - **Abrir**: trae al frente la ventana del agente.
- **Auto-send (opcional)**: en la pestaña ⚙ puedes activar que la respuesta
  se envíe sola con Enter. macOS pedirá permiso de **Accesibilidad** una
  sola vez. Sin este permiso, NOTCH copia al portapapeles y pulsas `⌘V` tú.

## Pestañas

| Pestaña | Qué hace |
|---|---|
| Office | Oficina pixel-art: cada agente en su iMac. El que te necesita **se levanta**; el que terminó **se va al café**. Con 6+ agentes crece (sala, lounge, ciudad). La luz sigue la hora real. Ábrela con doble-tap de `⌘` derecha (requiere Accesibilidad; si no, usa el menú). |
| Shelf | Arrastra archivos al panel: quedan en la estantería o caen directo en una sesión viva. Botones por archivo: **To agent** (lo entrega a la sesión que elijas), AirDrop, Zip, JPG, PDF. Las capturas de pantalla entran solas. El original nunca se modifica. |
| Focus | **Timer** con anillo (avisa para descansar la vista) y **Keep awake** (30m/1h/2h o Auto mientras los agentes trabajan, salvo batería baja). |
| Mac | CPU, memoria, batería y **qué agente está cargando tu Mac**. |
| Notas | **Quick-note**: escribe y Enter. Se guarda en `~/NOTCH-notes/`, en tu daily note de Obsidian (configura el vault) o en Apple Notes. **Historial**: qué hizo cada agente, hora a hora, hoy y últimos 6 días. |
| ⚙ | Auto-send (Accessibility), ruta del vault de Obsidian y nota de privacidad. |

## Privacidad

- NOTCH solo lee los archivos de sesión de **tus** agentes en **tu** Mac.
- No pide Screen Recording. Solo pide Accesibilidad si activas auto-send,
  y Automatización solo cuando usas iTerm o Apple Notes.
- Conexiones: ninguna (salvo la descarga inicial). Tus datos no salen del Mac.

## Solución de problemas

- **No detecta mi agente**: comprueba que su proceso esté corriendo y que
  tenga archivos de sesión recientes (`swift run NotchApp -- --monitor-once`
  muestra lo que ve el motor).
- **Reply no llega**: sin Accesibilidad el texto queda en el portapapeles;
  pulsa `⌘V` en la ventana del agente. Para iTerm hace falta permitir
  Automatización la primera vez.
- **Doble-tap ⌘ no abre**: necesita Accesibilidad; usa "Abrir notch" del menú.
- **Música en silencio**: solo Music.app y Spotify por ahora; otros
  reproductores muestran "Silencio".
