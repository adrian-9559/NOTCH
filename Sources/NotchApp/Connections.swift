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
    /// URL del evento (Zoom/Meet/Teams) si la trae.
    var url: URL? = nil
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

    /// Eventos de un día concreto (para las puntos de Tareas):
    /// respeta el interruptor «Eventos en el calendario».
    func events(on day: Date) -> [CalEvent] {
        guard NotchSettings.shared.useSystemCalendar else { return [] }
        return fetchEvents(on: day)
    }

    /// Eventos SIN el interruptor de Tareas: lo usa la pestaña Agenda
    /// (solo hace falta el permiso de Calendario).
    func agendaEvents(on day: Date) -> [CalEvent] {
        fetchEvents(on: day)
    }

    private func fetchEvents(on day: Date) -> [CalEvent] {
        guard auth == .granted,
              let s = ensureStore() else { return [] }
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        let pred = s.predicateForEvents(withStart: start, end: end, calendars: nil)
        return s.events(matching: pred)
            .sorted { $0.startDate < $1.startDate }
            .map { CalEvent(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "", start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay, url: $0.url) }
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

/// Lugar predeterminado guardado por el usuario (máx.5).
struct WeatherPlace: Codable, Identifiable, Equatable {
    var id: String { "\(n)|\(la)|\(lo)" }
    var n: String
    var la: Double
    var lo: Double
}

final class WeatherStore: ObservableObject {
    /// Instancia única: la pestaña Tiempo y el notch comparten datos
    /// (entrar en la pestaña ya no vuelve a cargar desde cero).
    static let shared = WeatherStore()

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
    /// Lugares predeterminados del usuario (chips bajo el buscador).
    @Published var places: [WeatherPlace] = []

    private let loc = LocationService()
    private var timer: Timer?
    private var refreshTimer: Timer?
    private static let placesKey = "notchWeatherPlaces"

    private init() {
        startClock()
        // Refresco silencioso cada15 min. Solo con ciudad guardada:
        // nunca pide permisos por sorpresa al arrancar (el consentimiento
        // de ubicación se pide al entrar en la pestaña Tiempo).
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            self?.silentRefresh()
        }
    }

    /// Recarga el parte sin tocar permisos: ciudad guardada y, si no,
    /// respaldo por zona horaria (así el notch nunca queda sin datos).
    func silentRefresh() {
        if let lat = savedLat,
           let lon = UserDefaults.standard.object(forKey: "notchWeatherLon") as? Double {
            let city = UserDefaults.standard.string(forKey: "notchWeatherCity") ?? ""
            fetch(lat: lat, lon: lon, place: city)
            return
        }
        _ = tzFallbackFetch()
    }

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
            // Sin ubicación activada: respaldo por zona horaria.
            if !tzFallbackFetch() { error = true }
            return
        }
        // Sin bundle (binario de desarrollo) la ubicación no puede
        // pedirse: se usa el respaldo por zona horaria.
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            if !tzFallbackFetch() { error = true }
            return
        }
        // Automático: la primera vez macOS pide el consentimiento de
        // ubicación; si se deniega, respaldo por zona horaria.
        useCurrentLocation()
    }

    /// Respaldo por zona horaria: ciudades por IANA para que el notch
    /// tenga clima aunque no haya ciudad guardada ni ubicación
    /// (el binario de desarrollo no puede pedir permisos de CLLocation).
    /// No se guarda: si luego hay ciudad o ubicación, mandan ellas.
    func tzFallbackFetch() -> Bool {
        let id = TimeZone.current.identifier
        fputs("NOTCH-DBG tz id=\(id)\n", stderr)
        guard let hit = Self.tzCities[id] else { return false }
        fputs("NOTCH-DBG tz hit=\(hit.city)\n", stderr)
        fetch(lat: hit.lat, lon: hit.lon, place: hit.city)
        return true
    }

    private static let tzCities: [String: (city: String, lat: Double, lon: Double)] = [
        "Europe/Madrid": ("Madrid", 40.4168, -3.7038),
        "Atlantic/Canary": ("Las Palmas", 28.1235, -15.4363),
        "Europe/London": ("Londres", 51.5074, -0.1278),
        "Europe/Paris": ("París", 48.8566, 2.3522),
        "Europe/Berlin": ("Berlín", 52.52, 13.405),
        "Europe/Rome": ("Roma", 41.9028, 12.4964),
        "Europe/Lisbon": ("Lisboa", 38.7223, -9.1393),
        "Europe/Amsterdam": ("Ámsterdam", 52.3676, 4.9041),
        "Europe/Moscow": ("Moscú", 55.7558, 37.6173),
        "America/New_York": ("Nueva York", 40.7128, -74.006),
        "America/Chicago": ("Chicago", 41.8781, -87.6298),
        "America/Denver": ("Denver", 39.7392, -104.9903),
        "America/Los_Angeles": ("Los Ángeles", 34.0522, -118.2437),
        "America/Mexico_City": ("Ciudad de México", 19.4326, -99.1332),
        "America/Bogota": ("Bogotá", 4.711, -74.0721),
        "America/Lima": ("Lima", -12.0464, -77.0428),
        "America/Santiago": ("Santiago", -33.4489, -70.6693),
        "America/Argentina/Buenos_Aires": ("Buenos Aires", -34.6037, -58.3816),
        "America/Sao_Paulo": ("São Paulo", -23.5505, -46.6333),
        "America/Toronto": ("Toronto", 43.6532, -79.3832),
        "Asia/Tokyo": ("Tokio", 35.6762, 139.6503),
        "Asia/Seoul": ("Seúl", 37.5665, 126.978),
        "Asia/Shanghai": ("Shanghái", 31.2304, 121.4737),
        "Asia/Hong_Kong": ("Hong Kong", 22.3193, 114.1694),
        "Asia/Singapore": ("Singapur", 1.3521, 103.8198),
        "Asia/Kolkata": ("Mumbai", 19.076, 72.8777),
        "Asia/Dubai": ("Dubái", 25.2048, 55.2708),
        "Australia/Sydney": ("Sídney", -33.8688, 151.2093),
        "Pacific/Auckland": ("Auckland", -36.8485, 174.7633),
        "Africa/Cairo": ("El Cairo", 30.0444, 31.2357),
        "Africa/Johannesburg": ("Johannesburgo", -26.2041, 28.0473),
    ]

    // MARK: - Lugares predeterminados

    func loadPlaces() {
        guard let data = UserDefaults.standard.data(forKey: Self.placesKey),
              let list = try? JSONDecoder().decode([WeatherPlace].self, from: data)
        else { return }
        places = list
    }

    private func savePlaces() {
        if let data = try? JSONEncoder().encode(places) {
            UserDefaults.standard.set(data, forKey: Self.placesKey)
        }
    }

    /// Guarda un lugar al buscar ciudad (máx.5, sin duplicados).
    func rememberPlace(name: String, lat: Double, lon: Double) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        places.removeAll { $0.n.caseInsensitiveCompare(clean) == .orderedSame }
        places.insert(WeatherPlace(n: clean, la: lat, lo: lon), at: 0)
        if places.count > 5 { places = Array(places.prefix(5)) }
        savePlaces()
    }

    func removePlace(_ p: WeatherPlace) {
        places.removeAll { $0.id == p.id }
        savePlaces()
    }

    func usePlace(_ p: WeatherPlace) {
        fetch(lat: p.la, lon: p.lo, place: p.n)
    }

    func useCurrentLocation() {
        loading = true
        error = false
        loc.requestOnce { [weak self] c in
            guard let self else { return }
            guard let c else {
                DispatchQueue.main.async {
                    self.loading = false
                    // Sin ubicación (denegada): respaldo por zona.
                    if !self.tzFallbackFetch() {
                        self.error = self.place.isEmpty && self.temp == nil
                    }
                }
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
                fputs("NOTCH-DBG error-set=denied-loc\n", stderr)
                DispatchQueue.main.async { self.loading = false; self.error = true }
                return
            }
            let label = m.locality ?? m.name ?? q
            DispatchQueue.main.async {
                self.rememberPlace(name: label, lat: c.latitude, lon: c.longitude)
            }
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
                fputs("NOTCH-DBG error-set=network\n", stderr)
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
            fputs("NOTCH-DBG weather resp temp=\(String(describing: cur["temperature_2m"])) err=\(String(describing: json["error"]))\n", stderr)
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

// MARK: - Icono del parte a color

/// Icono compuesto y multicolor: nube blanca/gris según la intensidad,
/// gotas azules, nieve blanca, rayo ámbar, sol amarillo… Se usa en la
/// pestaña Tiempo y en el notch cerrado (a diferencia del SF Symbol
/// plano, cada elemento lleva su color).
struct WeatherGlyph: View {
    var code: Int
    var size: CGFloat = 16

    private var hasCloud: Bool { ![0, 1].contains(code) }

    /// La nube se oscurece con la intensidad de la precipitación.
    private var cloud: Color {
        switch code {
        case 3: return Color(hex: "9AA7B8")
        case 45, 48: return Color(hex: "8B97A8")
        case 51, 53, 55, 56, 57, 80, 81, 82: return Color(hex: "B9C2CE")
        case 61, 63, 66, 67: return Color(hex: "8593A6")
        case 65, 71, 73, 75, 77, 85, 86: return Color(hex: "6E7C90")
        case 95, 96, 99: return Color(hex: "59637A")
        default: return Color(hex: "D7DEE8")
        }
    }

    var body: some View {
        ZStack {
            // Sol (despejado y parcial): amarillo detrás de la nube.
            if code == 0 || code == 1 || code == 2 {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: size * (code == 2 ? 0.60 : 0.95), weight: .medium))
                    .foregroundStyle(Color(hex: "F2B33D"))
                    .offset(x: code == 2 ? -size * 0.26 : 0,
                            y: code == 2 ? -size * 0.26 : 0)
                    .shadow(color: Color(hex: "F2B33D").opacity(0.55), radius: size * 0.22)
            }
            if hasCloud {
                Image(systemName: "cloud.fill")
                    .font(.system(size: size * 0.78, weight: .medium))
                    .foregroundStyle(cloud)
                    .offset(y: code == 2 ? size * 0.12 : (precipVisible ? size * 0.02 : 0))
                    .shadow(color: .black.opacity(0.25), radius: size * 0.14)
            }
            precip
        }
        .frame(width: size * 1.4, height: size * 1.4)
    }

    private var precipVisible: Bool {
        switch code {
        case 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 71, 73, 75, 77, 80, 81, 82, 85, 86, 95, 96, 99:
            return true
        default: return false
        }
    }

    @ViewBuilder
    private var precip: some View {
        switch code {
        case 51, 53, 55:
            drops(count: 2, color: Color(hex: "4C8FD8"))
        case 56, 57, 66, 67:
            drops(count: 2, color: Color(hex: "7FC4E8"))
        case 61, 63, 65, 80, 81, 82:
            drops(count: 3, color: Color(hex: "4C8FD8"))
        case 71, 73, 75, 77, 85, 86:
            Image(systemName: "snowflake")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(.white)
                .offset(y: size * 0.42)
                .shadow(color: .white.opacity(0.45), radius: size * 0.12)
        case 95, 96, 99:
            Image(systemName: "bolt.fill")
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(Color(hex: "F2B33D"))
                .offset(y: size * 0.44)
        case 45, 48:
            VStack(spacing: size * 0.09) {
                Capsule().fill(cloud).frame(width: size * 0.58, height: size * 0.09)
                Capsule().fill(cloud.opacity(0.75)).frame(width: size * 0.42, height: size * 0.09)
            }
            .offset(y: size * 0.40)
        default:
            EmptyView()
        }
    }

    private func drops(count: Int, color: Color) -> some View {
        HStack(spacing: size * 0.13) {
            ForEach(0..<count, id: \.self) { i in
                Image(systemName: "drop.fill")
                    .font(.system(size: size * 0.23, weight: .bold))
                    .foregroundStyle(color)
                    .offset(y: i % 2 == 1 ? size * 0.10 : 0)
            }
        }
        .offset(y: size * 0.44)
    }
}

// MARK: - Pestaña Tiempo

/// Hora local del lugar + clima (Open-Meteo, sin clave). Ubicación con
/// consentimiento o ciudad manual (se recuerda).
struct WeatherView: View {
    @ObservedObject private var store = WeatherStore.shared
    @ObservedObject private var settings = NotchSettings.shared
    @State private var query = ""

    /// Tinte del estado del tiempo (hero y contornos).
    private var tint: Color {
        store.code.map { weatherTint($0, fallback: settings.accent) } ?? settings.accent
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
            // Lugares predeterminados: toca para cambiar, ✕ para quitar.
            if !store.places.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.places) { p in placeChip(p) }
                    }
                }
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
            store.loadPlaces()
            store.loadDefault()
        }

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
                            WeatherGlyph(code: c, size: 34)
                                .shadow(color: tint.opacity(0.45), radius: 10)
                                .padding(.bottom, 2)
                        }
                        if let t = store.temp {
                            Text(fmtTemp(t))
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
                               value: store.days.first.map { fmtTemp($0.tmax, degree: false) } ?? "—", unit: "°")
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
            NotchTag(icon: "clock", text: tr("wthr.hourly"), color: tint)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(store.hours.enumerated()), id: \.element.date) { i, h in
                        VStack(spacing: 4) {
                            Text(i == 0 ? tr("wthr.now") : hourString(h.date))
                                .font(.notchMono(9))
                                .foregroundStyle(i == 0 ? settings.accent : Color.white.opacity(0.5))
                            WeatherGlyph(code: h.code, size: 17)
                            Text(fmtTemp(h.temp))
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
            NotchTag(icon: "calendar", text: tr("wthr.days"), color: tint)
            ForEach(Array(store.days.enumerated()), id: \.element.date) { i, d in
                HStack(spacing: 8) {
                    Text(dayName(d.date))
                        .font(.system(size: 12, weight: i == 0 ? .semibold : .regular))
                        .foregroundStyle(Color.white.opacity(i == 0 ? 0.95 : 0.8))
                        .frame(width: 84, alignment: .leading)
                    WeatherGlyph(code: d.code, size: 15)
                        .frame(width: 18)
                    Text(fmtTemp(d.tmin))
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
                    Text(fmtTemp(d.tmax))
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

    /// Chip de lugar predeterminado: navega (izq) y quita (der).
    private func placeChip(_ p: WeatherPlace) -> some View {
        let current = store.place == p.n
        return HStack(spacing: 0) {
            Button { store.usePlace(p) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(current ? settings.accent : Color.white.opacity(0.5))
                    Text(p.n)
                        .font(.notchMono(10))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                .padding(.leading, 9).padding(.trailing, 3).padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            Button { store.removePlace(p) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .padding(.horizontal, 6).padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .help(tr("wthr.removePlace"))
        }
        .background(
            Capsule().fill(current ? settings.accent.opacity(0.16) : Color.white.opacity(0.05))
        )
        .overlay(
            Capsule().stroke(current ? settings.accent.opacity(0.45) : Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private func timeString(_ d: Date) -> String {
        // localTime ya lleva el desfase: se pinta en GMT tal cual.
        NotchDateFmt.hourMinuteGMT.string(from: d)
    }

    private func hourString(_ d: Date) -> String {
        NotchDateFmt.hourH.string(from: d)
    }

    private func dayName(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return tr("act.today") }
        if cal.isDateInTomorrow(d) { return tr("task.tomorrow") }
        return NotchDateFmt.weekdayFull.string(from: d).capitalized
    }

}

/// Tinte del estado del tiempo (hero, contornos y notch cerrado).
func weatherTint(_ code: Int, fallback: Color) -> Color {
    switch code {
    case 0, 1: return Color(hex: "F2B33D")
    case 2: return Color(hex: "E8A33D")
    case 3: return Color(hex: "8FA3BF")
    case 45, 48: return Color(hex: "9AA7B8")
    case 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82: return Color(hex: "4C8FD8")
    case 71, 73, 75, 77, 85, 86: return Color(hex: "7FC4E8")
    case 95, 96, 99: return Color(hex: "9B7BE8")
    default: return fallback
    }
}

extension WeatherView {
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
