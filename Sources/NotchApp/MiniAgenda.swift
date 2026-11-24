#if os(macOS)
import AppKit
import SwiftUI

/// Pestaña Agenda: próximos eventos de Calendario (EventKit, local).
/// Muestra HOY con el evento en curso y el próximo marcados, y
/// MAÑANA en formato compacto. Botón «Unirse» cuando el evento
/// trae URL (Zoom/Meet/Teams). Se actualiza solo cada30 s.
struct AgendaView: View {
    @ObservedObject private var cal = CalService.shared
    @ObservedObject private var settings = NotchSettings.shared
    @State private var today: [CalEvent] = []
    @State private var tomorrow: [CalEvent] = []
    @State private var now = Date()
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if cal.auth != .granted {
                enableCard
            } else {
                daySection(tr("agenda.today"), events: today, live: true)
                if !tomorrow.isEmpty {
                    daySection(tr("agenda.tomorrow"), events: tomorrow, live: false)
                }
            }
        }
        .onAppear {
            cal.refreshStatus()
            reload()
        }
        .onChange(of: cal.auth) { _ in reload() }
        .onReceive(ticker) { d in
            now = d
            reload()
        }
    }

    private var enableCard: some View {
        NotchCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.system(size: 13))
                        .foregroundStyle(settings.accent)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(settings.accent.opacity(0.15)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tr("agenda.enable"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(tr("agenda.enableSub"))
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button(tr("agenda.enable")) { cal.requestAccess() }
                        .buttonStyle(NotchPrimaryButton(size: .small, color: settings.accent))
                }
            }
        }
    }

    @ViewBuilder
    private func daySection(_ title: String, events: [CalEvent], live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            NotchTag(icon: "calendar", text: title, color: settings.accent,
                     trailing: events.isEmpty ? nil : "\(events.count)")
            if events.isEmpty {
                Text(tr("agenda.empty"))
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            } else {
                ForEach(events) { e in
                    eventRow(e, live: live)
                    if e.id != events.last?.id {
                        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func eventRow(_ e: CalEvent, live: Bool) -> some View {
        let inProgress = live && e.start <= now && e.end > now
        let isNext = live && !inProgress && e.start > now
        let mins = isNext ? Int(e.start.timeIntervalSince(now) / 60) : 0
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(e.isAllDay ? tr("agenda.allDay")
                     : "\(e.start.formatted(date: .omitted, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))")
                    .font(.notchMono(10))
                    .foregroundStyle(inProgress ? settings.accent : Color.white.opacity(0.55))
                if inProgress {
                    Text(tr("agenda.now"))
                        .font(.notchMono(9))
                        .foregroundStyle(settings.accent)
                } else if isNext {
                    Text(tr("agenda.in", max(1, mins)))
                        .font(.notchMono(9))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
            .frame(width: 110, alignment: .leading)

            Text(e.title)
                .font(.system(size: 12, weight: inProgress || isNext ? .semibold : .regular))
                .foregroundStyle(Color.white.opacity(inProgress || isNext ? 0.95 : 0.7))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            if let url = e.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                Button(tr("agenda.join")) { NSWorkspace.shared.open(url) }
                    .buttonStyle(NotchGhostButton(size: .mini, tint: settings.accent))
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, inProgress ? 6 : 0)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(inProgress ? settings.accent.opacity(0.12) : Color.clear)
        )
    }

    private func reload() {
        guard cal.auth == .granted else {
            today = []
            tomorrow = []
            return
        }
        today = cal.agendaEvents(on: Date())
        if let t = Calendar.current.date(byAdding: .day, value: 1, to: Date()) {
            tomorrow = cal.agendaEvents(on: t)
        }
    }
}
#endif
