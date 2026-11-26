//! Snowpuff's own settings over Snowhush's: icicles, the window's glow, breath, calls, sound, the extras, updates.
//! Kept under the same registry key as the rest, by the names Snowpuff 1.3 gave them.

use std::sync::Mutex;

use windows::core::{HSTRING, PCWSTR};

use crate::prefs;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Extra {
    /// Icicles along the bottom edges of windows with snow on them.
    pub icicles: bool,
    /// The foreground window glows warm onto the snow around it.
    pub warm_glow: bool,
    /// Blowing into the microphone blows the snow away.
    pub puff: bool,
    /// The snow and its sound step aside while another app uses the camera or microphone.
    pub quiet_on_calls: bool,
    /// The winter sound: 0 off, 1 wind, 2 fireplace, 3 both.
    pub ambience: u32,
    /// Its volume, in percent.
    pub volume: u32,
    pub sound_effects: bool,
    /// New versions from GitHub install themselves.
    pub auto_update: bool,
    /// Ctrl+Alt+letter shortcuts work anywhere.
    pub hotkeys: bool,
    /// A swirl of snow behind a fast cursor.
    pub blizzard: bool,
    pub fog: bool,
    pub stars: bool,
    pub garland: bool,
    pub frost: bool,
    /// The cat in the drift and the bullfinch on the windows.
    pub creatures: bool,
    /// Typing "snow" brings a flurry.
    pub words: bool,
    /// It snows, rains or hails as it does outside.
    pub live_weather: bool,
    /// Hail beats down instead of snow.
    pub hail: bool,
    /// The version whose news was last shown, as 10400 for 1.4.0.
    pub seen_version: u32,
}

const NAMES: [&str; 19] = [
    "icicles",
    "warmGlow",
    "puff",
    "quietOnCalls",
    "ambience",
    "ambienceVolume",
    "soundEffects",
    "autoUpdate",
    "hotkeys",
    "blizzard",
    "fog",
    "stars",
    "garland",
    "frost",
    "creatures",
    "words",
    "liveWeather",
    "hail",
    "seenVersion",
];

impl Extra {
    fn load() -> Extra {
        let read = |name: &str| prefs::read(PCWSTR(HSTRING::from(name).as_ptr()));
        let on = |name: &str| read(name).is_none_or(|v| v != 0);
        let off = |name: &str| read(name).is_some_and(|v| v != 0);
        Extra {
            icicles: on("icicles"),
            warm_glow: on("warmGlow"),
            puff: off("puff"),
            quiet_on_calls: on("quietOnCalls"),
            ambience: read("ambience").unwrap_or(0).min(3),
            volume: read("ambienceVolume").unwrap_or(50).clamp(5, 100),
            sound_effects: on("soundEffects"),
            auto_update: on("autoUpdate"),
            hotkeys: on("hotkeys"),
            blizzard: on("blizzard"),
            fog: off("fog"),
            stars: on("stars"),
            garland: off("garland"),
            frost: on("frost"),
            creatures: on("creatures"),
            words: off("words"),
            live_weather: off("liveWeather"),
            hail: off("hail"),
            seen_version: read("seenVersion").unwrap_or(0),
        }
    }

    fn values(&self) -> [u32; 19] {
        [
            self.icicles as u32,
            self.warm_glow as u32,
            self.puff as u32,
            self.quiet_on_calls as u32,
            self.ambience,
            self.volume,
            self.sound_effects as u32,
            self.auto_update as u32,
            self.hotkeys as u32,
            self.blizzard as u32,
            self.fog as u32,
            self.stars as u32,
            self.garland as u32,
            self.frost as u32,
            self.creatures as u32,
            self.words as u32,
            self.live_weather as u32,
            self.hail as u32,
            self.seen_version,
        ]
    }

    fn save(&self) {
        for (name, value) in NAMES.iter().zip(self.values()) {
            prefs::write(PCWSTR(HSTRING::from(*name).as_ptr()), value);
        }
    }
}

static EXTRA: Mutex<Option<Extra>> = Mutex::new(None);

/// Snowpuff's settings as they are now.
pub fn get() -> Extra {
    let mut extra = EXTRA.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    *extra.get_or_insert_with(Extra::load)
}

/// Changes Snowpuff's settings and saves them, returning them as they are after.
pub fn change(change: impl FnOnce(&mut Extra)) -> Extra {
    let mut extra = EXTRA.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let extra = extra.get_or_insert_with(Extra::load);
    change(extra);
    extra.save();
    *extra
}

pub fn auto_update() -> bool {
    get().auto_update
}
