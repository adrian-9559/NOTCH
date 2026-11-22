#if os(macOS)
import AppKit
import CoreLocation
import EventKit
import NotchCore
import SwiftUI

// MARK: - Conexiones: calendarios del sistema + ubicación + clima
//
// Apple Calendar por EventKit (incluye lo sincronizado: iCloud y las
// cuentas de Google/Outlook que el usuario tenga en Calendario). Google
// o Microsoft directos exigirían OAuth con credenciales de desarrollador:
// se hace vía Cuentas de Internet del sistema. Clima por Open-Meteo
// (sin clave) con ubicación consentida o ciudad manual.

// MARK: - Calendarios del sistema (EventKit)

/// Un evento para la agenda del día.
struct CalEvent: Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
}

final class CalService: ObservableObject {
    static let shared = CalService()

    enum AuthState { case unknown, requesting, granted, denied }

    @Published private(set) var auth = AuthState.unknown
    private var store: EKEventStore?
    private var cache: (at: Date, days: [Date])?
    private let ttl: TimeInterval = 120

    private func ensureStore() -> EKEventStore? {
        // Sin bundle empaquetado EventKit no puede autorizar: degradar.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        if let s = store { return s }
        let s = EKEventStore()
        store = s
        return s
    }

    /// Pide acceso (solo empaquetada; en desarrollo queda denegado).
    func requestAccess() {
        guard auth == .unknown || auth == .denied else { return }
        guard let s = ensureStore() else {
            DispatchQueue.main.async { self.auth = .denied }
            return
        }
        DispatchQueue.main.async { self.auth = .requesting }
        if #available(macOS 14, *) {
            s.requestFullAccessToEvents { [weak self] granted, _ in
                DispatchQueue.main.async { self?.auth = granted ? .granted : .denied }
            }
        } else {
            s.requestAccess(to: .event) { [weak self] granted, _ in
                DispatchQueue.main.async { self?.auth = granted ? .granted : .denied }
            }
        }
    }

    func refreshStatus() {
        guard ensureStore() != nil else {
            if auth == .unknown { auth = .denied }
            return
        }
        if #available(macOS 14, *) {
            auth = EKEventStore.authorizationStatus(for: .event) == .fullAccess ? .granted : .denied
        } else {
            auth = EKEventStore.authorizationStatus(for: .event) == .authorized ? .granted : .denied
        }
    }

    /// Días con algún evento en [from, to] (con caché de 2 min).
    func eventDays(from: Date, to: Date) -> [Date] {
        guard NotchSettings.shared.useSystemCalendar, auth == .granted,
              let s = ensureStore() else { return [] }
        if let c = cache, Date().timeIntervalSince(c.at) < ttl { return c.days }
        let pred = s.predicateForEvents(withStart: from, end: to, calendars: nil)
        let days = Set(s.events(matching: pred).map { Calendar.current.startOfDay(for: $0.startDate) })
        let out = Array(days).sorted()
        cache = (Date(), out)
        return out
    }

    /// Eventos de un día concreto (para la agenda).
    func events(on day: Date) -> [CalEvent] {
        guard NotchSettings.shared.useSystemCalendar, auth == .granted,
              let s = ensureStore() else { return [] }
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        let pred = s.predicateForEvents(withStart: start, end: end, calendars: nil)
        return s.events(matching: pred)
            .sorted { $0.startDate < $1.startDate }
            .map { CalEvent(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "", start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay) }
    }
}

// MARK: - Ubicación consentida + clima (Open-Meteo, sin clave)

final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var coord: CLLocationCoordinate2D?
    @Published private(set) var denied = false
    private var manager: CLLocationManager?
    private var oneShot: ((CLLocationCoordinate2D?) -> Void)?

    func requestOnce(_ done: @escaping (CLLocationCoordinate2D?) -> Void) {
        let m = CLLocationManager()
        m.delegate = self
        manager = m
        oneShot = done
        denied = false
        m.requestWhenInUseAuthorization()
        // Si ya estaba autorizado, arranca directo.
        if m.authorizationStatus == .authorized || m.authorizationStatus == .authorizedAlways {
            m.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            denied = true
            oneShot?(nil)
            oneShot = nil
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let c = locations.last?.coordinate {
            coord = c
            oneShot?(c)
        } else {
            oneShot?(nil)
        }
        oneShot = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        denied = true
        oneShot?(nil)
        oneShot = nil
    }
}

/// Punto horario y día del parte.
struct HourPoint: Equatable { var date: Date; var temp: Double; var code: Int }
struct DayPoint: Equatable { var date: Date; var tmax: Double; var tmin: Double; var code: Int }

final class WeatherStore: ObservableObject {
    @Published var place = ""
    @Published var temp: Double?
    @Published var code: Int?
    @Published var humidity: Double?
    @Published var wind: Double?
    @Published var utcOffset: Int?
    @Published var hours: [HourPoint] = []
    @Published var days: [DayPoint] = []
    @Published var loading = false
    @Published var error = false
    @Published var nowTick = Date()

    private let loc = LocationService()
    private var timer: Timer?

    private var savedLat: Double? {
        UserDefaults.standard.object(forKey: "notchWeatherLat") as? Double
    }

    func startClock() {
        stopClock()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.nowTick = Date()
        }
    }

    func stopClock() {
        timer?.invalidate()
        timer = nil
    }

    /// Hora local del lugar observado (instante desplazado a su UTC).
    var localTime: Date {
        guard let off = utcOffset else { return nowTick }
        return nowTick.addingTimeInterval(TimeInterval(off))
    }

    /// Entrada: ciudad guardada, si no ubicación (con consentimiento).
    func loadDefault() {
        if let lat = savedLat,
           let lon = UserDefaults.standard.object(forKey: "notchWeatherLon") as? Double {
            let city = UserDefaults.standard.string(forKey: "notchWeatherCity") ?? ""
            fetch(lat: lat, lon: lon, place: city)
            return
        }
        guard NotchSettings.shared.useLocation else {
            // Sin lugar todavía: mostrar el estado "busca una ciudad".
            error = true
            return
        }
        useCurrentLocation()
    }

    func useCurrentLocation() {
        loading = true
        error = false
        loc.requestOnce { [weak self] c in
            guard let self else { return }
            guard let c else {
                DispatchQueue.main.async { self.loading = false; self.error = self.place.isEmpty && self.temp == nil }
                return
            }
            self.reverseName(lat: c.latitude, lon: c.longitude) { name in
                self.fetch(lat: c.latitude, lon: c.longitude, place: name, save: true)
            }
        }
    }

    func searchCity(_ name: String) {
        let q = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        loading = true
        error = false
        CLGeocoder().geocodeAddressString(q) { [weak self] marks, _ in
            guard let self else { return }
            guard let m = marks?.first, let c = m.location?.coordinate else {
                DispatchQueue.main.async { self.loading = false; self.error = true }
                return
            }
            let label = m.locality ?? m.name ?? q
            self.fetch(lat: c.latitude, lon: c.longitude, place: label, save: true)
        }
    }

    private func reverseName(lat: Double, lon: Double, done: @escaping (String) -> Void) {
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon)) { marks, _ in
            done(marks?.first?.locality ?? marks?.first?.name ?? "")
        }
    }

    private func fetch(lat: Double, lon: Double, place: String, save: Bool = false) {
        loading = true
        error = false
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        comps?.queryItems = [
            URLQueryItem(name: "latitude", value: "\(lat)"),
            URLQueryItem(name: "longitude", value: "\(lon)"),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "6"),
        ]
        guard let url = comps?.url else {
            loading = false; error = true
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { self?.loading = false; self?.error = true }
                return
            }
            let cur = json["current"] as? [String: Any] ?? [:]
            let hourly = json["hourly"] as? [String: Any] ?? [:]
            let daily = json["daily"] as? [String: Any] ?? [:]
            let hTimes = hourly["time"] as? [String] ?? []
            let hTemps = hourly["temperature_2m"] as? [Double] ?? []
            let hCodes = hourly["weather_code"] as? [Int] ?? []
            let dTimes = daily["time"] as? [String] ?? []
            let dMax = daily["temperature_2m_max"] as? [Double] ?? []
            let dMin = daily["temperature_2m_min"] as? [Double] ?? []
            let dCodes = daily["weather_code"] as? [Int] ?? []
            let dayFmt: DateFormatter = {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy-MM-dd"; return f
            }()
            var hours: [HourPoint] = []
            // Primeras 12 h desde ahora.
            let nowH: String = {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy-MM-dd'T'HH':00'"; return f.string(from: Date())
            }()
            let startIdx = hTimes.firstIndex(where: { $0 >= nowH }) ?? 0
            for i in startIdx..<min(startIdx + 12, hTimes.count) {
                guard i < hTemps.count, i < hCodes.count,
                      let d = Self.looseHour(hTimes[i]) else { continue }
                hours.append(HourPoint(date: d, temp: hTemps[i], code: hCodes[i]))
            }
            var days: [DayPoint] = []
            for i in 0..<min(5, dTimes.count) {
                guard i < dMax.count, i < dMin.count, i < dCodes.count,
                      let d = dayFmt.date(from: dTimes[i]) else { continue }
                days.append(DayPoint(date: d, tmax: dMax[i], tmin: dMin[i], code: dCodes[i]))
            }
            DispatchQueue.main.async {
                self.place = place
                self.temp = cur["temperature_2m"] as? Double
                self.code = cur["weather_code"] as? Int
                self.humidity = cur["relative_humidity_2m"] as? Double
                self.wind = cur["wind_speed_10m"] as? Double
                self.utcOffset = json["utc_offset_seconds"] as? Int
                self.hours = hours
                self.days = days
                self.loading = false
                self.error = self.temp == nil
                if save {
                    UserDefaults.standard.set(lat, forKey: "notchWeatherLat")
                    UserDefaults.standard.set(lon, forKey: "notchWeatherLon")
                    UserDefaults.standard.set(place, forKey: "notchWeatherCity")
                }
            }
        }.resume()
    }

    private static func looseHour(_ s: String) -> Date? {
        // "2026-11-22T14:00" → Date en la zona del parte (viene con timezone=auto).
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f.timeZone = TimeZone.current
        return f.date(from: s)
    }
}

// MARK: - Pestaña Tiempo

/// Hora local del lugar + clima (Open-Meteo, sin clave). Ubicación con
/// consentimiento o ciudad manual (se recuerda).
struct WeatherView: View {
    @StateObject private var store = WeatherStore()
    @ObservedObject private var settings = NotchSettings.shared
    @State private var query = ""

    /// Tinte del estado del tiempo (hero y contornos).
    private var tint: Color {
        guard let c = store.code else { return settings.accent }
        switch c {
        case 0, 1: return Color(hex: "F2B33D")
        case 2: return Color(hex: "E8A33D")
        case 3: return Color(hex: "8FA3BF")
        case 45, 48: return Color(hex: "9AA7B8")
        case 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82: return Color(hex: "4C8FD8")
        case 71, 73, 75, 77, 85, 86: return Color(hex: "7FC4E8")
        case 95, 96, 99: return Color(hex: "9B7BE8")
        default: return settings.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Buscador + ubicación.
            HStack(spacing: 6) {
                NotchTextField(
                    placeholder: tr("wthr.searchPh"), text: $query,
                    icon: "magnifyingglass", hint: "⏎",
                    color: settings.accent,
                    onCommit: { store.searchCity(query); query = "" }
                )
                Button { store.useCurrentLocation() } label: {
                    Image(systemName: "location.fill")
                        .font(.system(size: 12))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(NotchGhostButton(size: .small, tint: settings.accent))
                .help(tr("wthr.useLoc"))
                .disabled(!settings.useLocation)
            }
            if store.loading && store.temp == nil {
                VStack(spacing: 8) {
                    ProgressView().progressViewStyle(.circular).scaleEffect(0.7)
                    Text(tr("act.empty"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else if store.error && store.temp == nil {
                VStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.06)).frame(width: 42, height: 42)
                        Image(systemName: "cloud.slash")
                            .font(.system(size: 17))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                    Text(tr("wthr.noLoc"))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Button(tr("wthr.retry")) { store.loadDefault() }
                        .buttonStyle(NotchGhostButton(size: .mini, tint: settings.accent))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else {
                heroCard
                if !store.hours.isEmpty { hourlyCard }
                if !store.days.isEmpty { dailyCard }
            }
        }
        .padding(8)
        .onAppear {
            store.startClock()
            store.loadDefault()
        }
        .onDisappear { store.stopClock() }
    }

    // MARK: - Ahora: hora grande + estado + métricas

    private var heroCard: some View {
        NotchCard(accent: tint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        if !store.place.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(tint)
                                Text(store.place)
                                    .font(.notchMono(11))
                                    .foregroundStyle(Color.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                        }
                        Text(timeString(store.localTime))
                            .font(.notchMono(36))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                            .kerning(1)
                        if let c = store.code {
                            Text(condName(c))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.8))
                        }
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 0) {
                        if let c = store.code {
                            Image(systemName: iconName(c))
                                .font(.system(size: 34))
                                .foregroundStyle(tint)
                                .shadow(color: tint.opacity(0.5), radius: 12)
                                .padding(.bottom, 2)
                        }
                        if let t = store.temp {
                            Text("\(Int(t.rounded()))°")
                                .font(.notchMono(34))
                                .foregroundStyle(.white)
                                .monospacedDigit()
                        }
                    }
                }
                // Métricas en tres fichas.
                HStack(spacing: 6) {
                    metricTile(icon: "wind", label: tr("wthr.wind"),
                               value: store.wind.map { "\(Int($0.rounded()))" } ?? "—", unit: "km/h")
                    metricTile(icon: "drop.fill", label: tr("wthr.humidity"),
                               value: store.humidity.map { "\(Int($0.rounded()))" } ?? "—", unit: "%")
                    metricTile(icon: "arrow.up", label: tr("wthr.max"),
                               value: store.days.first.map { "\(Int($0.tmax.rounded()))" } ?? "—", unit: "°")
                }
            }
        }
    }

    private func metricTile(icon: String, label: String, value: String, unit: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.notchMono(13))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text(unit)
                    .font(.notchMono(8))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            Spacer(minLength: 0)
            Text(label)
                .font(.notchMono(9))
                .foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: - Próximas horas

    private var hourlyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("wthr.hourly"))
                .font(.notchMono(10))
                .foregroundStyle(Color.white.opacity(0.5))
                .kerning(1.2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(store.hours.enumerated()), id: \.element.date) { i, h in
                        VStack(spacing: 4) {
                            Text(i == 0 ? tr("wthr.now") : hourString(h.date))
                                .font(.notchMono(9))
                                .foregroundStyle(i == 0 ? settings.accent : Color.white.opacity(0.5))
                            Image(systemName: iconName(h.code))
                                .font(.system(size: 14))
                                .foregroundStyle(i == 0 ? tint : tint.opacity(0.85))
                            Text("\(Int(h.temp.rounded()))°")
                                .font(.notchMono(12))
                                .foregroundStyle(.white.opacity(0.92))
                                .monospacedDigit()
                        }
                        .frame(minWidth: 46)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(i == 0 ? settings.accent.opacity(0.14) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(i == 0 ? settings.accent.opacity(0.4) : Color.clear, lineWidth: 1)
                        )
                        if i < store.hours.count - 1 {
                            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1, height: 34)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.058), Color.white.opacity(0.028)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.13), Color.white.opacity(0.055)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.20), radius: 10, y: 5)
    }

    // MARK: - Próximos días (con barra de rango tipo Apple)

    private var dailyCard: some View {
        let gmin = (store.days.map(\.tmin).min() ?? 0)
        let gmax = (store.days.map(\.tmax).max() ?? 1)
        let span = max(1, gmax - gmin)
        return VStack(alignment: .leading, spacing: 6) {
            Text(tr("wthr.days"))
                .font(.notchMono(10))
                .foregroundStyle(Color.white.opacity(0.5))
                .kerning(1.2)
            ForEach(Array(store.days.enumerated()), id: \.element.date) { i, d in
                HStack(spacing: 8) {
                    Text(dayName(d.date))
                        .font(.system(size: 12, weight: i == 0 ? .semibold : .regular))
                        .foregroundStyle(Color.white.opacity(i == 0 ? 0.95 : 0.8))
                        .frame(width: 84, alignment: .leading)
                    Image(systemName: iconName(d.code))
                        .font(.system(size: 12))
                        .foregroundStyle(tint)
                        .frame(width: 18)
                    Text("\(Int(d.tmin.rounded()))°")
                        .font(.notchMono(11))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                    // Barra de rango min→max dentro del rango de la semana.
                    GeometryReader { geo in
                        let fracLow = CGFloat((d.tmin - gmin) / span)
                        let fracHigh = CGFloat((d.tmax - gmin) / span)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.09))
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [Color(hex: "4C8FD8"), Color(hex: "F2B33D")],
                                    startPoint: .leading, endPoint: .trailing
                                ))
                                .frame(width: max(6, geo.size.width * (fracHigh - fracLow)))
                                .offset(x: geo.size.width * fracLow)
                        }
                    }
                    .frame(height: 6)
                    Text("\(Int(d.tmax.rounded()))°")
                        .font(.notchMono(11))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.058), Color.white.opacity(0.028)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.13), Color.white.opacity(0.055)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.20), radius: 10, y: 5)
    }

    private func timeString(_ d: Date) -> String {
        // localTime ya lleva el desfase: se pinta en GMT tal cual.
        let f = DateFormatter(); f.locale = .current
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: d)
    }

    private func hourString(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = .current
        f.dateFormat = "HH'h'"
        return f.string(from: d)
    }

    private func dayName(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return tr("act.today") }
        if cal.isDateInTomorrow(d) { return tr("task.tomorrow") }
        let f = DateFormatter(); f.locale = .current; f.dateFormat = "EEEE"
        return f.string(from: d).capitalized
    }

    private func iconName(_ code: Int) -> String {
        switch code {
        case 0, 1: return "sun.max.fill"
        case 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    private func condName(_ code: Int) -> String {
        switch code {
        case 0, 1: return tr("wthr.clear")
        case 2: return tr("wthr.partly")
        case 3: return tr("wthr.cloudy")
        case 45, 48: return tr("wthr.fog")
        case 51, 53, 55, 56, 57: return tr("wthr.drizzle")
        case 61, 63, 65, 66, 67, 80, 81, 82: return tr("wthr.rain")
        case 71, 73, 75, 77, 85, 86: return tr("wthr.snow")
        case 95, 96, 99: return tr("wthr.storm")
        default: return tr("wthr.cloudy")
        }
    }
}
#endif
