//! Weather Outside: what falls follows the weather where you are. The place comes from Windows' location service,
//! rounded to about ten kilometres, and goes only to Open-Meteo (open-meteo.com), which needs no account.

use std::thread;

use windows::Devices::Geolocation::{GeolocationAccessStatus, Geolocator};
use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::UI::WindowsAndMessaging::{PostMessageW, WM_APP};
use windows_future::{AsyncStatus, IAsyncOperation};

use crate::log;

/// Posted back with a boxed `Result<Now, String>`.
pub const WM_WEATHER: u32 = WM_APP + 5;

/// How hard it falls outside.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Snowfall {
    Off,
    Light,
    Steady,
    Heavy,
}

impl Snowfall {
    /// The intensity slider's value for it, 0 to 1.
    pub fn intensity(self) -> f32 {
        match self {
            Snowfall::Off => 0.0,
            Snowfall::Light => 0.25,
            Snowfall::Steady => 0.5,
            Snowfall::Heavy => 0.85,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Now {
    /// 0 snow, 3 rain, 4 hail.
    pub weather: u8,
    pub snowfall: Snowfall,
    pub fog: bool,
    pub temperature: f32,
}

impl Now {
    /// A short line for the menu: "Snow, −3°".
    pub fn summary(&self, russian: bool) -> String {
        let what = match (self.snowfall, self.fog, self.weather) {
            (Snowfall::Off, true, _) => {
                if russian {
                    "Туман"
                } else {
                    "Fog"
                }
            }
            (Snowfall::Off, false, _) => {
                if russian {
                    "Ясно"
                } else {
                    "Clear"
                }
            }
            (_, _, 3) => {
                if russian {
                    "Дождь"
                } else {
                    "Rain"
                }
            }
            (_, _, 4) => {
                if russian {
                    "Град"
                } else {
                    "Hail"
                }
            }
            _ => {
                if russian {
                    "Снег"
                } else {
                    "Snow"
                }
            }
        };
        format!("{what}, {}°", self.temperature.round() as i32)
    }
}

/// Asks where we are and what the weather is there, on another thread; the answer comes back as `WM_WEATHER`.
pub fn look_outside(window: HWND) {
    let target = window.0 as isize;
    thread::spawn(move || {
        let result = Box::new(read());
        if let Err(error) = result.as_ref() {
            log!("weather: {error}");
        }
        unsafe {
            let _ = PostMessageW(Some(HWND(target as _)), WM_WEATHER, WPARAM(0), LPARAM(Box::into_raw(result) as isize));
        }
    });
}

fn read() -> Result<Now, String> {
    let denied = || {
        if snowpuff_core::text::code() == "ru" {
            "Snowpuff не знает, где ты. Разреши доступ к расположению: Параметры → Конфиденциальность и защита → Расположение.".to_string()
        } else {
            "Snowpuff can't tell where you are. Allow location in Settings → Privacy & security → Location.".to_string()
        }
    };
    let access = Geolocator::RequestAccessAsync().and_then(wait).map_err(|_| denied())?;
    if access != GeolocationAccessStatus::Allowed {
        return Err(denied());
    }
    let locator = Geolocator::new().map_err(|e| e.message())?;
    let place = locator
        .GetGeopositionAsync()
        .and_then(wait)
        .and_then(|position| position.Coordinate())
        .and_then(|coordinate| coordinate.Point())
        .and_then(|point| point.Position())
        .map_err(|_| denied())?;
    // Rounded: the weather doesn't need to know the street.
    let (latitude, longitude) = ((place.Latitude * 10.0).round() / 10.0, (place.Longitude * 10.0).round() / 10.0);
    let url = format!("https://api.open-meteo.com/v1/forecast?latitude={latitude:.1}&longitude={longitude:.1}&current=weather_code,temperature_2m");
    let body = String::from_utf8_lossy(&crate::update::get(&url)?).into_owned();
    let current = &body[body.find("\"current\":{").ok_or("no current weather")?..];
    let number = |key: &str| -> Option<f32> {
        let rest = &current[current.find(&format!("\"{key}\":"))? + key.len() + 3..];
        let end = rest.find([',', '}'])?;
        rest[..end].trim().parse().ok()
    };
    let code = number("weather_code").ok_or("no weather code")? as i32;
    let temperature = number("temperature_2m").unwrap_or(0.0);
    Ok(reading(code, temperature))
}

/// Waits for a Windows Runtime operation on this thread, which has nothing else to do meanwhile.
fn wait<T: windows::core::RuntimeType + 'static>(operation: IAsyncOperation<T>) -> windows::core::Result<T> {
    let started = std::time::Instant::now();
    loop {
        match operation.Status()? {
            AsyncStatus::Completed => return operation.GetResults(),
            AsyncStatus::Started if started.elapsed().as_secs() < 30 => thread::sleep(std::time::Duration::from_millis(50)),
            _ => return Err(windows::core::Error::empty()),
        }
    }
}

/// WMO weather codes, as Open-Meteo gives them, to what falls and how hard.
pub fn reading(code: i32, temperature: f32) -> Now {
    let now = |weather: u8, snowfall: Snowfall, fog: bool| Now { weather, snowfall, fog, temperature };
    let cold = if temperature < 1.0 { 0 } else { 3 };
    match code {
        71 | 85 => now(0, Snowfall::Light, false),
        73 | 77 => now(0, Snowfall::Steady, false),
        75 | 86 => now(0, Snowfall::Heavy, false),
        51 | 56 | 61 | 80 => now(3, Snowfall::Light, false),
        53 | 57 | 63 | 81 => now(3, Snowfall::Steady, false),
        55 | 65 | 66 | 67 | 82 | 95 => now(3, Snowfall::Heavy, false),
        96 | 99 => now(4, Snowfall::Steady, false),
        45 | 48 => now(cold, Snowfall::Off, true),
        _ => now(cold, Snowfall::Off, false),
    }
}
