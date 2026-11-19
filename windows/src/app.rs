use std::cell::RefCell;
use std::mem::size_of;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc::{self, Sender};
use std::thread::{self, JoinHandle};

use windows::Win32::Foundation::{HANDLE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::Com::{COINIT_APARTMENTTHREADED, CoInitializeEx};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Power::{POWERBROADCAST_SETTING, RegisterPowerSettingNotification};
use windows::Win32::System::Registry::{HKEY_CURRENT_USER, RRF_RT_REG_DWORD, RegGetValueW};
use windows::Win32::System::RemoteDesktop::{NOTIFY_FOR_THIS_SESSION, WTSRegisterSessionNotification};
use windows::Win32::System::SystemServices::GUID_CONSOLE_DISPLAY_STATE;
use windows::Win32::System::Threading::{CreateEventW, SetEvent};
use windows::Win32::UI::HiDpi::{GetDpiForSystem, GetSystemMetricsForDpi};
use windows::Win32::UI::Shell::{
    NIF_ICON, NIF_MESSAGE, NIF_SHOWTIP, NIF_TIP, NIM_ADD, NIM_DELETE, NIM_MODIFY, NIM_SETVERSION, NIN_SELECT, NOTIFYICON_VERSION_4,
    NOTIFYICONDATAW, Shell_NotifyIconW,
};
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{HSTRING, PCWSTR, Result, w};

use crate::audio::{Ear, Sound};
use crate::calls;
use crate::log;
use crate::prefs::{self, Settings};
use crate::snow::{self, Command, Links};
use crate::{weather, whats_new};
use snowpuff_core::extras::Weather;
use snowpuff_core::sfx::Cue;
use crate::update::{self, Release};
use crate::welcome::{self, Handlers};
use snowpuff::text::{russian, tr};
use snowpuff_core::simulation::Snowfall;

const CLASS: PCWSTR = w!("SnowpuffController");
const WM_TRAY: u32 = WM_APP + 1;
/// The microphone couldn't be opened; posted from the ear's thread.
const WM_DEAF: u32 = WM_APP + 2;
/// An update check or install finished; posted from its thread with a boxed `Updated`.
const WM_UPDATE: u32 = WM_APP + 3;
const NIN_KEYSELECT: u32 = NIN_SELECT | 1;
const ID_SNOWFALL: u32 = 100;
const ID_SOUND: u32 = 150;
const ID_VOLUME: u32 = 160;
const ID_ACCUMULATE: u32 = 200;
const ID_MELT: u32 = 201;
const ID_SCREENSHOTS: u32 = 202;
const ID_LOGIN: u32 = 203;
const ID_WINDOWS: u32 = 204;
const ID_BEHIND: u32 = 205;
const ID_CLEAR: u32 = 207;
const ID_TASKBAR: u32 = 209;
const ID_ICICLES: u32 = 210;
const ID_GLOW: u32 = 211;
const ID_PUFF: u32 = 212;
const ID_QUIET: u32 = 213;
const ID_UPDATES: u32 = 214;
const ID_AUTO_UPDATE: u32 = 215;
const ID_DONATE: u32 = 216;
const ID_SITE: u32 = 217;
const ID_ABOUT: u32 = 218;
const ID_OVER_FULL_SCREEN: u32 = 222;
const ID_PERFORMANCE: u32 = 224;
const TIMER_CLOCK: usize = 4;
const TIMER_WORDS: usize = 5;
const TIMER_WEATHER: usize = 6;
const WM_WHATS_NEW: u32 = WM_APP + 6;

const ID_QUIT: u32 = 299;
const TIMER_WELCOME: usize = 1;
const TIMER_CALLS: usize = 2;
const TIMER_UPDATES: usize = 3;
/// How often a running Snowpuff looks for a new version.
const UPDATE_EVERY: u32 = 3 * 60 * 60 * 1000;
const DONATE: &str = "https://t.me/hhrrzz1";
const SITE: &str = "https://ehroz.pro";
/// Volumes the sound menu offers, in percent.
const VOLUMES: [u32; 4] = [25, 50, 75, 100];

static TASKBAR_CREATED: AtomicU32 = AtomicU32::new(0);

struct App {
    settings: Settings,
    commands: Sender<Command>,
    wake: HANDLE,
    snow: Option<JoinHandle<()>>,
    icon: HICON,
    locked: bool,
    display_off: bool,
    away: bool,
    /// Another app has the camera or microphone: the snow and its sound step aside.
    hushed: bool,
    /// How long the camera or microphone has been in use, or free, in checks, so a moment's use doesn't flicker it.
    busy_checks: u32,
    free_checks: u32,
    sound: Sound,
    ear: Option<Ear>,
    /// A newer version found while automatic updates are off, offered in the menu.
    update: Option<Release>,
    /// An update check or download is under way.
    updating: bool,
    /// The weather outside, while Weather Outside is on, and its line for the menu.
    outside: Option<weather::Now>,
    live: Option<String>,
    /// The watched keys down at the last look, and the order the last few went down in, for "snow".
    keys_down: u8,
    typed: Vec<(u8, u32)>,
    /// The year whose New Year fireworks have gone off.
    fireworks_year: u16,
    /// The snowfall before Ctrl+Alt+S turned it off, to bring it back.
    snowfall_before: Option<Snowfall>,
}

impl App {
    /// The settings with the weather outside in place of the mode and intensity picked, while that is on.
    fn effective(&self) -> Settings {
        let mut settings = self.settings;
        if let Some(now) = self.outside {
            settings.autumn = false;
            settings.petals = false;
            settings.rain = now.weather == 3;
            settings.hail = now.weather == 4;
            settings.snowfall = now.snowfall;
            settings.fog |= now.fog;
        }
        settings
    }
}

/// What an update thread reports back.
enum Updated {
    Checked(std::result::Result<Option<Release>, String>),
    Failed(String),
}

thread_local! {
    static APP: RefCell<Option<App>> = const { RefCell::new(None) };
}

/// The tray icon and its menu, and the system events that pause the snow, on the main thread;
/// the snow itself runs on its own thread so menus and other modal loops never stall it.
pub fn run() -> Result<()> {
    unsafe {
        CoInitializeEx(None, COINIT_APARTMENTTHREADED).ok()?;
        let instance = GetModuleHandleW(None)?;
        let class = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(procedure),
            hInstance: instance.into(),
            lpszClassName: CLASS,
            ..Default::default()
        };
        RegisterClassExW(&class);
        let window = CreateWindowExW(WINDOW_EX_STYLE(0), CLASS, w!("Snowpuff"), WS_OVERLAPPED, 0, 0, 0, 0, None, None, Some(instance.into()), None)?;
        TASKBAR_CREATED.store(RegisterWindowMessageW(w!("TaskbarCreated")), Ordering::Relaxed);

        prefs::restore_after_reinstall();
        let mut settings = Settings::load();
        // Coming from a version before the settings file: write it now, so it is there to outlive an uninstall.
        if snowpuff::store::read().is_none() {
            settings.save();
        }
        // Snow that only falls when remembered isn't much of a mood: the first run adds Snowpuff to the apps that
        // open at login; the menu turns that off.
        if !settings.login_offered {
            settings.login_offered = true;
            settings.save();
            if !prefs::opens_at_login() {
                let status = prefs::set_opens_at_login(true);
                log!("open at login on first run: {status:?}");
            }
        }
        let (commands, receiver) = mpsc::channel();
        let wake = CreateEventW(None, false, false, None)?;
        let links = Links { wake: wake.0 as isize, controller: window.0 as isize };
        let snow = thread::Builder::new().name("snow".into()).spawn(move || snow::run(receiver, links, settings)).ok();
        let icon = tray_icon(settings.snowfall == Snowfall::Off);
        add_tray_icon(window, icon);
        let _ = WTSRegisterSessionNotification(window, NOTIFY_FOR_THIS_SESSION);
        let _ = RegisterPowerSettingNotification(HANDLE(window.0), &GUID_CONSOLE_DISPLAY_STATE, DEVICE_NOTIFY_WINDOW_HANDLE);
        if !settings.welcomed {
            SetTimer(Some(window), TIMER_WELCOME, 1200, None);
        }
        if settings.quiet_on_calls {
            SetTimer(Some(window), TIMER_CALLS, 2000, None);
        }
        SetTimer(Some(window), TIMER_CLOCK, 1000, None);
        if settings.hotkeys {
            register_hotkeys(window);
        }
        if settings.words {
            SetTimer(Some(window), TIMER_WORDS, 33, None);
        }
        if settings.live_weather {
            weather::look_outside(window);
            SetTimer(Some(window), TIMER_WEATHER, 30 * 60 * 1000, None);
        }
        // Just updated: say what changed, once. A first run has the welcome instead.
        let version = version_number(update::VERSION);
        if settings.welcomed && settings.seen_version != version {
            let _ = PostMessageW(Some(window), WM_WHATS_NEW, WPARAM(0), LPARAM(0));
        }
        if settings.seen_version != version {
            let mut seen = settings;
            seen.seen_version = version;
            seen.save();
        }
        // The first look for a new version waits until the snow has settled in.
        SetTimer(Some(window), TIMER_UPDATES, 60_000, None);
        let mut app = App {
            settings,
            commands,
            wake,
            snow,
            icon,
            locked: false,
            display_off: false,
            away: false,
            hushed: false,
            busy_checks: 0,
            free_checks: 0,
            sound: Sound::new(),
            ear: None,
            update: None,
            updating: false,
            outside: None,
            live: None,
            keys_down: 0,
            typed: Vec::new(),
            fireworks_year: 0,
            snowfall_before: None,
        };
        refresh_sound(&mut app);
        if app.settings.puff {
            app.ear = Some(open_ear(&app, window));
        }
        APP.set(Some(app));

        let mut message = MSG::default();
        while GetMessageW(&mut message, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    Ok(())
}

/// A mistake while handling one message is logged and that message skipped; the tray and the snow carry on.
unsafe extern "system" fn procedure(window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    let handled = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| unsafe { handle(window, message, wparam, lparam) }));
    handled.unwrap_or_else(|_| {
        log!("message {message:#x} failed; skipped");
        unsafe { DefWindowProcW(window, message, wparam, lparam) }
    })
}

unsafe fn handle(window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match message {
        WM_TRAY => {
            let event = (lparam.0 & 0xffff) as u32;
            if event == WM_CONTEXTMENU || event == NIN_SELECT || event == NIN_KEYSELECT {
                let x = (wparam.0 & 0xffff) as i16 as i32;
                let y = ((wparam.0 >> 16) & 0xffff) as i16 as i32;
                show_menu(window, x, y);
            }
            LRESULT(0)
        }
        WM_WTSSESSION_CHANGE => {
            update(|app| match wparam.0 as u32 {
                WTS_SESSION_LOCK => app.locked = true,
                WTS_SESSION_UNLOCK => app.locked = false,
                WTS_CONSOLE_DISCONNECT | WTS_REMOTE_DISCONNECT => app.away = true,
                WTS_CONSOLE_CONNECT | WTS_REMOTE_CONNECT => app.away = false,
                _ => {}
            });
            LRESULT(0)
        }
        WM_POWERBROADCAST if wparam.0 as u32 == PBT_POWERSETTINGCHANGE => {
            let setting = unsafe { &*(lparam.0 as *const POWERBROADCAST_SETTING) };
            if setting.PowerSetting == GUID_CONSOLE_DISPLAY_STATE {
                let off = setting.Data[0] == 0;
                update(|app| app.display_off = off);
            }
            LRESULT(1)
        }
        // The taskbar turned light or dark: the tray's mark follows it.
        WM_SETTINGCHANGE => {
            APP.with_borrow_mut(|app| {
                if let Some(app) = app {
                    refresh_icon(window, app);
                }
            });
            LRESULT(0)
        }
        WM_CLOSE => {
            quit(window);
            LRESULT(0)
        }
        WM_TIMER if wparam.0 == TIMER_UPDATES => {
            unsafe { SetTimer(Some(window), TIMER_UPDATES, UPDATE_EVERY, None) };
            check_for_updates(window, false);
            LRESULT(0)
        }
        WM_UPDATE => {
            let result = unsafe { Box::from_raw(lparam.0 as *mut Updated) };
            updated(window, *result, wparam.0 != 0);
            LRESULT(0)
        }
        WM_HOTKEY => {
            hotkey(window, wparam.0 as i32);
            LRESULT(0)
        }
        WM_WHATS_NEW => {
            whats_new::show();
            LRESULT(0)
        }
        snow::WM_CUES => {
            let cues = unsafe { Box::from_raw(lparam.0 as *mut Vec<Cue>) };
            APP.with_borrow_mut(|app| {
                if let Some(app) = app
                    && app.settings.sound_effects
                    && !app.hushed
                {
                    cues.iter().for_each(|cue| app.sound.play(*cue));
                }
            });
            LRESULT(0)
        }
        weather::WM_WEATHER => {
            let result = unsafe { Box::from_raw(lparam.0 as *mut std::result::Result<weather::Now, String>) };
            let failed = APP.with_borrow_mut(|app| {
                let app = app.as_mut()?;
                if !app.settings.live_weather {
                    return None;
                }
                match *result {
                    Ok(now) => {
                        app.outside = Some(now);
                        app.live = Some(now.summary(russian()));
                        let effective = app.effective();
                        send(app, Command::SetWeather { weather: weather_index(snow::weather(&effective)) as u8, calm: !prefs::animations_enabled() });
                        send(app, Command::Snowfall(effective.snowfall));
                        send(app, Command::Refresh(effective));
                        refresh_sound(app);
                        None
                    }
                    Err(error) => {
                        app.settings.live_weather = false;
                        app.settings.save();
                        Some(error)
                    }
                }
            });
            if let Some(error) = failed {
                message_box(window, &error, MB_OK | MB_ICONINFORMATION);
            }
            LRESULT(0)
        }
        WM_TIMER if wparam.0 == TIMER_WEATHER => {
            weather::look_outside(window);
            LRESULT(0)
        }
        WM_TIMER if wparam.0 == TIMER_CLOCK => {
            // A surprise nobody is told about: fireworks at midnight on New Year, for three minutes.
            let now = unsafe { windows::Win32::System::SystemInformation::GetLocalTime() };
            if now.wMonth == 1 && now.wDay == 1 && now.wHour == 0 && now.wMinute == 0 {
                APP.with_borrow_mut(|app| {
                    if let Some(app) = app
                        && app.fireworks_year != now.wYear
                    {
                        app.fireworks_year = now.wYear;
                        send(app, Command::Fireworks(180.0));
                    }
                });
            }
            LRESULT(0)
        }
        WM_TIMER if wparam.0 == TIMER_WORDS => {
            watch_words();
            LRESULT(0)
        }
        WM_TIMER if wparam.0 == TIMER_CALLS => {
            check_calls(window);
            LRESULT(0)
        }
        WM_DEAF => {
            APP.with_borrow_mut(|app| {
                if let Some(app) = app {
                    app.ear = None;
                    app.settings.puff = false;
                    app.settings.save();
                }
            });
            message_box(
                window,
                tr(
                    "Snowpuff can't hear the microphone.\n\nTo blow on the snow, let desktop apps use the microphone in Settings → Privacy & security → Microphone. Sound is only listened to for a puff of breath, never recorded or sent anywhere.",
                    "Snowpuff не слышит микрофон.\n\nЧтобы дуть на снег, разреши классическим приложениям доступ к микрофону: Параметры → Конфиденциальность и защита → Микрофон. Звук только проверяется на «дуновение», он не записывается и никуда не отправляется.",
                ),
                MB_OK | MB_ICONINFORMATION,
            );
            LRESULT(0)
        }
        WM_TIMER if wparam.0 == TIMER_WELCOME => {
            unsafe {
                let _ = KillTimer(Some(window), TIMER_WELCOME);
            }
            welcome::show(Handlers {
                scatter: Box::new(|pieces| {
                    APP.with_borrow(|app| {
                        if let Some(app) = app {
                            send(app, Command::Scatter(pieces));
                        }
                    })
                }),
                finished: Box::new(|| {
                    APP.with_borrow_mut(|app| {
                        let Some(app) = app else { return };
                        app.settings.welcomed = true;
                        app.settings.save();
                    })
                }),
                skipped: Box::new(|| {
                    APP.with_borrow(|app| {
                        if let Some(app) = app {
                            send(app, Command::ReleaseSnowfall);
                        }
                    })
                }),
            });
            LRESULT(0)
        }
        _ if message != 0 && message == TASKBAR_CREATED.load(Ordering::Relaxed) => {
            APP.with_borrow(|app| {
                if let Some(app) = app {
                    add_tray_icon(window, app.icon);
                    send(app, Command::ShellRestarted);
                }
            });
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(window, message, wparam, lparam) },
    }
}

/// Changes what pauses the snow and tells the snow thread whether it may run.
fn update(change: impl FnOnce(&mut App)) {
    APP.with_borrow_mut(|app| {
        let Some(app) = app else { return };
        change(app);
        let active = !app.locked && !app.display_off && !app.away;
        send(app, Command::Active(active));
        refresh_sound(app);
    });
}

fn send(app: &App, command: Command) {
    let _ = app.commands.send(command);
    unsafe {
        let _ = SetEvent(app.wake);
    }
}

/// The sound plays only while someone is there to hear it and no call is on.
fn refresh_sound(app: &mut App) {
    let muted = app.hushed || app.locked || app.display_off || app.away;
    let windiness = match app.settings.snowfall {
        Snowfall::Off => 0.15,
        Snowfall::Light => 0.3,
        Snowfall::Heavy => 1.0,
        _ => 0.55,
    };
    app.sound.set(app.settings.ambience, muted, app.settings.volume as f32 / 100.0, windiness);
    let effective = app.effective();
    let strength = snowpuff_core::rain::intensity(effective.snowfall);
    let weather = snow::weather(&effective);
    let piles = matches!(weather, Weather::Snow | Weather::Leaves | Weather::Petals);
    let rains = weather == Weather::Rain || (effective.mix_rain && piles);
    let on = effective.sound_effects && !muted;
    app.sound.set_effects(on, if rains { strength } else { 0.0 }, if weather == Weather::Hail { strength } else { 0.0 });
}

/// Opens the microphone for breaths; each puff goes straight to the snow thread.
fn open_ear(app: &App, window: HWND) -> Ear {
    let commands = app.commands.clone();
    let wake = app.wake.0 as isize;
    let controller = window.0 as isize;
    Ear::start(
        move |strength| {
            let _ = commands.send(Command::Breathe(strength));
            unsafe {
                let _ = SetEvent(HANDLE(wake as _));
            }
        },
        move || unsafe {
            let _ = PostMessageW(Some(HWND(controller as _)), WM_DEAF, WPARAM(0), LPARAM(0));
        },
    )
}

/// A call takes a few seconds of use to count, and a few without to end, so a quick dictation doesn't flicker it.
fn check_calls(window: HWND) {
    let busy = calls::in_use();
    APP.with_borrow_mut(|app| {
        let Some(app) = app else { return };
        if busy {
            app.busy_checks += 1;
            app.free_checks = 0;
        } else {
            app.free_checks += 1;
            app.busy_checks = 0;
        }
        let hushed = if app.hushed { app.free_checks < 2 } else { app.busy_checks >= 2 };
        if hushed != app.hushed {
            set_hushed(app, hushed, window);
        }
    });
}

fn set_hushed(app: &mut App, hushed: bool, window: HWND) {
    app.hushed = hushed;
    send(app, Command::Hushed(hushed));
    refresh_sound(app);
    refresh_icon(window, app);
    log!("call: {hushed}");
}

fn snowfall_title(snowfall: Snowfall) -> &'static str {
    match snowfall {
        Snowfall::Off => tr("Off", "Выкл"),
        Snowfall::Light => tr("Light", "Лёгкий"),
        Snowfall::Steady => tr("Steady", "Ровный"),
        Snowfall::Heavy => tr("Heavy", "Метель"),
        Snowfall::Variable => tr("Variable", "Переменный"),
    }
}

fn append(menu: HMENU, flags: MENU_ITEM_FLAGS, id: u32, title: &str) {
    let title = HSTRING::from(title);
    unsafe {
        let _ = AppendMenuW(menu, flags, id as usize, &title);
    }
}

/// "snow", or "снег" on a Russian layout, typed anywhere brings a flurry. Only the eight keys those words use are looked
/// at, and only the order they go down in is kept, for two seconds: nothing typed is read, stored or sent.
fn watch_words() {
    // S N O W, and C Y T U where a Russian layout has С Н Е Г.
    const KEYS: [u16; 8] = [0x53, 0x4E, 0x4F, 0x57, 0x43, 0x59, 0x54, 0x55];
    let now = unsafe { windows::Win32::System::SystemInformation::GetTickCount() };
    let typed = APP.with_borrow_mut(|app| {
        let app = app.as_mut()?;
        let mut down = 0u8;
        for (i, key) in KEYS.iter().enumerate() {
            if unsafe { windows::Win32::UI::Input::KeyboardAndMouse::GetAsyncKeyState(*key as i32) } < 0 {
                down |= 1 << i;
                if app.keys_down & (1 << i) == 0 {
                    app.typed.push((i as u8, now));
                }
            }
        }
        app.keys_down = down;
        app.typed.retain(|(_, at)| now.wrapping_sub(*at) < 2000);
        let last: Vec<u8> = app.typed.iter().rev().take(4).rev().map(|(k, _)| *k).collect();
        if last == [0, 1, 2, 3] || last == [4, 5, 6, 7] {
            app.typed.clear();
            send(app, Command::Flurry);
        }
        Some(())
    });
    let _ = typed;
}

/// A version as one number for the registry: 1.3.0 is 10300.
fn version_number(version: &str) -> u32 {
    version.split('.').take(3).map(|p| p.parse::<u32>().unwrap_or(0)).fold(0, |n, p| n * 100 + p)
}

/// A setting that only flips on and off and needs nothing but the snow thread told: its title, how to read it from
/// the settings and how to flip it, and when it can't be changed.
struct Switch {
    english: &'static str,
    russian: &'static str,
    get: fn(&Settings) -> bool,
    flip: fn(&mut Settings),
    enabled: fn(&Settings) -> bool,
}

const fn switch(english: &'static str, russian: &'static str, get: fn(&Settings) -> bool, flip: fn(&mut Settings)) -> Switch {
    Switch { english, russian, get, flip, enabled: |_| true }
}

/// The Magic group in Settings, and a few Behavior and Display switches, all sent to the snow thread as a refresh.
const SWITCHES: [Switch; 10] = [
    Switch {
        english: "Snow on Selection",
        russian: "Снег на рамке выделения",
        get: |s| s.deep_interaction,
        flip: |s| s.deep_interaction = !s.deep_interaction,
        enabled: |s| s.snow_on_windows,
    },
    switch("Typing \"snow\" Brings a Flurry", "Слово «снег» вызывает снегопад", |s| s.words, |s| s.words = !s.words),
    switch("Swirl Behind the Cursor", "Метель за курсором", |s| s.blizzard, |s| s.blizzard = !s.blizzard),
    switch("Frost and Misted Glass", "Иней и запотевшее стекло", |s| s.frost, |s| s.frost = !s.frost),
    switch("Fog", "Туман", |s| s.fog, |s| s.fog = !s.fog),
    switch("Starry Sky", "Звёздное небо", |s| s.stars, |s| s.stars = !s.stars),
    switch("Garland on Windows", "Гирлянда на окнах", |s| s.garland, |s| s.garland = !s.garland),
    switch("Cat and Bullfinch", "Кот и снегирь", |s| s.creatures, |s| s.creatures = !s.creatures),
    switch("Battery Saver", "Экономить батарею", |s| s.battery_saver, |s| s.battery_saver = !s.battery_saver),
    switch("Sound Effects", "Звуки эффектов", |s| s.sound_effects, |s| s.sound_effects = !s.sound_effects),
];
const ID_SWITCH: u32 = 300;
const ID_WEATHER: u32 = 230;
const ID_MIX_RAIN: u32 = 235;
const ID_LIVE: u32 = 236;
const ID_WHATS_NEW: u32 = 238;
const ID_REPORT: u32 = 239;
const ID_HELP: u32 = 240;
const ID_HOTKEYS: u32 = 241;

/// Ctrl+Alt and a letter, anywhere: the letters, and what each does.
const HOTKEYS: [(u32, u16); 8] = [
    (1, b'S' as u16), // snow on and off
    (2, b'M' as u16), // the next mode
    (3, b'N' as u16), // a snowman at the cursor
    (4, b'B' as u16), // a snowball at the cursor
    (5, b'C' as u16), // clear the snow
    (6, b'F' as u16), // frost on and off
    (7, b'G' as u16), // the garland on and off
    (8, b'H' as u16), // How to Use
];

fn register_hotkeys(window: HWND) {
    use windows::Win32::UI::Input::KeyboardAndMouse::{MOD_ALT, MOD_CONTROL, MOD_NOREPEAT, RegisterHotKey};
    for (id, key) in HOTKEYS {
        // Another app may hold the same keys; Snowpuff's others still work.
        if let Err(error) = unsafe { RegisterHotKey(Some(window), id as i32, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, key as u32) } {
            log!("hotkey Ctrl+Alt+{} taken: {error}", key as u8 as char);
        }
    }
}

fn unregister_hotkeys(window: HWND) {
    use windows::Win32::UI::Input::KeyboardAndMouse::UnregisterHotKey;
    for (id, _) in HOTKEYS {
        unsafe {
            let _ = UnregisterHotKey(Some(window), id as i32);
        }
    }
}

fn hotkey(window: HWND, id: i32) {
    let login = prefs::opens_at_login();
    match id {
        1 => APP.with_borrow_mut(|app| {
            let Some(app) = app else { return };
            let next = if app.settings.snowfall == Snowfall::Off {
                app.snowfall_before.take().unwrap_or(Snowfall::Steady)
            } else {
                app.snowfall_before = Some(app.settings.snowfall);
                Snowfall::Off
            };
            app.settings.snowfall = next;
            app.settings.save();
            send(app, Command::Snowfall(next));
            refresh_sound(app);
            refresh_icon(window, app);
        }),
        2 => {
            let next = APP.with_borrow(|app| app.as_ref().map(|app| (weather_index(snow::weather(&app.settings)) + 1) % 5));
            if let Some(next) = next {
                choose(window, ID_WEATHER + next, login);
            }
        }
        3 => APP.with_borrow(|app| {
            if let Some(app) = app {
                send(app, Command::Snowman);
            }
        }),
        4 => APP.with_borrow(|app| {
            if let Some(app) = app {
                send(app, Command::Snowball);
            }
        }),
        5 => choose(window, ID_CLEAR, login),
        6 => choose(window, ID_SWITCH + 3, login),
        7 => choose(window, ID_SWITCH + 6, login),
        8 => whats_new::show_help(),
        _ => {}
    }
}
const ID_OPACITY: u32 = 260;
const OPACITIES: [u32; 4] = [25, 50, 75, 100];

/// Days and hours to midnight on New Year, in the menu.
fn countdown() -> String {
    let now = unsafe { windows::Win32::System::SystemInformation::GetLocalTime() };
    let leap = |y: u16| (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let days_in = [31, if leap(now.wYear) { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let day_of_year: u32 = days_in[..now.wMonth as usize - 1].iter().sum::<u32>() + now.wDay as u32;
    let days_total: u32 = days_in.iter().sum();
    let minutes_left = (days_total - day_of_year) * 24 * 60 + (23 - now.wHour as u32) * 60 + (60 - now.wMinute as u32);
    let (days, hours, minutes) = (minutes_left / 1440, minutes_left % 1440 / 60, minutes_left % 60);
    match (days, russian()) {
        (0, true) => format!("До Нового года {hours} ч {minutes} мин"),
        (0, false) => format!("New Year in {hours} h {minutes} min"),
        (_, true) => format!("До Нового года {days} дн {hours} ч"),
        (_, false) => format!("New Year in {days} d {hours} h"),
    }
}

fn show_menu(window: HWND, x: i32, y: i32) {
    let Some((settings, pending, updating, live)) = APP.with_borrow(|app| {
        app.as_ref().map(|app| (app.settings, app.update.as_ref().map(|r| r.version.clone()), app.updating, app.live.clone()))
    }) else {
        return;
    };
    let login = prefs::opens_at_login();
    let checked = |on: bool| if on { MF_CHECKED } else { MF_UNCHECKED };
    let enabled = |on: bool| if on { MF_ENABLED } else { MF_GRAYED };
    let weather = snow::weather(&settings);
    let piles = matches!(weather, Weather::Snow | Weather::Leaves | Weather::Petals);
    let leafy = matches!(weather, Weather::Leaves | Weather::Petals);
    let chosen = unsafe {
        let Ok(menu) = CreatePopupMenu() else { return };
        let Ok(snowfall) = CreatePopupMenu() else { return };
        let Ok(sound) = CreatePopupMenu() else { return };
        let Ok(modes) = CreatePopupMenu() else { return };
        let Ok(options) = CreatePopupMenu() else { return };
        let Ok(opacity) = CreatePopupMenu() else { return };
        for (i, option) in Snowfall::ALL.iter().enumerate() {
            append(snowfall, MF_STRING, ID_SNOWFALL + i as u32, snowfall_title(*option));
        }
        let current = Snowfall::ALL.iter().position(|&s| s == settings.snowfall).unwrap_or(0) as u32;
        let _ = CheckMenuRadioItem(snowfall, ID_SNOWFALL, ID_SNOWFALL + 4, ID_SNOWFALL + current, MF_BYCOMMAND.0);
        let sounds = [tr("Off", "Выкл"), tr("Wind", "Ветер"), tr("Fireplace", "Камин"), tr("Wind and Fireplace", "Ветер и камин")];
        for (i, mode) in sounds.iter().enumerate() {
            append(sound, MF_STRING, ID_SOUND + i as u32, mode);
        }
        let _ = CheckMenuRadioItem(sound, ID_SOUND, ID_SOUND + 3, ID_SOUND + settings.ambience, MF_BYCOMMAND.0);
        let _ = AppendMenuW(sound, MF_SEPARATOR, 0, PCWSTR::null());
        for (i, volume) in VOLUMES.iter().enumerate() {
            let title = if russian() { format!("Громкость {volume}%") } else { format!("Volume {volume}%") };
            append(sound, MF_STRING, ID_VOLUME + i as u32, &title);
        }
        let nearest = VOLUMES.iter().enumerate().min_by_key(|(_, v)| v.abs_diff(settings.volume)).map_or(1, |(i, _)| i) as u32;
        let _ = CheckMenuRadioItem(sound, ID_VOLUME, ID_VOLUME + 3, ID_VOLUME + nearest, MF_BYCOMMAND.0);
        let _ = AppendMenuW(sound, MF_SEPARATOR, 0, PCWSTR::null());
        append(sound, MF_STRING | checked(settings.sound_effects), ID_SWITCH + 9, tr("Sound Effects", "Звуки эффектов"));

        // Mode: what falls.
        let titles = [
            tr("Snow", "Снег"),
            tr("Autumn Leaves", "Осенние листья"),
            tr("Cherry Blossom", "Цветущая сакура"),
            tr("Rain", "Дождь"),
            tr("Hail", "Град"),
        ];
        for (i, title) in titles.iter().enumerate() {
            append(modes, MF_STRING | enabled(live.is_none()), ID_WEATHER + i as u32, title);
        }
        let _ = CheckMenuRadioItem(modes, ID_WEATHER, ID_WEATHER + 4, ID_WEATHER + weather_index(weather), MF_BYCOMMAND.0);
        let _ = AppendMenuW(modes, MF_SEPARATOR, 0, PCWSTR::null());
        append(modes, MF_STRING | checked(settings.mix_rain) | enabled(piles), ID_MIX_RAIN, tr("Add Rain", "Добавить дождь"));
        let outside = match &live {
            Some(now) if russian() => format!("Погода за окном: {now}"),
            Some(now) => format!("Weather Outside: {now}"),
            None => tr("Weather Outside", "Погода за окном").to_string(),
        };
        append(modes, MF_STRING | checked(settings.live_weather), ID_LIVE, &outside);

        // Settings, in groups.
        let header = |menu: HMENU, title: &str| append(menu, MF_STRING | MF_GRAYED, 0, title);
        let on_windows = settings.snow_on_windows && !settings.behind_windows;
        let pick = |snow: &'static str, leaves: &'static str| if leafy { leaves } else { snow };
        header(options, tr("— Behavior —", "— Поведение —"));
        append(options, MF_STRING | checked(settings.accumulate) | enabled(piles), ID_ACCUMULATE, tr("Accumulate on the Ground", "Сугробы на земле"));
        append(options, MF_STRING | checked(settings.snow_on_windows) | enabled(!settings.behind_windows), ID_WINDOWS, pick(tr("Snow on Windows", "Снег на окнах"), tr("Leaves on Windows", "Листья на окнах")));
        append(options, MF_STRING | checked(settings.melt) | enabled(settings.accumulate && piles), ID_MELT, if weather == Weather::Petals { tr("Wilt Petals", "Лепестки вянут") } else { pick(tr("Melt Snow", "Таяние"), tr("Wither Leaves", "Листья вянут")) });
        append(options, MF_STRING | checked(settings.icicles) | enabled(on_windows && weather == Weather::Snow), ID_ICICLES, tr("Icicles", "Сосульки"));
        append(options, MF_STRING | checked(settings.warm_glow) | enabled(on_windows), ID_GLOW, tr("Warm Window Light", "Тёплый свет окна"));
        append(options, MF_STRING | checked(settings.puff), ID_PUFF, tr("Blow on the Snow (Microphone)", "Подуть на снег (микрофон)"));
        append(options, MF_STRING | checked(settings.quiet_on_calls), ID_QUIET, tr("Hide During Calls", "Прятать на созвонах"));
        for (i, item) in SWITCHES.iter().enumerate().take(2) {
            append(options, MF_STRING | checked((item.get)(&settings)) | enabled((item.enabled)(&settings)), ID_SWITCH + i as u32, tr(item.english, item.russian));
        }
        header(options, tr("— Magic —", "— Волшебство —"));
        for (i, item) in SWITCHES.iter().enumerate().skip(2).take(6) {
            append(options, MF_STRING | checked((item.get)(&settings)) | enabled((item.enabled)(&settings)), ID_SWITCH + i as u32, tr(item.english, item.russian));
        }
        header(options, tr("Alt + move: draw on frost · Alt held on a drift: snowman · Alt-click: snowball", "Alt + курсор: рисовать по инею · Alt на сугробе: снеговик · Alt + клик: снежок"));
        header(options, tr("— Display —", "— Отображение —"));
        append(options, MF_STRING | checked(settings.behind_windows), ID_BEHIND, tr("Behind Windows", "За окнами"));
        append(options, MF_STRING | checked(settings.over_full_screen) | enabled(!settings.behind_windows), ID_OVER_FULL_SCREEN, tr("Show over Full Screen", "Поверх полноэкранных приложений"));
        append(options, MF_STRING | checked(settings.behind_taskbar), ID_TASKBAR, tr("Behind Taskbar", "За панелью задач"));
        append(options, MF_STRING | checked(settings.show_in_screenshots), ID_SCREENSHOTS, tr("Show in Screenshots", "Показывать на скриншотах"));
        append(options, MF_STRING | checked(settings.max_performance), ID_PERFORMANCE, tr("Max Performance", "Максимальная плавность"));
        append(options, MF_STRING | checked(settings.battery_saver), ID_SWITCH + 8, tr("Battery Saver", "Экономить батарею"));
        for (i, value) in OPACITIES.iter().enumerate() {
            append(opacity, MF_STRING, ID_OPACITY + i as u32, &format!("{value}%"));
        }
        let near = OPACITIES.iter().enumerate().min_by_key(|(_, v)| v.abs_diff(settings.opacity)).map_or(3, |(i, _)| i) as u32;
        let _ = CheckMenuRadioItem(opacity, ID_OPACITY, ID_OPACITY + 3, ID_OPACITY + near, MF_BYCOMMAND.0);
        append(options, MF_POPUP, opacity.0 as u32, tr("Opacity of What Falls", "Прозрачность падающего"));
        header(options, tr("— General —", "— Общие —"));
        append(options, MF_POPUP, sound.0 as u32, tr("Sound", "Звук"));
        append(options, MF_STRING | checked(login), ID_LOGIN, tr("Open at Login", "Открывать при входе"));
        append(options, MF_STRING | checked(settings.auto_update), ID_AUTO_UPDATE, tr("Update Automatically", "Обновлять автоматически"));
        append(options, MF_STRING | checked(settings.hotkeys), ID_HOTKEYS, tr("Hotkeys Ctrl+Alt+Letter", "Горячие клавиши Ctrl+Alt+буква"));

        append(menu, MF_POPUP, snowfall.0 as u32, tr("Intensity", "Интенсивность"));
        append(menu, MF_POPUP, modes.0 as u32, tr("Mode", "Режим"));
        append(menu, MF_STRING | enabled(piles), ID_CLEAR, pick(tr("Clear Snow", "Смести весь снег"), tr("Clear Leaves", "Смести все листья")));
        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
        header(menu, &countdown());
        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
        append(menu, MF_POPUP, options.0 as u32, tr("Settings", "Настройки"));
        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
        let updates = match (&pending, updating) {
            (_, true) => tr("Updating…", "Обновление…").to_string(),
            (Some(version), _) => if russian() { format!("Обновить до {version}") } else { format!("Update to {version}") },
            (None, _) => tr("Check for Updates…", "Проверить обновления…").to_string(),
        };
        append(menu, MF_STRING | enabled(!updating), ID_UPDATES, &updates);
        append(menu, MF_STRING, ID_HELP, tr("How to Use…", "Как пользоваться…"));
        append(menu, MF_STRING, ID_WHATS_NEW, tr("What's New", "Что нового"));
        append(menu, MF_STRING, ID_REPORT, tr("Report a Problem…", "Сообщить о проблеме…"));
        let about = if russian() { format!("Snowpuff {} на GitHub", update::VERSION) } else { format!("Snowpuff {} on GitHub", update::VERSION) };
        append(menu, MF_STRING, ID_ABOUT, &about);
        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
        append(menu, MF_STRING, ID_DONATE, tr("Support the Author ♥", "Поддержать автора ♥"));
        append(menu, MF_STRING, ID_SITE, tr("More Apps — ehroz.pro", "Другие приложения — ehroz.pro"));
        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
        append(menu, MF_STRING, ID_QUIT, tr("Quit Snowpuff", "Выйти из Snowpuff"));

        // A tray menu only closes on an outside click while its owner is in the foreground.
        let _ = SetForegroundWindow(window);
        let chosen = TrackPopupMenuEx(menu, (TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY).0, x, y, window, None).0 as u32;
        let _ = PostMessageW(Some(window), WM_NULL, WPARAM(0), LPARAM(0));
        let _ = DestroyMenu(menu);
        chosen
    };
    choose(window, chosen, login);
}

fn weather_index(weather: Weather) -> u32 {
    match weather {
        Weather::Snow => 0,
        Weather::Leaves => 1,
        Weather::Petals => 2,
        Weather::Rain => 3,
        Weather::Hail => 4,
    }
}

/// Tells the snow thread the settings changed in ways that only refresh what it shows, and saves them.
fn refresh(app: &mut App) {
    app.settings.save();
    send(app, Command::Refresh(app.effective()));
    refresh_sound(app);
}

fn choose(window: HWND, chosen: u32, login: bool) {
    match chosen {
        0 => {}
        ID_QUIT => quit(window),
        ID_WHATS_NEW => whats_new::show(),
        ID_HELP => whats_new::show_help(),
        ID_HOTKEYS => APP.with_borrow_mut(|app| {
            let Some(app) = app else { return };
            app.settings.hotkeys = !app.settings.hotkeys;
            app.settings.save();
            if app.settings.hotkeys {
                register_hotkeys(window);
            } else {
                unregister_hotkeys(window);
            }
        }),
        ID_REPORT => update::open(&update::report_link()),
        ID_UPDATES => {
            let pending = APP.with_borrow(|app| app.as_ref().and_then(|app| app.update.clone()));
            match pending {
                Some(release) => install_update(window, release, true),
                None => check_for_updates(window, true),
            }
        }
        ID_AUTO_UPDATE => APP.with_borrow_mut(|app| {
            let Some(app) = app else { return };
            app.settings.auto_update = !app.settings.auto_update;
            app.settings.save();
        }),
        ID_ABOUT => update::open(&format!("https://github.com/{}", update::REPOSITORY)),
        ID_DONATE => update::open(DONATE),
        ID_SITE => update::open(SITE),
        ID_CLEAR => APP.with_borrow(|app| {
            if let Some(app) = app {
                send(app, Command::ClearSnow(!prefs::animations_enabled()));
            }
        }),
        ID_LOGIN => {
            let status = prefs::set_opens_at_login(!login);
            log!("open at login {}: {status:?}", !login);
            // The settings file remembers it, for a reinstall.
            APP.with_borrow(|app| {
                if let Some(app) = app {
                    app.settings.save();
                }
            });
        }
        ID_PUFF => APP.with_borrow_mut(|app| {
            let Some(app) = app else { return };
            app.settings.puff = !app.settings.puff;
            app.settings.save();
            app.ear = app.settings.puff.then(|| open_ear(app, window));
        }),
        ID_QUIET => APP.with_borrow_mut(|app| {
            let Some(app) = app else { return };
            app.settings.quiet_on_calls = !app.settings.quiet_on_calls;
            app.settings.save();
            unsafe {
                if app.settings.quiet_on_calls {
                    SetTimer(Some(window), TIMER_CALLS, 2000, None);
                } else {
                    let _ = KillTimer(Some(window), TIMER_CALLS);
                }
            }
            if !app.settings.quiet_on_calls && app.hushed {
                set_hushed(app, false, window);
            }
        }),
        ID_LIVE => APP.with_borrow_mut(|app| {
            let Some(app) = app else { return };
            app.settings.live_weather = !app.settings.live_weather;
            app.settings.save();
            if app.settings.live_weather {
                weather::look_outside(window);
                unsafe { SetTimer(Some(window), TIMER_WEATHER, 30 * 60 * 1000, None) };
            } else {
                unsafe {
                    let _ = KillTimer(Some(window), TIMER_WEATHER);
                }
                app.live = None;
                app.outside = None;
                let effective = app.effective();
                send(app, Command::SetWeather { weather: weather_index(snow::weather(&effective)) as u8, calm: !prefs::animations_enabled() });
                send(app, Command::Refresh(effective));
            }
        }),
        _ if (ID_WEATHER..ID_WEATHER + 5).contains(&chosen) => APP.with_borrow_mut(|app| {
            let Some(app) = app else { return };
            let index = chosen - ID_WEATHER;
            let settings = &mut app.settings;
            settings.autumn = index == 1 || index == 2;
            settings.petals = index == 2;
            settings.rain = index == 3;
            settings.hail = index == 4;
            settings.save();
            send(app, Command::SetWeather { weather: index as u8, calm: !prefs::animations_enabled() });
            refresh_sound(app);
            refresh_icon(window, app);
        }),
        _ if (ID_SWITCH..ID_SWITCH + SWITCHES.len() as u32).contains(&chosen) => APP.with_borrow_mut(|app| {
            let Some(app) = app else { return };
            (SWITCHES[(chosen - ID_SWITCH) as usize].flip)(&mut app.settings);
            unsafe {
                if app.settings.words {
                    SetTimer(Some(window), TIMER_WORDS, 33, None);
                } else {
                    let _ = KillTimer(Some(window), TIMER_WORDS);
                }
            }
            refresh(app);
        }),
        ID_MIX_RAIN => APP.with_borrow_mut(|app| {
            let Some(app) = app else { return };
            app.settings.mix_rain = !app.settings.mix_rain;
            refresh(app);
        }),
        _ if (ID_OPACITY..ID_OPACITY + 4).contains(&chosen) => APP.with_borrow_mut(|app| {
            let Some(app) = app else { return };
            app.settings.opacity = OPACITIES[(chosen - ID_OPACITY) as usize];
            refresh(app);
        }),
        _ if (ID_SOUND..ID_SOUND + 4).contains(&chosen) || (ID_VOLUME..ID_VOLUME + 4).contains(&chosen) => APP.with_borrow_mut(|app| {
            let Some(app) = app else { return };
            if chosen >= ID_VOLUME {
                app.settings.volume = VOLUMES[(chosen - ID_VOLUME) as usize];
            } else {
                app.settings.ambience = chosen - ID_SOUND;
            }
            app.settings.save();
            refresh_sound(app);
        }),
        _ => APP.with_borrow_mut(|app| {
            let Some(app) = app else { return };
            let settings = &mut app.settings;
            let command = match chosen {
                ID_ACCUMULATE => {
                    settings.accumulate = !settings.accumulate;
                    Command::Accumulate(settings.accumulate)
                }
                ID_MELT => {
                    settings.melt = !settings.melt;
                    Command::Melt(settings.melt)
                }
                ID_WINDOWS => {
                    settings.snow_on_windows = !settings.snow_on_windows;
                    Command::SnowOnWindows(settings.snow_on_windows)
                }
                ID_ICICLES => {
                    settings.icicles = !settings.icicles;
                    Command::Icicles(settings.icicles)
                }
                ID_GLOW => {
                    settings.warm_glow = !settings.warm_glow;
                    Command::WarmGlow(settings.warm_glow)
                }
                ID_BEHIND => {
                    settings.behind_windows = !settings.behind_windows;
                    Command::BehindWindows(settings.behind_windows)
                }
                ID_TASKBAR => {
                    settings.behind_taskbar = !settings.behind_taskbar;
                    Command::BehindTaskbar(settings.behind_taskbar)
                }
                ID_PERFORMANCE => {
                    settings.max_performance = !settings.max_performance;
                    Command::MaxPerformance(settings.max_performance)
                }
                ID_OVER_FULL_SCREEN => {
                    settings.over_full_screen = !settings.over_full_screen;
                    Command::OverFullScreen(settings.over_full_screen)
                }
                ID_SCREENSHOTS => {
                    settings.show_in_screenshots = !settings.show_in_screenshots;
                    Command::ShowInScreenshots(settings.show_in_screenshots)
                }
                _ => {
                    let Some(&snowfall) = Snowfall::ALL.get(chosen.wrapping_sub(ID_SNOWFALL) as usize) else { return };
                    settings.snowfall = snowfall;
                    Command::Snowfall(snowfall)
                }
            };
            settings.save();
            send(app, command);
            refresh_sound(app);
            refresh_icon(window, app);
        }),
    }
}

/// Looks for a new version on another thread and reports back with `WM_UPDATE`. `asked` is a check from the menu,
/// which answers even when there's nothing new.
fn check_for_updates(window: HWND, asked: bool) {
    let busy = APP.with_borrow_mut(|app| {
        let Some(app) = app else { return true };
        std::mem::replace(&mut app.updating, true)
    });
    if busy {
        return;
    }
    let target = window.0 as isize;
    thread::spawn(move || post_update(target, asked, Updated::Checked(update::check())));
}

/// Downloads and starts the installer on another thread; it closes this app and opens the new version.
fn install_update(window: HWND, release: Release, asked: bool) {
    APP.with_borrow_mut(|app| {
        if let Some(app) = app {
            app.updating = true;
        }
    });
    log!("installing {}", release.version);
    let target = window.0 as isize;
    thread::spawn(move || {
        if let Err(error) = update::install(&release) {
            post_update(target, asked, Updated::Failed(error));
        }
    });
}

fn post_update(target: isize, asked: bool, result: Updated) {
    let result = Box::new(result);
    unsafe {
        let _ = PostMessageW(Some(HWND(target as _)), WM_UPDATE, WPARAM(asked as usize), LPARAM(Box::into_raw(result) as isize));
    }
}

fn updated(window: HWND, result: Updated, asked: bool) {
    let Some((automatic, hushed)) = APP.with_borrow_mut(|app| {
        let app = app.as_mut()?;
        app.updating = false;
        Some((app.settings.auto_update, app.hushed))
    }) else {
        return;
    };
    match result {
        Updated::Checked(Ok(Some(release))) => {
            log!("update available: {}", release.version);
            if asked {
                let question = if russian() {
                    format!("Вышел Snowpuff {}. У тебя {}.\n\nОбновить сейчас? Snowpuff перезапустится через пару секунд.", release.version, update::VERSION)
                } else {
                    format!("Snowpuff {} is out. You have {}.\n\nUpdate now? Snowpuff restarts in a couple of seconds.", release.version, update::VERSION)
                };
                if message_box(window, &question, MB_YESNO | MB_ICONQUESTION) == IDYES {
                    install_update(window, release, true);
                    return;
                }
            } else if automatic && !hushed {
                // A quiet moment: not in the middle of a call.
                install_update(window, release, false);
                return;
            }
            APP.with_borrow_mut(|app| {
                if let Some(app) = app {
                    app.update = Some(release);
                }
            });
        }
        Updated::Checked(Ok(None)) => {
            if asked {
                let text = if russian() {
                    format!("У тебя последняя версия Snowpuff — {}.", update::VERSION)
                } else {
                    format!("Snowpuff {} is the latest version.", update::VERSION)
                };
                message_box(window, &text, MB_OK | MB_ICONINFORMATION);
            }
        }
        Updated::Checked(Err(error)) | Updated::Failed(error) => {
            log!("update failed: {error}");
            if asked {
                let text = if russian() { format!("Не получилось обновить Snowpuff.\n\n{error}") } else { format!("Couldn't update Snowpuff.\n\n{error}") };
                message_box(window, &text, MB_OK | MB_ICONWARNING);
            }
        }
    }
}

fn message_box(window: HWND, text: &str, style: MESSAGEBOX_STYLE) -> MESSAGEBOX_RESULT {
    let text: Vec<u16> = text.encode_utf16().chain([0]).collect();
    unsafe { MessageBoxW(Some(window), PCWSTR(text.as_ptr()), w!("Snowpuff"), style | MB_SETFOREGROUND | MB_TOPMOST) }
}

fn quit(window: HWND) {
    remove_tray_icon(window);
    if let Some(mut app) = APP.with_borrow_mut(Option::take) {
        send(&app, Command::Quit);
        if let Some(snow) = app.snow.take() {
            let _ = snow.join();
        }
        unsafe {
            let _ = DestroyIcon(app.icon);
        }
    }
    unsafe { PostQuitMessage(0) };
}

/// Whether the taskbar is light, as Windows sets it under Personalization → Colors.
fn light_taskbar() -> bool {
    let mut value = 0u32;
    let mut size = 4u32;
    let status = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            w!("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
            w!("SystemUsesLightTheme"),
            RRF_RT_REG_DWORD,
            None,
            Some((&raw mut value).cast()),
            Some(&mut size),
        )
    };
    status.is_ok() && value != 0
}

/// The tray's mark at its size for the display's scale, dark on a light taskbar and light on a dark one, and paused
/// while the snowfall is off; the app icon if it can't be had.
fn tray_icon(paused: bool) -> HICON {
    let group = match (light_taskbar(), paused) {
        (true, false) => 2,
        (true, true) => 3,
        (false, false) => 4,
        (false, true) => 5,
    };
    unsafe {
        let size = GetSystemMetricsForDpi(SM_CXSMICON, GetDpiForSystem());
        let Ok(instance) = GetModuleHandleW(None) else { return HICON::default() };
        [group, 1]
            .iter()
            .find_map(|&id| LoadImageW(Some(instance.into()), PCWSTR(id as *const u16), IMAGE_ICON, size, size, LR_DEFAULTCOLOR).ok())
            .map_or(HICON::default(), |icon| HICON(icon.0))
    }
}

/// Puts the right mark in the tray: paused while the snowfall is off or a call is on, and matching the taskbar.
fn refresh_icon(window: HWND, app: &mut App) {
    let icon = tray_icon(app.settings.snowfall == Snowfall::Off || app.hushed);
    let data = NOTIFYICONDATAW { cbSize: size_of::<NOTIFYICONDATAW>() as u32, hWnd: window, uID: 1, uFlags: NIF_ICON, hIcon: icon, ..Default::default() };
    unsafe {
        let _ = Shell_NotifyIconW(NIM_MODIFY, &data);
        let _ = DestroyIcon(app.icon);
    }
    app.icon = icon;
}

fn add_tray_icon(window: HWND, icon: HICON) {
    let mut data = NOTIFYICONDATAW {
        cbSize: size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: window,
        uID: 1,
        uFlags: NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP,
        uCallbackMessage: WM_TRAY,
        hIcon: icon,
        ..Default::default()
    };
    let tip = tr("Snowpuff — Ctrl+Alt+H: how to use", "Snowpuff — Ctrl+Alt+H: как пользоваться");
    for (slot, unit) in data.szTip.iter_mut().take(127).zip(tip.encode_utf16()) {
        *slot = unit;
    }
    unsafe {
        let _ = Shell_NotifyIconW(NIM_DELETE, &data);
        let _ = Shell_NotifyIconW(NIM_ADD, &data);
        data.Anonymous.uVersion = NOTIFYICON_VERSION_4;
        let _ = Shell_NotifyIconW(NIM_SETVERSION, &data);
    }
}

fn remove_tray_icon(window: HWND) {
    let data = NOTIFYICONDATAW { cbSize: size_of::<NOTIFYICONDATAW>() as u32, hWnd: window, uID: 1, ..Default::default() };
    unsafe {
        let _ = Shell_NotifyIconW(NIM_DELETE, &data);
    }
}
