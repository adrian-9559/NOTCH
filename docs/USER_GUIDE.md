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
- **Aviso "ha terminado"**: cuando un agente acaba DE VERDAD sale del
  notch una píldora con su color y qué ha terminado, a la misma altura
  que la de música (si coinciden, salen una detrás de otra); se oculta
  sola. (Si solo hace una pausa entre subtareas, no molesta.) Se puede
  desactivar en Ajustes, igual que el de canción.
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
  oculta sola a los pocos segundos (mientras sale, la píldora pequeña
  se quita y vuelve después). Se puede desactivar en Ajustes.
- **Cover y onda junto al notch**: mientras suena algo, del notch sale una
  píldora negra total con la carátula en un extremo, el tiempo y la barra
  en el centro y la onda en el otro extremo, con el color solo abajo
  (arriba negro puro). Se oculta al abrir el panel. **Solo se muestra con
  música sonando**: al pausar o parar, la píldora se va y…
- **Clima en el notch cerrado**: …el notch pasa a mostrar el **icono del
  parte a la izquierda** (sol ámbar, nube gris según la intensidad, gotas
  azules, nieve blanca, rayo) y **la temperatura a la derecha**, con
  fundido. Los datos vienen de tu ciudad guardada, de la ubicación
  (si la concedes) o, sin más, de la **zona horaria del sistema**
  (Madrid, Londres, Nueva York…); se refresca cada15 min.

## Pestañas

| Pestaña | Qué hace |
|---|---|
| Shelf | Dropzone punteada estilo Lumio (**kept for a day**: lo de 24 h se retira solo, el original no se toca). Por archivo: miniatura, **AirDrop**, **Zip**, **JPG**, **PDF**, Ver, Path y **To agent** (lo entrega a la sesión que elijas). Las capturas entran solas. |
| Focus | **Timer** con reloj grande (presets 15/25/50/90, pausa y **Cronómetro**) + descanso de ojos al final, y **Keep awake** con su **relojito ajustable** (stepper de minutos + presets, cuenta atrás y modos ∞/Auto). Evita el reposo de **Pantalla** y/o el **Salvapantallas** a libre elección. |
| Tiempo | **Hora local + clima** (Open-Meteo, sin clave): temperatura, estado, viento, humedad, 12 h y 5 días. Con tu **ubicación** (consentida) o buscando ciudad (se recuerda). |
| Mac | Tarjeta unificada de **MEDICIONES**: anillos de **CPU en vivo** (`E·P` + pico), **memoria** (`usada/total` + presión y swap) y **batería** (logo con carga + salud, ciclos, potencia y tiempo restante —estimado si macOS no lo da—). Debajo: **qué carga el Mac** (top procesos; toca uno para ver PID/MEM/usuario/tiempo y **Terminar**lo), **AGENT SERVERS** (puertos en escucha con Open/Stop, mapeados al agente dueño) y **LIMPIEZA** con niveles — ✓ seguro (temporales y logs), ↓ se re-descarga (cachés de Puppeteer, Playwright, Serena, Codegraph…), ⚠ destructivo (base de datos de OpenCode con **VACUUM** sin perder sesiones; worktree solo si `git status` está limpio; ficheros enormes con **borrado definitivo** y doble confirmación). «Limpiar todo» jamás toca lo destructivo. Solo con todo parado. Secciones plegables. Abajo, la huella del propio NOTCH. |
| Actividad | **Heatmap GitHub de 12 semanas** con meses y leyenda Menos/Más, total gigante con racha y mejor marca, y **ranking por agente** con barras proporcionales. Todo sale del historial local. |
| Agentes | **Respuestas en un sitio**: lista en vivo — los que trabajan salen **cargando** (spinner + %CPU), y el que te **pregunta** sale expandido con la pregunta y sus respuestas (**Permitir** / escribir / **Enviar** / **Abrir**). Si el notch está cerrado, sale la píldora **"X te necesita"**: tócala y el notch se abre aquí. Anti-spam: el aviso de fin solo sale tras 45 s quieto y no se repite en el mismo request. |
| Música | Reproducción estilo Lumio: carátula con vinilo asomando, título, barra de progreso con tiempos y controles ⏮ ⏸ ⏭. **El panel se ilumina con el color de la canción** (extraído de la carátula). Music.app y Spotify. |
| Controles | Botones, interruptores, selectores y steppers 100% propios de NOTCH: siguen tu color de acento (el timer va en verde Lumio). |
| Notas | Nota rápida (command-bar) + **portapapeles local estilo Win+V**: historial solo en memoria (clic=copiar, auto-pegar opcional), popup junto al cursor con **doble-⌘-derecho** (↑↓+Enter, 1-8, Esc). Requiere Input Monitoring para el atajo. |
| ⚙ | Es el botón de la derecha en la navbar (o `⌘,`): abre el **modal de Ajustes** — color y opacidad, **idioma** (ES/EN/FR/DE), pestañas, comportamiento (hover, auto-send, avisos con duración, auto-envío de tareas, login), **música** (fuente), **portapapeles** (atajo, auto-pegar, tope), **conexiones** (Apple Calendar, ubicación, Google/Outlook vía Cuentas de Internet), **datos** (retención, tamaño, borrado) y privacidad. |
| Tareas | **Tareas personales** (sin agentes): **calendario mensual** con puntos y filtro por día, **quick-add** (título + Hoy/Mañana) para clase, secciones En curso/Pte./Hechas/Archivadas. Cada evento configura **fecha + aviso** (píldora / sistema / ambas / nada); el planificador avisa una sola vez. |

## Privacidad

- NOTCH solo lee los archivos de sesión de **tus** agentes en **tu** Mac.
- No pide Screen Recording. Solo pide Accesibilidad si activas auto-send,
  y Automatización solo cuando usas iTerm o Apple Notes.
- Conexiones: ninguna (salvo la descarga inicial). Tus datos no salen del Mac.

## Solución de problemas

- **No veo a un agente (u otro CLI de IA) en el panel**: NOTCH audita
  los procesos y escribe en su registro las marcas que ningún detector
  reclama: `grep NOTCH-UNMAPPED ~/..../notch.log` (salida estándar de la
  app). Si aparece ahí el tuyo, es un hueco de la tabla de detección. Los
  agentes solo-por-fichero (extensiones de VS Code) ahora cuentan como
  **en uso** mientras su log se esté escribiendo.

- **No detecta mi agente**: comprueba que su proceso esté corriendo y que
  tenga archivos de sesión recientes (`swift run NotchApp -- --monitor-once`
  muestra lo que ve el motor).
- **Reply no llega**: sin Accesibilidad el texto queda en el portapapeles;
  pulsa `⌘V` en la ventana del agente. Para iTerm hace falta permitir
  Automatización la primera vez.
- **Doble-tap ⌘ no abre**: necesita Accesibilidad; usa "Abrir notch" del menú.
- **Música en silencio**: solo Music.app y Spotify por ahora; otros
  reproductores muestran "Silencio".
