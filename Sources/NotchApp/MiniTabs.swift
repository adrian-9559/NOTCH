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
}

enum MiniTabs {
    static func register() {
        ExtraTabsProvider.makeTabs = {
            guard let store = NotchContext.shared.store else { return [] }
            let ctx = NotchContext.shared
            return [
                (title: "Office", view: AnyView(PixelOfficeView(store: store))),
                (title: "Shelf", view: AnyView(ShelfView(store: store, shelf: ctx.shelf))),
                (title: "Focus", view: AnyView(VStack(spacing: 0) {
                    TimerView(store: ctx.focusTimer)
                    Divider()
                    AwakeView(store: ctx.awake, sessions: store)
                })),
                (title: "Mac", view: AnyView(VStack(spacing: 0) {
                    StatsView(sessions: store)
                    Divider()
                    MusicView(store: ctx.music)
                })),
                (title: "Notas", view: AnyView(VStack(spacing: 0) {
                    QuickNoteView(store: ctx.quickNote)
                    Divider()
                    HistoryView()
                })),
                (title: "⚙", view: AnyView(SettingsView())),
            ]
        }
    }
}
#endif
