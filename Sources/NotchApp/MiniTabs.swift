#if os(macOS)
import SwiftUI

/// Contexto compartido para construir las pestañas del notch.
/// AppDelegate lo rellena al arrancar; ExtraTabsProvider lo lee.
final class NotchContext {
    static let shared = NotchContext()
    private init() {}
    var store: SessionStore?
    let shelf = ShelfStore()
    let focusTimer = FocusTimerStore()
    let awake = AwakeStore()
    let quickNote = QuickNoteStore()
    let music = MusicStore()
    let tasks = TaskStore()
    /// Portapapeles local (solo memoria), lo arranca AppDelegate.
    let clips = ClipStore()
    /// Hover de la navbar por polling (bocadillo), lo alimenta NotchUI.
    let navHover = NavHoverStore()
}

enum MiniTabs {
    static func register() {
        ExtraTabsProvider.makeTabs = {
            guard let store = NotchContext.shared.store else { return [] }
            let ctx = NotchContext.shared
            return [
                (title: NotchTab.shelf.rawValue, view: AnyView(ShelfView(store: store, shelf: ctx.shelf))),
                (title: NotchTab.focus.rawValue, view: AnyView(HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        NotchTag(icon: "timer", text: tr("focus.timer"),
                                 color: Color(hex: "2F9E6E"))
                        TimerView(store: ctx.focusTimer)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                    Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1)
                    VStack(alignment: .leading, spacing: 8) {
                        NotchTag(icon: "sun.max.fill", text: tr("focus.awake"),
                                 color: NotchSettings.shared.accent)
                        AwakeView(store: ctx.awake, sessions: store)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                })),
                (title: NotchTab.mac.rawValue, view: AnyView(StatsView(sessions: store))),
                (title: NotchTab.tiempo.rawValue, view: AnyView(WeatherView())),
                (title: NotchTab.agenda.rawValue, view: AnyView(AgendaView())),
                (title: NotchTab.launcher.rawValue, view: AnyView(LauncherView())),
                (title: NotchTab.activity.rawValue, view: AnyView(ActivityView())),
                (title: NotchTab.agents.rawValue, view: AnyView(AgentsView(store: store))),
                (title: NotchTab.music.rawValue, view: AnyView(MusicView(store: ctx.music))),
                (title: NotchTab.notes.rawValue, view: AnyView(VStack(spacing: 0) {
                    QuickNoteView(store: ctx.quickNote)
                    Divider()
                    ClipboardView(store: ctx.clips)
                })),
                (title: NotchTab.tasks.rawValue, view: AnyView(TasksView(tasks: ctx.tasks))),
                // La ⚙ ya no es pestaña: abre el modal SettingsWindowController
                // desde el botón de la navbar.
            ]
        }
    }
}
#endif
