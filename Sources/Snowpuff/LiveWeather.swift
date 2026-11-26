import CoreLocation
import Foundation

/// Weather Outside: what falls follows the weather where you are. The location comes from Location Services, rounded
/// to about ten kilometres, and goes only to Open-Meteo (open-meteo.com), which needs no account; nothing else is sent.
final class LiveWeather: NSObject, CLLocationManagerDelegate {
    struct Now {
        let weather: Weather
        let snowfall: Snowfall
        let fog: Bool
        let temperature: Double
    }

    private(set) var now: Now?
    var changed: () -> Void = {}
    var failed: (String) -> Void = { _ in }
    private let manager = CLLocationManager()
    private var place: CLLocationCoordinate2D?
    private var timer: Timer?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.refresh() }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: failed(Self.deniedMessage)
        default: manager.requestLocation()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        now = nil
        changed()
    }

    /// A short line for the menu: "Snow, −3°".
    var summary: String? {
        guard let now else { return nil }
        let what = now.snowfall == .off ? (now.fog ? tr("Fog", "Туман") : tr("Clear", "Ясно")) : now.weather.title
        return "\(what), \(Int(now.temperature.rounded()))°"
    }

    private static let deniedMessage = tr(
        "Snowpuff can't tell where you are. Allow it in System Settings → Privacy & Security → Location Services.",
        "Snowpuff не знает, где ты. Разреши доступ в Системных настройках → Конфиденциальность и безопасность → Службы геолокации."
    )

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard timer != nil else { return }
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways: manager.requestLocation()
        case .denied, .restricted: failed(Self.deniedMessage)
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // Rounded: the weather doesn't need to know the street.
        place = CLLocationCoordinate2D(latitude: (location.coordinate.latitude * 10).rounded() / 10, longitude: (location.coordinate.longitude * 10).rounded() / 10)
        refresh()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("Snowpuff: no location: \(error)")
    }

    private func refresh() {
        guard let place else {
            manager.requestLocation()
            return
        }
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.1f", place.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.1f", place.longitude)),
            URLQueryItem(name: "current", value: "weather_code,temperature_2m"),
        ]
        guard let url = parts.url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any],
                  let code = (current["weather_code"] as? NSNumber)?.intValue
            else {
                if let error { NSLog("Snowpuff: weather failed: \(error)") }
                return
            }
            let temperature = (current["temperature_2m"] as? NSNumber)?.doubleValue ?? 0
            let now = Self.reading(code: code, temperature: temperature)
            DispatchQueue.main.async {
                guard self.timer != nil else { return }
                self.now = now
                self.changed()
            }
        }.resume()
    }

    /// WMO weather codes, as Open-Meteo gives them, to what falls and how hard.
    static func reading(code: Int, temperature: Double) -> Now {
        switch code {
        case 71, 85: Now(weather: .snow, snowfall: .light, fog: false, temperature: temperature)
        case 73, 77: Now(weather: .snow, snowfall: .steady, fog: false, temperature: temperature)
        case 75, 86: Now(weather: .snow, snowfall: .heavy, fog: false, temperature: temperature)
        case 51, 56, 61, 80: Now(weather: .rain, snowfall: .light, fog: false, temperature: temperature)
        case 53, 57, 63, 81: Now(weather: .rain, snowfall: .steady, fog: false, temperature: temperature)
        case 55, 65, 66, 67, 82, 95: Now(weather: .rain, snowfall: .heavy, fog: false, temperature: temperature)
        case 96, 99: Now(weather: .hail, snowfall: .steady, fog: false, temperature: temperature)
        case 45, 48: Now(weather: temperature < 1 ? .snow : .rain, snowfall: .off, fog: true, temperature: temperature)
        default: Now(weather: temperature < 1 ? .snow : .rain, snowfall: .off, fog: false, temperature: temperature)
        }
    }
}
