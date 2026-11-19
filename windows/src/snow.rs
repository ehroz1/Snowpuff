use std::sync::mpsc::Receiver;

use windows::Win32::Foundation::{HANDLE, HWND, LPARAM, WPARAM};
use windows::Win32::System::Com::{COINIT_APARTMENTTHREADED, CoInitializeEx};
use windows::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
use windows::Win32::System::Threading::{
    CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, CreateWaitableTimerExW, CreateWaitableTimerW, INFINITE, SetWaitableTimer, TIMER_ALL_ACCESS,
    WaitForMultipleObjects,
};
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, MB_ICONERROR, MB_OK, MSG, MWMO_INPUTAVAILABLE, MessageBoxW, MsgWaitForMultipleObjectsEx, PM_REMOVE, PeekMessageW, PostMessageW,
    QS_ALLINPUT, TranslateMessage, WM_CLOSE,
};
use windows::core::{HSTRING, PCWSTR, Result, w};

use snowpuff_core::geometry::V2;
use snowpuff_core::extras::{Settings as ExtrasSettings, Weather};
use snowpuff_core::rain;
use snowpuff_core::sfx::Cue;
use snowpuff_core::simulation::{ScatterPiece, SnowSimulation, Snowfall};

use crate::desktop::{self, DesktopLayer};
use crate::light::{Sky, Wallpapers};
use crate::log;
use crate::prefs::Settings;
use crate::render::Gpu;
use crate::screen::{BACKDROP_CHANGED, Clock, DISPLAYS_CHANGED, Monitor, PowerBudget, Screen, dip_size, listen, monitors, walls, watch_taskbar};
use crate::tracker::Tracker;

/// A piece of the welcome window crumbling into snow, in physical screen pixels.
pub struct Piece {
    pub x: f32,
    pub y: f32,
    pub velocity: V2,
    pub color: [f32; 3],
}

pub enum Command {
    Snowfall(Snowfall),
    Accumulate(bool),
    Melt(bool),
    SnowOnWindows(bool),
    BehindWindows(bool),
    BehindTaskbar(bool),
    /// Explorer started again, taking the desktop's wallpaper layer with it.
    ShellRestarted,
    ShowInScreenshots(bool),
    /// Off while the screen is locked, asleep or the session is away.
    Active(bool),
    Scatter(Vec<Piece>),
    /// Starts the snowfall held back for the welcome window.
    ReleaseSnowfall,
    /// Blows all the snow away; when calm, for less motion, melts it where it lies instead.
    ClearSnow(bool),
    Icicles(bool),
    WarmGlow(bool),
    /// A breath into the microphone, and how hard.
    Breathe(f32),
    /// A call is on: the snow hides until it ends.
    Hushed(bool),
    /// The snow stays over full-screen apps too.
    OverFullScreen(bool),
    /// Every frame at the display's full rate.
    MaxPerformance(bool),
    /// A new mode: 0 snow, 1 leaves, 2 cherry petals, 3 rain, 4 hail. What lies is blown away first, or melts when calm.
    SetWeather {
        weather: u8,
        calm: bool,
    },
    /// Settings that only change how things look or which extras show, taken whole.
    Refresh(Settings),
    /// Fireworks for this many seconds.
    Fireworks(f32),
    /// Big soft flakes for a few seconds, as when "snow" is typed.
    Flurry,
    Quit,
}

/// Raw handles cross to the snow thread as numbers: the thread only waits on the event and posts to the window.
/// Sounds for the main thread to play, posted with a boxed `Vec<Cue>`.
pub const WM_CUES: u32 = windows::Win32::UI::WindowsAndMessaging::WM_APP + 4;

pub struct Links {
    pub wake: isize,
    pub controller: isize,
}

pub fn run(commands: Receiver<Command>, links: Links, settings: Settings) {
    if let Err(error) = run_loop(&commands, &links, settings) {
        log!("stopped: {error}");
        let text = HSTRING::from(format!("Snowpuff couldn't start drawing snow.\n\n{error}"));
        unsafe {
            MessageBoxW(None, &text, w!("Snowpuff"), MB_OK | MB_ICONERROR);
            let _ = PostMessageW(Some(HWND(links.controller as _)), WM_CLOSE, WPARAM(0), LPARAM(0));
        }
    }
}

fn run_loop(commands: &Receiver<Command>, links: &Links, mut settings: Settings) -> Result<()> {
    unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED).ok()? };
    let mut gpu = Gpu::new()?;
    log!("adapter: {}", gpu.adapter);
    let _listener = listen()?;
    let mut layer = settings.behind_windows.then(find_layer).flatten();
    let mut screens = sync_screens(&gpu, &settings, Vec::new(), layer, false);
    let timer = unsafe {
        CreateWaitableTimerExW(None, PCWSTR::null(), CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS.0)
            .or_else(|_| CreateWaitableTimerW(None, false, PCWSTR::null()))?
    };
    let wake = HANDLE(links.wake as _);
    let mut clock = Clock::new();
    let started = Clock::now();
    let mut active = true;
    let mut budget = PowerBudget::Full;
    let mut sky = Sky::now();
    let mut hushed = false;
    let wallpapers = Wallpapers::new().inspect_err(|error| log!("wallpapers unavailable: {error}")).ok();
    let mut chores_at = 0;
    let mut light_at = 0;
    let mut displays_changed_at = None;
    let mut desktop_logged = String::new();
    let mut stats = Stats::new(started);
    let mut tracker = Tracker::new();
    watch_taskbar(links.wake);

    loop {
        screens.iter().filter(|screen| screen.under_taskbar()).for_each(Screen::raise);
        while let Ok(command) = commands.try_recv() {
            match command {
                Command::Quit => return Ok(()),
                Command::Snowfall(snowfall) => {
                    settings.snowfall = snowfall;
                    screens.iter_mut().for_each(|screen| apply(screen, &settings, None));
                }
                Command::Accumulate(on) => {
                    settings.accumulate = on;
                    screens.iter_mut().for_each(|screen| screen.simulation.accumulates = on);
                }
                Command::Melt(on) => {
                    settings.melt = on;
                    screens.iter_mut().for_each(|screen| screen.simulation.thaws = on);
                }
                Command::SnowOnWindows(on) => {
                    settings.snow_on_windows = on;
                    if !on {
                        screens.iter_mut().for_each(Screen::drop_window_snow);
                    }
                }
                Command::BehindWindows(on) => {
                    settings.behind_windows = on;
                    layer = on.then(find_layer).flatten();
                    screens = sync_screens(&gpu, &settings, screens, layer, true);
                }
                Command::BehindTaskbar(on) => {
                    settings.behind_taskbar = on;
                    screens = sync_screens(&gpu, &settings, screens, layer, true);
                }
                Command::ShellRestarted => {
                    if settings.behind_windows {
                        layer = find_layer();
                        screens = sync_screens(&gpu, &settings, screens, layer, true);
                    }
                }
                Command::ShowInScreenshots(on) => {
                    settings.show_in_screenshots = on;
                    screens.iter().for_each(|screen| screen.show_in_screenshots(on));
                }
                Command::Scatter(pieces) => {
                    let Some(first) = pieces.first() else { continue };
                    let index = screens.iter().position(|screen| screen.contains(first.x, first.y)).unwrap_or(0);
                    let Some(screen) = screens.get_mut(index) else { continue };
                    let local: Vec<ScatterPiece> = pieces
                        .iter()
                        .map(|piece| ScatterPiece { position: screen.local(piece.x, piece.y), velocity: piece.velocity, color: piece.color })
                        .collect();
                    screen.simulation.scatter(&local);
                }
                Command::ReleaseSnowfall => {
                    settings.welcomed = true;
                    screens.iter_mut().for_each(|screen| screen.simulation.set_snowfall_held(false));
                }
                Command::ClearSnow(calm) => {
                    let direction = screens.first().map_or(-1.0, |screen| screen.simulation.breeze_direction());
                    for screen in &mut screens {
                        screen.simulation.blow_away(direction, calm);
                        screen.rain.clear();
                        screen.extras.clear();
                        if calm {
                            screen.icicles.melt();
                        } else {
                            screen.icicles.drop_all();
                        }
                    }
                }
                Command::Icicles(on) => {
                    settings.icicles = on;
                    let enabled = on && !settings.autumn && !settings.rain;
                    screens.iter_mut().for_each(|screen| screen.icicles.set_enabled(enabled));
                }
                Command::WarmGlow(on) => settings.warm_glow = on,
                Command::Breathe(strength) => {
                    if !hushed {
                        screens.iter_mut().for_each(|screen| {
                            screen.simulation.breathe(strength);
                            screen.wake(Clock::now());
                        });
                    }
                }
                Command::Hushed(on) => {
                    hushed = on;
                    screens.iter().for_each(|screen| screen.set_hidden(on));
                    if !on {
                        screens.iter_mut().for_each(Screen::resume);
                    }
                    log!("hushed: {on}");
                }
                Command::SetWeather { weather, calm } => {
                    settings.autumn = weather == 1 || weather == 2;
                    settings.petals = weather == 2;
                    settings.rain = weather == 3;
                    settings.hail = weather == 4;
                    let direction = screens.first().map_or(-1.0, |screen| screen.simulation.breeze_direction());
                    let now = Clock::now();
                    screens.iter_mut().for_each(|screen| {
                        apply(screen, &settings, Some((direction, calm)));
                        screen.wake(now);
                    });
                }
                Command::Refresh(next) => {
                    // Only what looks different; switching what falls goes through SetWeather.
                    settings = Settings { snowfall: settings.snowfall, ..next };
                    screens.iter_mut().for_each(|screen| apply(screen, &settings, None));
                }
                Command::Fireworks(seconds) => screens.iter_mut().for_each(|screen| screen.extras.fireworks(seconds)),
                Command::Flurry => screens.iter_mut().for_each(|screen| screen.extras.flurry()),
                Command::MaxPerformance(on) => {
                    settings.max_performance = on;
                    screens.iter_mut().for_each(|screen| screen.max_performance = on);
                }
                Command::OverFullScreen(on) => {
                    settings.over_full_screen = on;
                    screens.iter_mut().for_each(Screen::resume);
                }
                Command::Active(on) => {
                    if on && !active {
                        screens.iter_mut().for_each(Screen::resume);
                    }
                    active = on;
                    log!("active: {on}");
                }
            }
        }

        let mut message = MSG::default();
        while unsafe { PeekMessageW(&mut message, None, 0, 0, PM_REMOVE) }.as_bool() {
            unsafe {
                let _ = TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }

        let mut now = Clock::now();
        if DISPLAYS_CHANGED.take() {
            displays_changed_at = Some(now);
        }
        // Display changes come in bursts; the layout is read once they settle.
        if let Some(changed_at) = displays_changed_at
            && clock.seconds(now - changed_at) > 0.4
        {
            displays_changed_at = None;
            if settings.behind_windows {
                layer = find_layer();
            }
            screens = sync_screens(&gpu, &settings, screens, layer, false);
            clock.refresh();
            light_at = 0;
        }
        if BACKDROP_CHANGED.take() {
            light_at = 0;
        }

        if now >= chores_at {
            chores_at = now + clock.frequency;
            clock.refresh();
            // In case a display change went unannounced.
            let current = monitors(settings.behind_taskbar);
            if current.len() != screens.len() || screens.iter().any(|screen| !current.contains(&screen.monitor)) {
                DISPLAYS_CHANGED.set(true);
            }
            let next = power_budget(settings.battery_saver);
            if next != budget {
                budget = next;
                log!("power: {budget:?}");
                let density = if budget == PowerBudget::Saver { 0.75 } else { 1.0 };
                screens.iter_mut().for_each(|screen| screen.simulation.set_density(density));
            }
            screens.iter().for_each(Screen::raise);
            // Behind windows, the overlays live inside Explorer's windows and vanish when it restarts; until the
            // wallpaper layer is found they wait on top of everything instead.
            if settings.behind_windows && (layer.is_none() || screens.iter().any(|screen| !screen.alive())) {
                let found = find_layer();
                if found.is_some() || screens.iter().any(|screen| !screen.alive()) {
                    layer = found;
                    screens = sync_screens(&gpu, &settings, screens, layer, true);
                }
            }
            // Wallpaper apps share the layer the snow goes into; how they settle around it tells what went wrong.
            if settings.behind_windows {
                let tree = desktop::tree();
                if tree != desktop_logged {
                    log!("desktop: {tree}");
                    desktop_logged = tree;
                }
            }
            if now >= light_at {
                light_at = now + clock.frequency * 60;
                sky = Sky::now();
                if let Some(wallpapers) = &wallpapers {
                    screens.iter_mut().for_each(|screen| screen.update_backdrop(wallpapers));
                }
            }
        }

        if active && !hushed {
            // A drag starting is drawn right away instead of at the next calm frame.
            if tracker.take_started_moving() && settings.snow_on_windows {
                screens.iter_mut().for_each(|screen| screen.wake(now));
            }
            if screens.iter().any(|screen| screen.next_due <= now + clock.tolerance()) {
                tracker.refresh(&clock, now);
            }
            // Behind the windows the snow still settles on them: what lies on a window's top edge is above it, in plain view.
            let windows = settings.snow_on_windows.then_some(&tracker);
            let time = (clock.seconds(now - started) % 1000.0) as f32;
            let mut lost = false;
            let mut released = false;
            for screen in screens.iter_mut().filter(|screen| screen.next_due <= now + clock.tolerance()) {
                let covering = if settings.over_full_screen { None } else { tracker.covering(&screen.monitor.bounds) };
                if covering.is_some() != screen.covered() {
                    log!("{} {}", screen.monitor.name, covering.map_or("uncovered".to_string(), |class| format!("covered by {class}")));
                    screen.set_covered(covering.is_some());
                }
                if screen.covered() {
                    screen.next_due = now + clock.frequency / 4;
                    continue;
                }
                let began = Clock::now();
                match screen.frame(&gpu, &clock, now, budget, sky, time, windows, settings.warm_glow) {
                    Ok(drew) => {
                        stats.frame(drew, Clock::now() - began, screen.simulation.sprite_count());
                        released |= screen.simulation.take_snowfall_released();
                    }
                    Err(error) => {
                        log!("frame failed: {error}");
                        lost = true;
                    }
                }
            }
            // Sounds the extras asked for go to the main thread, which plays them.
            let cues: Vec<Cue> = screens.iter_mut().flat_map(|screen| screen.cues.drain(..)).collect();
            if !cues.is_empty() {
                let cues = Box::into_raw(Box::new(cues));
                unsafe {
                    if PostMessageW(Some(HWND(links.controller as _)), WM_CUES, WPARAM(0), LPARAM(cues as isize)).is_err() {
                        drop(Box::from_raw(cues));
                    }
                }
            }
            // The first display the welcome window's snow reaches starts the snowfall on all of them.
            if released {
                settings.welcomed = true;
                screens.iter_mut().for_each(|screen| screen.simulation.set_snowfall_held(false));
            }
            if lost {
                screens.clear();
                gpu = Gpu::new()?;
                screens = sync_screens(&gpu, &settings, Vec::new(), layer, false);
            }
            now = Clock::now();
            stats.report(&clock, now, &mut tracker);
        }

        let due = screens.iter().map(|screen| screen.next_due).min().filter(|_| active && !hushed);
        unsafe {
            if let Some(due) = due {
                let wait = -(((due - now).max(0) as i128 * 10_000_000) / clock.frequency as i128) as i64;
                let _ = SetWaitableTimer(timer, &wait, 0, None, None, false);
                // Messages wait for the next frame: window reports arrive with every mouse move,
                // and waking for each would cost more than the snow.
                WaitForMultipleObjects(&[wake, timer], false, INFINITE);
            } else {
                MsgWaitForMultipleObjectsEx(Some(&[wake]), INFINITE, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
            }
        }
    }
}

/// One overlay per display: new displays get snow, removed ones lose theirs, and a display that changed
/// size keeps its snow in a fresh overlay. `rebuild` gives every display a fresh overlay, as when the snow
/// moves behind windows or back.
fn sync_screens(gpu: &Gpu, settings: &Settings, mut current: Vec<Screen>, layer: Option<DesktopLayer>, rebuild: bool) -> Vec<Screen> {
    let mut result = Vec::new();
    let displays = monitors(settings.behind_taskbar);
    for monitor in displays.iter().cloned() {
        let kept = current.iter().position(|screen| screen.monitor.name == monitor.name);
        let simulation = match kept.map(|i| current.swap_remove(i)) {
            Some(screen) if screen.monitor == monitor && !rebuild && screen.behind_windows() == layer.is_some() => {
                result.push(screen);
                continue;
            }
            Some(screen) => {
                let mut simulation = screen.simulation;
                let (width, height) = dip_size(&monitor);
                simulation.resize(width as f32, height as f32);
                simulation
            }
            None => new_simulation(&monitor, settings),
        };
        log!("display {}: {:?}, {} dpi, {} Hz", monitor.name, monitor.rect, monitor.dpi, monitor.refresh);
        let screen = Screen::new(gpu, monitor.clone(), simulation, settings, layer).or_else(|(error, simulation)| {
            // Snow that can't go behind windows stays on top of them rather than vanishing.
            if layer.is_none() {
                return Err((error, simulation));
            }
            log!("overlay behind windows failed: {error}");
            Screen::new(gpu, monitor, simulation, settings, None)
        });
        match screen {
            Ok(mut screen) => {
                apply(&mut screen, settings, None);
                result.push(screen);
            }
            Err((error, _)) => log!("overlay failed: {error}"),
        }
    }
    for screen in &mut result {
        screen.simulation.walls = walls(&screen.monitor, &displays);
    }
    result
}

fn find_layer() -> Option<DesktopLayer> {
    let layer = desktop::find();
    log!("desktop layer: {layer:?}");
    layer
}

fn new_simulation(monitor: &Monitor, settings: &Settings) -> SnowSimulation {
    let (width, height) = dip_size(monitor);
    let mut simulation = SnowSimulation::new(width as f32, height as f32, settings.snowfall);
    simulation.thaws = settings.melt;
    simulation.accumulates = settings.accumulate;
    simulation.set_snowfall_held(!settings.welcomed);
    simulation.set_autumn(settings.autumn);
    if settings.rain {
        simulation.set_snowfall(Snowfall::Off);
    }
    simulation
}

fn power_budget(saver: bool) -> PowerBudget {
    let mut status = SYSTEM_POWER_STATUS::default();
    if unsafe { GetSystemPowerStatus(&mut status) }.is_err() {
        return PowerBudget::Full;
    }
    if status.SystemStatusFlag == 1 {
        PowerBudget::Saver
    } else if status.ACLineStatus == 0 {
        // Battery Saver in the menu goes easier on the battery still.
        if saver { PowerBudget::Saver } else { PowerBudget::Battery }
    } else {
        PowerBudget::Full
    }
}

/// What a frame costs on this thread, written to the log twice a minute.
struct Stats {
    since: i64,
    steps: u32,
    draws: u32,
    busy: i64,
    sprites: usize,
}

impl Stats {
    fn new(now: i64) -> Stats {
        Stats { since: now, steps: 0, draws: 0, busy: 0, sprites: 0 }
    }

    fn frame(&mut self, drew: bool, busy: i64, sprites: usize) {
        self.steps += 1;
        self.draws += drew as u32;
        self.busy += busy;
        self.sprites = self.sprites.max(sprites);
    }

    fn report(&mut self, clock: &Clock, now: i64, tracker: &mut Tracker) {
        let elapsed = clock.seconds(now - self.since);
        if elapsed < 30.0 {
            return;
        }
        let busy = clock.seconds(self.busy);
        let listing = clock.seconds(tracker.cost);
        log!(
            "frames: {:.1} steps/s, {:.1} draws/s, {:.0} µs per step, {:.2}% of a core, up to {} sprites; windows: {:.1} reads/s, {:.0} µs per read",
            self.steps as f64 / elapsed,
            self.draws as f64 / elapsed,
            busy * 1e6 / self.steps.max(1) as f64,
            (busy + listing) / elapsed * 100.0,
            self.sprites,
            tracker.listings as f64 / elapsed,
            listing * 1e6 / tracker.listings.max(1) as f64
        );
        *self = Stats::new(now);
        tracker.listings = 0;
        tracker.cost = 0;
    }
}

/// The weather the settings ask for.
pub fn weather(settings: &Settings) -> Weather {
    if settings.rain {
        Weather::Rain
    } else if settings.hail {
        Weather::Hail
    } else if settings.petals {
        Weather::Petals
    } else if settings.autumn {
        Weather::Leaves
    } else {
        Weather::Snow
    }
}

/// Sets a display to the settings: what falls and how hard, how it looks, the icicles and the extras. With a breeze's
/// direction and calmness, the weather is switching: what lies goes, blown away or melting.
fn apply(screen: &mut Screen, settings: &Settings, switching: Option<(f32, bool)>) {
    let weather = weather(settings);
    let leafy = matches!(weather, Weather::Leaves | Weather::Petals);
    let piles = matches!(weather, Weather::Snow | Weather::Leaves | Weather::Petals);
    match switching {
        Some((direction, calm)) => {
            if leafy != screen.simulation.autumn() {
                screen.simulation.switch_mode(leafy, direction, calm);
            } else if !piles {
                // Rain and hail don't lie: what snow or leaves there are blow away as they start.
                screen.simulation.blow_away(direction, calm);
            }
            if weather != Weather::Snow {
                if calm {
                    screen.icicles.melt();
                } else {
                    screen.icicles.drop_all();
                }
            }
        }
        None => screen.simulation.set_autumn(leafy),
    }
    screen.simulation.set_snowfall(if piles { settings.snowfall } else { Snowfall::Off });
    let rains = weather == Weather::Rain || (settings.mix_rain && piles);
    let strength = rain::intensity(settings.snowfall);
    screen.rain.set_intensity(strength * if weather == Weather::Rain { 1.0 } else { 0.6 });
    screen.rain.set_on(rains && settings.snowfall != Snowfall::Off);
    screen.icicles.set_enabled(settings.icicles && weather == Weather::Snow);
    screen.look = crate::render::Look { petals: weather == Weather::Petals, opacity: settings.opacity as f32 / 100.0 };
    screen.deep = settings.deep_interaction;
    screen.extras.settings = ExtrasSettings {
        weather,
        intensity: strength,
        blizzard: settings.blizzard,
        fog: settings.fog,
        stars: settings.stars,
        garland: settings.garland,
        frost: settings.frost,
        creatures: settings.creatures,
    };
}
