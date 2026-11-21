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
- **Aviso "ha terminado"**: cuando un agente acaba sale del notch una
  píldora con su color y qué ha terminado; se oculta sola.
- **Auto-send (opcional)**: en el modal de Ajustes (`⚙` o `⌘,`) puedes
  activar que la respuesta se envíe sola con Enter. macOS pedirá permiso de
  **Accesibilidad** una sola vez. Sin este permiso, NOTCH copia al portapapeles
  y pulsas `⌘V` tú.
- **Luz de canción**: mientras suena una canción, todo el panel se tiñe con
  el color dominante de su carátula (transición suave) y vuelve a su color
  normal al cerrar el reproductor.
- **Aura con el notch cerrado**: aunque no abras el panel, el notch se
  envuelve en un halo del color de la canción mientras suena; al pausar,
  se apaga.
- **Aviso de canción nueva**: al cambiar de canción sale del notch una
  píldora con la carátula en pequeño, el título y el ecualizador; se
  oculta sola a los pocos segundos.
- **Cover y onda junto al notch**: mientras suena algo, del notch sale una
  píldora negra con la carátula, el tiempo y la barra de progreso, con el
  borde iluminado del color de la canción (como Lumio, sin agentes ni
  tiempos). Al pausar se atenúa; al cerrar el reproductor desaparece.

## Pestañas

| Pestaña | Qué hace |
|---|---|
| Shelf | Dropzone punteada estilo Lumio (**kept for a day**: lo de 24 h se retira solo, el original no se toca). Por archivo: miniatura, **AirDrop**, **Zip**, **JPG**, **PDF**, Ver, Path y **To agent** (lo entrega a la sesión que elijas). Las capturas entran solas. |
| Focus | **Timer** con anillo (avisa para descansar la vista) y **Keep awake** configurable: evita el reposo de **Pantalla** y/o el **Salvapantallas**, con 30m, 1h, 2h, 4h, sin fin o **Auto** mientras trabajan (salvo batería baja), con cuenta atrás visible. |
| Mac | Estilo Lumio: anillos simples de **CPU** (`E·P`), **memoria** (`usada/total`, barra de presión + swap) y **batería**, pico del último minuto, **qué carga el Mac** (top procesos) y **AGENT SERVERS** (puertos en escucha con Open/Stop, mapeados al agente dueño). Abajo, la huella del propio NOTCH. |
| Actividad | **Tiempo por agente** (día / semana / mes) con barras por agente, minibarras de los últimos 7 días y **racha** de días seguidos con actividad. Todo sale del historial local. |
| Música | Reproducción estilo Lumio: carátula con vinilo asomando, título, barra de progreso con tiempos y controles ⏮ ⏸ ⏭. **El panel se ilumina con el color de la canción** (extraído de la carátula). Music.app y Spotify. |
| Notas | **Quick-note**: escribe y Enter. Se guarda en `~/NOTCH-notes/`, en tu daily note de Obsidian (configura el vault) o en Apple Notes. **Historial**: qué hizo cada agente, hora a hora, hoy y últimos 6 días. |
| ⚙ | Es el botón de la derecha en la navbar (o `⌘,`): abre el **modal de Ajustes** — color y opacidad del panel, orden y visibilidad de las pestañas, comportamiento y privacidad. |

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
