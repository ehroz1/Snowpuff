//! Snowpuff-Setup.exe: the app with an installer in the style of snowpuff.ehroz.pro. A short look at what the snow
//! does, a page of settings, then the install, all on one card.
//! `--silent` (or `/S`) installs without showing anything, for package managers; `--update`, which the app runs
//! when it updates itself, also opens the app again.

#![windows_subsystem = "windows"]

use std::cell::RefCell;
use std::os::windows::process::CommandExt;
use std::path::PathBuf;

use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Direct2D::Common::D2D_RECT_F;
use windows::Win32::Graphics::DirectWrite::{DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_WEIGHT_SEMI_BOLD};
use windows::Win32::System::Com::{COINIT_APARTMENTTHREADED, CoInitializeEx};
use windows::Win32::UI::Input::KeyboardAndMouse::{ReleaseCapture, SetCapture, VK_ESCAPE, VK_LEFT, VK_RETURN, VK_RIGHT};
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{PCWSTR, Result, w};

use snowpuff::card::{self, Align, Canvas, Card, GLOW, INK, LABEL, MUTED, Paint, SNOW};
use snowpuff::install;
use snowpuff::store::{self, Values};
use snowpuff::text::{russian, tr};

/// The app this installer carries, built before it.
const APP: &[u8] = include_bytes!(env!("SNOWPUFF_APP"));
const VERSION: &str = env!("CARGO_PKG_VERSION");
const CLASS: PCWSTR = w!("SnowpuffSetup");
const WIDTH: f32 = 620.0;
const HEIGHT: f32 = 470.0;
const SITE: &str = "https://ehroz.pro";
/// The look at the snow, before the settings.
const SLIDES: usize = 5;
/// Its pages and the settings, which the dots count.
const PAGES: usize = SLIDES + 1;

#[derive(Clone, PartialEq)]
enum Stage {
    /// A page of the presentation, 0 to `SLIDES - 1`, or the settings at `SLIDES`.
    Page(usize),
    Installing,
    Done(PathBuf),
    Failed(String),
}

/// What the person picks before installing. Restored from the settings file when one is left from before.
#[derive(Clone, Copy)]
struct Choices {
    /// 1 light, 2 steady, 3 heavy: the index in the app's list of snowfalls.
    snowfall: u32,
    /// 0 quiet, 1 wind, 2 fireplace.
    sound: u32,
    icicles: bool,
    quiet_on_calls: bool,
    open_at_login: bool,
    auto_update: bool,
}

impl Choices {
    fn from(saved: Option<&Values>) -> Choices {
        let get = |name: &str, default: u32| saved.and_then(|values| values.get(name).copied()).unwrap_or(default);
        Choices {
            snowfall: get("snowfall", 2).clamp(1, 3),
            sound: get("ambience", 0).min(2),
            icicles: get("icicles", 1) != 0,
            quiet_on_calls: get("quietOnCalls", 1) != 0,
            open_at_login: get("openAtLogin", 1) != 0,
            auto_update: get("autoUpdate", 1) != 0,
        }
    }
}

/// Something on the card that answers a click.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Hit {
    Primary,
    Secondary,
    Close,
    Dot(usize),
    Snowfall(u32),
    Sound(u32),
    Icicles,
    Calls,
    Login,
    Updates,
    Site,
}

struct Setup {
    window: HWND,
    card: Card,
    hits: Vec<(D2D_RECT_F, Hit)>,
    stage: Stage,
    choices: Choices,
    /// Settings left by an earlier install, if any: they are kept and only what is chosen here changes.
    saved: Option<Values>,
    installed: Option<String>,
    /// The control a press started on, while the button is held.
    holding: Option<Hit>,
}

thread_local! {
    static SETUP: RefCell<Option<Setup>> = const { RefCell::new(None) };
}

fn main() {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
    }
    // What the app runs when it updates itself: it is closed, replaced and opened again, with nothing to click.
    if std::env::args().skip(1).any(|argument| argument.eq_ignore_ascii_case("--update")) {
        let installed = install::install(APP, VERSION);
        // Whatever happened, the snow comes back: the new version, or the old one if it couldn't be replaced.
        if let Some(exe) = installed.as_ref().ok().cloned().or_else(install::installed_exe) {
            install::launch(&exe);
        }
        // The downloaded installer has done its job.
        if let Ok(me) = std::env::current_exe()
            && me.starts_with(std::env::temp_dir())
        {
            let _ = std::process::Command::new("cmd.exe")
                .raw_arg(format!("/c ping 127.0.0.1 -n 3 >nul & del /q \"{}\"", me.display()))
                .creation_flags(0x0800_0000)
                .spawn();
        }
        std::process::exit(if installed.is_ok() { 0 } else { 1 });
    }
    if std::env::args().skip(1).any(|argument| argument.eq_ignore_ascii_case("--silent") || argument.eq_ignore_ascii_case("/s")) {
        std::process::exit(if install::install(APP, VERSION).is_ok() { 0 } else { 1 });
    }
    if open().is_err() {
        // Without the card, fall back to installing and opening the app, which is what the card would lead to.
        if let Ok(exe) = install::install(APP, VERSION) {
            install::launch(&exe);
        }
        return;
    }
    unsafe {
        let mut message = MSG::default();
        while GetMessageW(&mut message, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
}

fn open() -> Result<()> {
    card::register(CLASS, Some(procedure))?;
    let (scale, origin) = card::placement(WIDTH, HEIGHT);
    let card = Card::new(WIDTH, HEIGHT, scale)?;
    let saved = store::read();
    let mut setup = Setup {
        window: HWND::default(),
        card,
        hits: Vec::new(),
        stage: Stage::Page(0),
        choices: Choices::from(saved.as_ref()),
        saved,
        installed: install::installed_version(),
        holding: None,
    };
    let pixels = setup.paint()?;
    unsafe {
        let window = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_APPWINDOW,
            CLASS,
            w!("Snowpuff Setup"),
            WS_POPUP | WS_SYSMENU | WS_MINIMIZEBOX,
            origin.x,
            origin.y,
            setup.card.size.0,
            setup.card.size.1,
            None,
            None,
            None,
            None,
        )?;
        card::present(window, setup.card.size, &pixels, Some(origin));
        setup.window = window;
        SETUP.set(Some(setup));
        let _ = ShowWindow(window, SW_SHOW);
        let _ = SetForegroundWindow(window);
    }
    Ok(())
}

// MARK: - Drawing

const QUIET: Paint = (MUTED, 0.72);
const FAINT: Paint = (MUTED, 0.45);

impl Setup {
    fn paint(&mut self) -> Result<Vec<u8>> {
        let (pixels, hits) = self.card.canvas(|canvas| self.draw(canvas))?;
        self.hits = hits;
        Ok(pixels)
    }

    fn draw(&self, canvas: &Canvas) -> Result<Vec<(D2D_RECT_F, Hit)>> {
        canvas.frame(16.0)?;
        let card = canvas.rect;
        let mut hits = Vec::new();
        let pressed = self.holding == Some(Hit::Primary);
        let installing = self.stage == Stage::Installing;
        let scene = D2D_RECT_F { left: card.left + 14.0, top: card.top + 14.0, right: card.right - 14.0, bottom: card.top + 250.0 };

        match &self.stage {
            Stage::Page(page) if *page < SLIDES => {
                illustration(canvas, scene, *page)?;
                let (title, body) = slide(*page);
                canvas.title(title, (card.left + 48.0, card.top + 274.0), WIDTH - 96.0, 38.0, (INK, 1.0), Align::Center)?;
                canvas.text(body, (card.left + 80.0, card.top + 326.0), WIDTH - 160.0, 14.0, DWRITE_FONT_WEIGHT_NORMAL, QUIET, Align::Center)?;
                let secondary = if *page == 0 { tr("Skip to settings", "Сразу к настройкам") } else { tr("Back", "Назад") };
                hits.push((text_button(canvas, secondary)?, Hit::Secondary));
                hits.push((primary(canvas, tr("Next", "Далее"), pressed)?, Hit::Primary));
                dots(canvas, *page, &mut hits)?;
            }
            Stage::Page(_) | Stage::Installing => {
                self.draw_settings(canvas, &mut hits)?;
                if !installing {
                    hits.push((text_button(canvas, tr("Back", "Назад"))?, Hit::Secondary));
                }
                let label = if installing { tr("Installing…", "Установка…") } else { self.install_label() };
                hits.push((primary(canvas, label, pressed || installing)?, Hit::Primary));
                dots(canvas, SLIDES, &mut hits)?;
            }
            Stage::Done(_) => {
                illustration(canvas, scene, SLIDES)?;
                canvas.title(tr("Let it settle.", "Пусть ложится."), (card.left + 48.0, card.top + 274.0), WIDTH - 96.0, 38.0, (INK, 1.0), Align::Center)?;
                canvas.text(
                    tr(
                        "Snowpuff is installed and already in the tray. It's in the Start menu too; everything chosen here can be changed from its icon.",
                        "Snowpuff установлен и уже в трее. Он есть и в меню «Пуск»; всё выбранное меняется в меню его значка.",
                    ),
                    (card.left + 80.0, card.top + 326.0),
                    WIDTH - 160.0,
                    14.0,
                    DWRITE_FONT_WEIGHT_NORMAL,
                    QUIET,
                    Align::Center,
                )?;
                hits.push((text_button(canvas, tr("More apps — ehroz.pro", "Другие приложения — ehroz.pro"))?, Hit::Site));
                hits.push((primary(canvas, tr("Open Snowpuff", "Открыть Snowpuff"), pressed)?, Hit::Primary));
            }
            Stage::Failed(error) => {
                illustration(canvas, scene, 0)?;
                canvas.title(tr("Something got in the way", "Что-то помешало"), (card.left + 48.0, card.top + 274.0), WIDTH - 96.0, 34.0, (INK, 1.0), Align::Center)?;
                let body = if russian() { format!("Не удалось установить: {error}.") } else { format!("Couldn't install: {error}.") };
                canvas.text(&body, (card.left + 80.0, card.top + 326.0), WIDTH - 160.0, 14.0, DWRITE_FONT_WEIGHT_NORMAL, QUIET, Align::Center)?;
                hits.push((text_button(canvas, tr("Back", "Назад"))?, Hit::Secondary));
                hits.push((primary(canvas, tr("Try again", "Ещё раз"), pressed)?, Hit::Primary));
            }
        }

        if !installing {
            let (x, y, arm) = (card.right - 30.0, card.top + 30.0, 5.5);
            let on_picture = !matches!(self.stage, Stage::Page(page) if page == SLIDES);
            let paint = if on_picture { (SNOW, 0.75) } else { QUIET };
            canvas.line((x - arm, y - arm), (x + arm, y + arm), paint, 1.4)?;
            canvas.line((x - arm, y + arm), (x + arm, y - arm), paint, 1.4)?;
            hits.push((D2D_RECT_F { left: x - 16.0, top: y - 16.0, right: x + 16.0, bottom: y + 16.0 }, Hit::Close));
        }
        Ok(hits)
    }

    fn install_label(&self) -> &'static str {
        match &self.installed {
            None => tr("Install", "Установить"),
            Some(old) if snowpuff_core::version::newer(VERSION, old) => tr("Update", "Обновить"),
            Some(_) => tr("Reinstall", "Переустановить"),
        }
    }

    fn draw_settings(&self, canvas: &Canvas, hits: &mut Vec<(D2D_RECT_F, Hit)>) -> Result<()> {
        let card = canvas.rect;
        let left = card.left + 48.0;
        let right = card.right - 48.0;
        canvas.title(tr("Make it yours", "Настроим под тебя"), (left, card.top + 40.0), WIDTH - 96.0, 36.0, (INK, 1.0), Align::Left)?;
        let note = if self.saved.is_some() {
            tr("Your settings from the last install were found and are already here.", "Нашлись настройки прошлой установки — они уже здесь.")
        } else {
            tr("All of it can be changed later from the tray icon.", "Всё это можно поменять потом в меню значка в трее.")
        };
        let note_paint = if self.saved.is_some() { (GLOW, 0.9) } else { QUIET };
        canvas.text(note, (left, card.top + 86.0), WIDTH - 96.0, 13.0, DWRITE_FONT_WEIGHT_NORMAL, note_paint, Align::Left)?;

        let mut y = card.top + 122.0;
        let row = 44.0;
        let label = |text: &str, y: f32| canvas.text(text, (left, y + 11.0), 280.0, 14.0, DWRITE_FONT_WEIGHT_NORMAL, (INK, 0.95), Align::Left);
        let rule = |y: f32| canvas.line((left, y), (right, y), ([1.0; 3], 0.07), 1.0);

        label(tr("Snowfall", "Снегопад"), y)?;
        let options = [tr("Light", "Лёгкий"), tr("Steady", "Ровный"), tr("Heavy", "Метель")];
        for (i, rect) in segments(canvas, &options, (self.choices.snowfall - 1) as usize, right, y + 7.0)?.into_iter().enumerate() {
            hits.push((rect, Hit::Snowfall(i as u32 + 1)));
        }
        y += row;
        rule(y)?;
        label(tr("Sound", "Звук"), y)?;
        let options = [tr("Quiet", "Тихо"), tr("Wind", "Ветер"), tr("Fireplace", "Камин")];
        for (i, rect) in segments(canvas, &options, self.choices.sound as usize, right, y + 7.0)?.into_iter().enumerate() {
            hits.push((rect, Hit::Sound(i as u32)));
        }
        for (text, on, hit) in [
            (tr("Icicles under windows with snow", "Сосульки под окнами со снегом"), self.choices.icicles, Hit::Icicles),
            (tr("Hide during calls", "Прятать на созвонах"), self.choices.quiet_on_calls, Hit::Calls),
            (tr("Open when Windows starts", "Запускать вместе с Windows"), self.choices.open_at_login, Hit::Login),
            (tr("Update automatically", "Обновляться автоматически"), self.choices.auto_update, Hit::Updates),
        ] {
            y += row;
            rule(y)?;
            label(text, y)?;
            toggle(canvas, on, right, y + 11.0)?;
            // The whole row answers, not only the switch.
            hits.push((D2D_RECT_F { left, top: y, right, bottom: y + row }, hit));
        }
        Ok(())
    }
}

/// The title and text of a page of the presentation.
fn slide(page: usize) -> (&'static str, &'static str) {
    match page {
        0 => (
            "Snowpuff",
            tr(
                "Warm snow on your desktop. A quick look at what it does, a few settings, and it's falling in a minute.",
                "Тёплый снег на рабочем столе. Покажем, что он умеет, настроим — и через минуту он пойдёт.",
            ),
        ),
        1 => (
            tr("It settles on windows", "Ложится на окна"),
            tr(
                "Snow gathers on the edges of windows and on the taskbar. Give a window a shake and it slides off.",
                "Снег оседает на краях окон и на панели задач. Дёрни окно — и он соскользнёт вниз.",
            ),
        ),
        2 => (
            tr("It scatters from the cursor", "Разлетается от курсора"),
            tr(
                "Sweep the mouse through a drift and it parts. Five kinds of snowfall, from light to a blizzard, plus rain and leaves.",
                "Проведи мышкой по сугробу — снег расступится. Пять видов снегопада, от лёгкого до метели, а ещё дождь и листья.",
            ),
        ),
        3 => (
            tr("Icicles and warm light", "Сосульки и тёплый свет"),
            tr(
                "Icicles grow under windows with snow on them, and the active window glows warm onto the snow, like the one on the icon.",
                "Под окнами со снегом растут сосульки, а активное окно светится тёплым светом, как окно на иконке.",
            ),
        ),
        _ => (
            tr("It listens, and steps aside", "Слушает и не мешает"),
            tr(
                "Blow into the microphone and the snow flies; nothing is recorded. On calls, in full-screen games and on battery it keeps out of the way.",
                "Подуй в микрофон — снег разлетится, ничего не записывается. На созвонах, в играх и на батарее он не мешает.",
            ),
        ),
    }
}

/// The amber button at the bottom right.
fn primary(canvas: &Canvas, label: &str, pressed: bool) -> Result<D2D_RECT_F> {
    let card = canvas.rect;
    let rect = D2D_RECT_F { left: card.right - 28.0 - 168.0, top: card.bottom - 66.0, right: card.right - 28.0, bottom: card.bottom - 26.0 };
    let fill = if pressed { GLOW.map(|c| c * 0.86) } else { GLOW };
    canvas.fill_round(rect, 6.0, (fill, 1.0))?;
    canvas.text(label, (rect.left, rect.top + 9.0), rect.right - rect.left, 14.0, DWRITE_FONT_WEIGHT_SEMI_BOLD, (LABEL, 1.0), Align::Center)?;
    Ok(rect)
}

/// A quiet text button at the bottom left.
fn text_button(canvas: &Canvas, label: &str) -> Result<D2D_RECT_F> {
    let card = canvas.rect;
    let (left, top) = (card.left + 28.0, card.bottom - 66.0);
    let width = 300.0;
    canvas.text(label, (left + 4.0, top + 10.0), width, 13.5, DWRITE_FONT_WEIGHT_NORMAL, QUIET, Align::Left)?;
    Ok(D2D_RECT_F { left, top, right: left + 200.0, bottom: top + 40.0 })
}

/// Which page this is, as dots between the buttons; each dot jumps to its page.
fn dots(canvas: &Canvas, current: usize, hits: &mut Vec<(D2D_RECT_F, Hit)>) -> Result<()> {
    let card = canvas.rect;
    let y = card.bottom - 46.0;
    let gap = 16.0;
    let start = (card.left + card.right) / 2.0 - gap * (PAGES - 1) as f32 / 2.0;
    for page in 0..PAGES {
        let x = start + gap * page as f32;
        if page == current {
            canvas.fill_round(D2D_RECT_F { left: x - 8.0, top: y - 3.0, right: x + 8.0, bottom: y + 3.0 }, 3.0, (GLOW, 1.0))?;
        } else {
            canvas.ellipse((x, y), (3.0, 3.0), FAINT)?;
        }
        hits.push((D2D_RECT_F { left: x - 8.0, top: y - 10.0, right: x + 8.0, bottom: y + 10.0 }, Hit::Dot(page)));
    }
    Ok(())
}

/// A row of choices, right-aligned at `right`; returns where each one is.
fn segments(canvas: &Canvas, options: &[&str], chosen: usize, right: f32, top: f32) -> Result<Vec<D2D_RECT_F>> {
    let width = 92.0;
    let height = 30.0;
    let left = right - width * options.len() as f32;
    canvas.stroke_round(D2D_RECT_F { left, top, right, bottom: top + height }, 6.0, ([1.0; 3], 0.16), 1.0)?;
    let mut rects = Vec::new();
    for (i, option) in options.iter().enumerate() {
        let rect = D2D_RECT_F { left: left + width * i as f32, top, right: left + width * (i + 1) as f32, bottom: top + height };
        let paint = if i == chosen {
            let inner = D2D_RECT_F { left: rect.left + 2.0, top: rect.top + 2.0, right: rect.right - 2.0, bottom: rect.bottom - 2.0 };
            canvas.fill_round(inner, 4.5, (GLOW, 1.0))?;
            (LABEL, 1.0)
        } else {
            (INK, 0.8)
        };
        let weight = if i == chosen { DWRITE_FONT_WEIGHT_SEMI_BOLD } else { DWRITE_FONT_WEIGHT_NORMAL };
        canvas.text(option, (rect.left, rect.top + 6.0), width, 13.0, weight, paint, Align::Center)?;
        rects.push(rect);
    }
    Ok(rects)
}

/// An on/off switch whose right edge is at `right`.
fn toggle(canvas: &Canvas, on: bool, right: f32, top: f32) -> Result<()> {
    let rect = D2D_RECT_F { left: right - 40.0, top, right, bottom: top + 22.0 };
    canvas.fill_round(rect, 11.0, if on { (GLOW, 1.0) } else { ([1.0; 3], 0.16) })?;
    let x = if on { rect.right - 11.0 } else { rect.left + 11.0 };
    canvas.ellipse((x, top + 11.0), (8.0, 8.0), if on { (LABEL, 1.0) } else { (SNOW, 0.9) })
}

// MARK: - Illustrations

const FRAME: [f32; 3] = [0.09, 0.043, 0.027];
const CURTAIN: [f32; 3] = [0.612, 0.227, 0.157];
const CAT: [f32; 3] = [0.227, 0.106, 0.063];
const LAMP: [f32; 3] = [0.42, 0.18, 0.11];

/// The night outside, the same on every page: sky, falling snow and a snowbank, with the page's own picture on it.
fn illustration(canvas: &Canvas, area: D2D_RECT_F, page: usize) -> Result<()> {
    canvas.clipped(area, || scene(canvas, area, page))
}

fn scene(canvas: &Canvas, area: D2D_RECT_F, page: usize) -> Result<()> {
    canvas.fill_round_vertical(area, 10.0, &[(0.0, ([0.043, 0.063, 0.09], 1.0)), (1.0, ([0.11, 0.165, 0.243], 1.0))])?;
    let width = area.right - area.left;
    let height = area.bottom - area.top;
    let center = area.left + width / 2.0;
    let ground = area.bottom - 38.0;

    if page != 2 {
        canvas.glow((center, area.top + height * 0.42), (width * 0.42, height * 0.62), &[(0.0, (GLOW, 0.28)), (1.0, (GLOW, 0.0))])?;
    }
    // Snowflakes at fixed places, so every page has the same weather.
    for i in 0..46u32 {
        let x = area.left + 8.0 + hash(i, 1) * (width - 16.0);
        let y = area.top + 8.0 + hash(i, 2) * (ground - area.top - 12.0);
        let r = 0.8 + hash(i, 3) * 1.6;
        canvas.ellipse((x, y), (r, r), (SNOW, 0.35 + hash(i, 4) * 0.5))?;
    }

    match page {
        0 => lit_window(canvas, center, area.top + 40.0, 132.0, Cat::Sitting, false)?,
        1 => desktop_window(canvas, center, area.top + 52.0)?,
        2 => {}
        3 => lit_window(canvas, center, area.top + 38.0, 132.0, Cat::None, true)?,
        4 => microphone(canvas, center, area.top + 44.0)?,
        _ => lit_window(canvas, center, area.top + 40.0, 132.0, Cat::Sleeping, false)?,
    }

    // The snowbank along the bottom, with a bright rim.
    let mut bank = vec![(area.left, area.bottom), (area.left, ground)];
    let steps = 40;
    for i in 0..=steps {
        let t = i as f32 / steps as f32;
        let x = area.left + t * width;
        let mut y = ground - 4.0 * (t * 9.0).sin() - 3.0 * (t * 23.0 + 1.3).sin();
        if page == 2 {
            // A dip where the cursor went through.
            let d = (x - (center + 40.0)) / 46.0;
            y += 18.0 * (-d * d).exp();
        }
        bank.push((x, y));
    }
    bank.push((area.right, area.bottom));
    canvas.polygon(&bank, ([0.86, 0.9, 0.95], 1.0))?;
    let rim: Vec<(f32, f32)> = bank[2..bank.len() - 1].iter().map(|&(x, y)| (x, y + 2.0)).collect();
    let mut highlight = rim.clone();
    highlight.extend(rim.iter().rev().map(|&(x, y)| (x, y - 2.6)));
    canvas.polygon(&highlight, (SNOW, 1.0))?;
    if page != 2 {
        canvas.glow((center, ground + 10.0), (width * 0.3, 16.0), &[(0.0, (GLOW, 0.5)), (1.0, (GLOW, 0.0))])?;
    }

    if page == 2 {
        // The cursor, and the snow it threw up.
        let (x, y) = (center + 40.0, ground - 6.0);
        for i in 0..22u32 {
            let angle = -0.3 - hash(i, 7) * 2.5;
            let reach = 20.0 + hash(i, 8) * 70.0;
            let r = 1.0 + hash(i, 9) * 2.0;
            canvas.ellipse((x + angle.cos() * reach, y + angle.sin() * reach * 0.8), (r, r), (SNOW, 0.9))?;
        }
        let arrow = [(0.0, 0.0), (0.0, 26.0), (7.0, 20.0), (12.0, 31.0), (16.5, 29.0), (11.5, 18.5), (20.0, 18.5)];
        let tip = (x - 2.0, y - 30.0);
        let outline: Vec<(f32, f32)> = arrow.iter().map(|&(ax, ay)| (tip.0 + ax * 1.15 - 1.2, tip.1 + ay * 1.15 - 1.2)).collect();
        canvas.polygon(&outline, ([0.05, 0.07, 0.1], 1.0))?;
        let fill: Vec<(f32, f32)> = arrow.iter().map(|&(ax, ay)| (tip.0 + ax, tip.1 + ay)).collect();
        canvas.polygon(&fill, (SNOW, 1.0))?;
    }
    Ok(())
}

#[derive(PartialEq)]
enum Cat {
    None,
    Sitting,
    Sleeping,
}

/// The window from the icon: warm glass, curtains with stitched hems, a lamp, a cap of snow and a snowy sill,
/// with icicles if asked.
fn lit_window(canvas: &Canvas, center: f32, top: f32, width: f32, cat: Cat, icicles: bool) -> Result<()> {
    let height = width * 0.96;
    let left = center - width / 2.0;
    let glass = D2D_RECT_F { left, top, right: left + width, bottom: top + height };
    canvas.fill_round(glass, 9.0, (FRAME, 1.0))?;
    let pane = D2D_RECT_F { left: left + 8.0, top: top + 8.0, right: glass.right - 8.0, bottom: glass.bottom - 8.0 };
    canvas.fill_round(pane, 4.0, ([0.85, 0.5, 0.23], 1.0))?;
    canvas.glow(
        (center + width * 0.08, pane.bottom - height * 0.2),
        (width * 0.55, height * 0.7),
        &[(0.0, ([1.0, 0.96, 0.84], 1.0)), (0.55, ([1.0, 0.81, 0.48], 1.0)), (1.0, ([0.85, 0.5, 0.23], 0.0))],
    )?;
    let curtain = width * 0.22;
    canvas.polygon(
        &[(pane.left, pane.top), (pane.left + curtain, pane.top), (pane.left + curtain * 0.7, pane.bottom), (pane.left, pane.bottom)],
        (CURTAIN, 1.0),
    )?;
    canvas.polygon(
        &[(pane.right, pane.top), (pane.right - curtain, pane.top), (pane.right - curtain * 0.7, pane.bottom), (pane.right, pane.bottom)],
        (CURTAIN, 1.0),
    )?;
    for side in [true, false] {
        let (x0, x1) = if side {
            (pane.left + curtain - 2.0, pane.left + curtain * 0.7 - 2.0)
        } else {
            (pane.right - curtain + 2.0, pane.right - curtain * 0.7 + 2.0)
        };
        for i in 0..14 {
            let t = i as f32 / 14.0;
            let (x, y) = (x0 + (x1 - x0) * t, pane.top + 3.0 + (pane.bottom - pane.top - 6.0) * t);
            canvas.line((x, y), (x, y + 2.5), ([1.0, 0.85, 0.63], 0.7), 0.8)?;
        }
    }
    match cat {
        Cat::Sitting => {
            let (x, y) = (pane.left + width * 0.3, pane.bottom);
            let s = width / 116.0;
            let body = [(0.0, 0.0), (-1.0, -17.0), (4.0, -23.0), (2.0, -32.0), (7.5, -27.0), (12.5, -27.0), (18.0, -32.0), (16.0, -23.0), (21.0, -17.0), (20.0, 0.0)];
            let points: Vec<(f32, f32)> = body.iter().map(|&(bx, by)| (x + bx * s, y + by * s)).collect();
            canvas.polygon(&points, (CAT, 1.0))?;
        }
        Cat::Sleeping => {
            let (x, y) = (pane.left + width * 0.32, pane.bottom - 6.0);
            canvas.ellipse((x + 8.0, y), (16.0, 8.0), (CAT, 1.0))?;
            canvas.ellipse((x - 6.0, y - 3.0), (7.0, 6.5), (CAT, 1.0))?;
            canvas.polygon(&[(x - 11.0, y - 6.0), (x - 10.0, y - 14.0), (x - 6.0, y - 8.0)], (CAT, 1.0))?;
            canvas.polygon(&[(x - 4.0, y - 8.0), (x - 0.5, y - 14.0), (x + 0.5, y - 6.0)], (CAT, 1.0))?;
        }
        Cat::None => {}
    }
    let (lx, ly) = (pane.right - width * 0.3, pane.bottom);
    canvas.glow((lx, ly - 16.0), (16.0, 12.0), &[(0.0, ([1.0, 0.97, 0.86], 0.8)), (1.0, ([1.0, 0.97, 0.86], 0.0))])?;
    canvas.polygon(&[(lx - 9.0, ly - 15.0), (lx + 9.0, ly - 15.0), (lx + 5.0, ly - 27.0), (lx - 5.0, ly - 27.0)], (LAMP, 1.0))?;
    canvas.fill_round(D2D_RECT_F { left: lx - 1.3, top: ly - 15.0, right: lx + 1.3, bottom: ly - 4.0 }, 1.0, (LAMP, 1.0))?;
    canvas.fill_round(D2D_RECT_F { left: lx - 6.0, top: ly - 4.0, right: lx + 6.0, bottom: ly }, 2.0, (LAMP, 1.0))?;
    canvas.fill_round(D2D_RECT_F { left: center - 3.5, top: pane.top, right: center + 3.5, bottom: pane.bottom }, 0.0, (FRAME, 1.0))?;
    let mid = (pane.top + pane.bottom) / 2.0 - 4.0;
    canvas.fill_round(D2D_RECT_F { left: pane.left, top: mid - 3.5, right: pane.right, bottom: mid + 3.5 }, 0.0, (FRAME, 1.0))?;

    let mut cap = vec![(left - 12.0, top + 6.0)];
    for i in 0..=16 {
        let t = i as f32 / 16.0;
        let x = left - 12.0 + t * (width + 24.0);
        let y = top - 4.0 - 7.0 * (t * std::f32::consts::PI).sin() - 2.5 * (t * 19.0).sin().abs();
        cap.push((x, y));
    }
    cap.push((left + width + 12.0, top + 6.0));
    canvas.polygon(&cap, (SNOW, 1.0))?;
    let sill = D2D_RECT_F { left: left - 12.0, top: glass.bottom - 2.0, right: glass.right + 12.0, bottom: glass.bottom + 9.0 };
    canvas.fill_round(sill, 3.0, (SNOW, 1.0))?;
    if icicles {
        let lengths = [14.0, 8.0, 26.0, 11.0, 34.0, 7.0, 20.0, 12.0, 24.0];
        for (i, length) in lengths.iter().enumerate() {
            let x = sill.left + 10.0 + i as f32 * (sill.right - sill.left - 20.0) / (lengths.len() - 1) as f32;
            canvas.polygon(&[(x - 3.5, sill.bottom - 1.0), (x + 3.5, sill.bottom - 1.0), (x, sill.bottom + length)], ([0.92, 0.95, 0.99], 0.9))?;
        }
    }
    Ok(())
}

/// A plain desktop window with snow along its top edge and a little sliding off.
fn desktop_window(canvas: &Canvas, center: f32, top: f32) -> Result<()> {
    let width = 230.0;
    let left = center - width / 2.0;
    let window = D2D_RECT_F { left, top, right: left + width, bottom: top + 116.0 };
    let bar = [0.886, 0.839, 0.765];
    canvas.fill_round(window, 9.0, ([0.937, 0.902, 0.847], 1.0))?;
    canvas.fill_round(D2D_RECT_F { left, top, right: window.right, bottom: top + 24.0 }, 9.0, (bar, 1.0))?;
    canvas.fill_round(D2D_RECT_F { left, top: top + 14.0, right: window.right, bottom: top + 24.0 }, 0.0, (bar, 1.0))?;
    for (i, rgb) in [[0.83, 0.38, 0.29], [0.89, 0.66, 0.25], [0.5, 0.68, 0.36]].iter().enumerate() {
        canvas.ellipse((left + 14.0 + i as f32 * 13.0, top + 12.0), (4.0, 4.0), (*rgb, 1.0))?;
    }
    for (i, length) in [150.0, 120.0, 170.0].iter().enumerate() {
        let y = top + 44.0 + i as f32 * 20.0;
        canvas.fill_round(D2D_RECT_F { left: left + 20.0, top: y, right: left + 20.0 + length, bottom: y + 6.0 }, 3.0, ([0.36, 0.29, 0.24], 0.35))?;
    }
    let mut cap = vec![(left + 2.0, top + 2.0)];
    for i in 0..=18 {
        let t = i as f32 / 18.0;
        let x = left + 2.0 + t * (width - 4.0);
        let y = top - 3.0 - 6.0 * (t * std::f32::consts::PI).sin().powf(0.6) - 2.0 * (t * 21.0).sin().abs();
        cap.push((x, y));
    }
    cap.push((window.right - 2.0, top + 2.0));
    canvas.polygon(&cap, (SNOW, 1.0))?;
    // A clump falling from the right corner.
    for (dx, dy, r) in [(10.0, 18.0, 3.0), (16.0, 34.0, 2.2), (8.0, 46.0, 1.8), (20.0, 58.0, 1.4)] {
        canvas.ellipse((window.right + dx, top + dy), (r, r), (SNOW, 0.95))?;
    }
    Ok(())
}

/// A microphone with a breath blowing snow away from it.
fn microphone(canvas: &Canvas, center: f32, top: f32) -> Result<()> {
    let x = center - 60.0;
    canvas.fill_round(D2D_RECT_F { left: x - 16.0, top, right: x + 16.0, bottom: top + 64.0 }, 16.0, (GLOW, 1.0))?;
    for i in 0..4 {
        let y = top + 18.0 + i as f32 * 9.0;
        canvas.line((x - 9.0, y), (x + 9.0, y), (LABEL, 0.35), 1.5)?;
    }
    let steps = 16;
    let mut previous = None;
    for i in 0..=steps {
        let angle = std::f32::consts::PI * i as f32 / steps as f32;
        let point = (x - 26.0 * angle.cos(), top + 38.0 + 26.0 * angle.sin());
        if let Some(from) = previous {
            canvas.line(from, point, (GLOW, 1.0), 3.0)?;
        }
        previous = Some(point);
    }
    canvas.line((x, top + 64.0), (x, top + 86.0), (GLOW, 1.0), 3.0)?;
    canvas.line((x - 14.0, top + 86.0), (x + 14.0, top + 86.0), (GLOW, 1.0), 3.0)?;
    for (i, (dy, length)) in [(-10.0, 70.0), (6.0, 96.0), (22.0, 62.0)].iter().enumerate() {
        let y = top + 32.0 + dy;
        canvas.line((x + 40.0, y), (x + 40.0 + length, y - 6.0 + i as f32 * 3.0), (SNOW, 0.55), 2.0)?;
    }
    for i in 0..14u32 {
        let fx = x + 120.0 + hash(i, 11) * 80.0;
        let fy = top + 10.0 + hash(i, 12) * 60.0;
        let r = 1.4 + hash(i, 13) * 2.0;
        canvas.ellipse((fx, fy), (r, r), (SNOW, 0.95))?;
    }
    Ok(())
}

/// A steady pseudo-random number in [0, 1) for `i`, different for each `salt`.
fn hash(i: u32, salt: u32) -> f32 {
    let mut x = i.wrapping_mul(0x9E37_79B9) ^ salt.wrapping_mul(0x85EB_CA6B);
    x ^= x >> 15;
    x = x.wrapping_mul(0x2C1B_3C6D);
    x ^= x >> 12;
    (x % 10_000) as f32 / 10_000.0
}

// MARK: - Events

unsafe extern "system" fn procedure(window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match message {
        WM_NCHITTEST => {
            let mut origin = RECT::default();
            unsafe {
                let _ = GetWindowRect(window, &mut origin);
            }
            let point = card::point(lparam);
            let on_control =
                SETUP.with_borrow(|setup| setup.as_ref().map(|setup| setup.hit(POINT { x: point.x - origin.left, y: point.y - origin.top }).is_some()));
            // The card drags the window anywhere but on its controls.
            LRESULT(if on_control == Some(false) { HTCAPTION as isize } else { HTCLIENT as isize })
        }
        WM_SETCURSOR => {
            unsafe {
                let mut point = POINT::default();
                let mut origin = RECT::default();
                let _ = GetCursorPos(&mut point);
                let _ = GetWindowRect(window, &mut origin);
                let on = SETUP.with_borrow(|setup| {
                    setup.as_ref().is_some_and(|setup| setup.hit(POINT { x: point.x - origin.left, y: point.y - origin.top }).is_some())
                });
                SetCursor(LoadCursorW(None, if on { IDC_HAND } else { IDC_ARROW }).ok());
            }
            LRESULT(1)
        }
        WM_LBUTTONDOWN | WM_LBUTTONUP => {
            unsafe {
                if message == WM_LBUTTONDOWN {
                    SetCapture(window);
                } else {
                    let _ = ReleaseCapture();
                }
            }
            let at = card::point(lparam);
            let clicked = SETUP.with_borrow_mut(|setup| {
                let setup = setup.as_mut()?;
                let hit = setup.hit(at);
                if message == WM_LBUTTONDOWN {
                    setup.holding = hit;
                    if hit == Some(Hit::Primary) {
                        refresh(setup);
                    }
                    None
                } else {
                    let started = setup.holding.take();
                    if started == Some(Hit::Primary) {
                        refresh(setup);
                    }
                    hit.filter(|&hit| Some(hit) == started)
                }
            });
            if let Some(hit) = clicked {
                click(hit);
            }
            LRESULT(0)
        }
        WM_KEYDOWN => {
            let key = wparam.0 as u16;
            if key == VK_RETURN.0 {
                click(Hit::Primary);
            } else if key == VK_ESCAPE.0 {
                close();
            } else if key == VK_RIGHT.0 {
                turn(1);
            } else if key == VK_LEFT.0 {
                turn(-1);
            }
            LRESULT(0)
        }
        WM_CLOSE => {
            close();
            LRESULT(0)
        }
        WM_DESTROY => {
            unsafe { PostQuitMessage(0) };
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(window, message, wparam, lparam) },
    }
}

impl Setup {
    /// The control under a point in the window's own pixels.
    fn hit(&self, point: POINT) -> Option<Hit> {
        let at = self.card.dips(point);
        self.hits.iter().rev().find(|(rect, _)| card::contains(rect, at)).map(|&(_, hit)| hit)
    }
}

/// Draws the card again and shows it.
fn refresh(setup: &mut Setup) {
    if let Ok(pixels) = setup.paint() {
        card::present(setup.window, setup.card.size, &pixels, None);
    }
}

fn update(change: impl FnOnce(&mut Setup)) {
    SETUP.with_borrow_mut(|setup| {
        if let Some(setup) = setup {
            change(setup);
            refresh(setup);
        }
    });
}

/// Moves through the pages with the arrow keys.
fn turn(by: isize) {
    update(|setup| {
        if let Stage::Page(page) = setup.stage {
            setup.stage = Stage::Page((page as isize + by).clamp(0, SLIDES as isize) as usize);
        }
    });
}

fn click(hit: Hit) {
    let stage = SETUP.with_borrow(|setup| setup.as_ref().map(|setup| setup.stage.clone()));
    let Some(stage) = stage else { return };
    match (hit, stage) {
        (Hit::Close, _) => close(),
        (Hit::Site, _) => open_link(SITE),
        (Hit::Dot(page), Stage::Page(_)) => update(|setup| setup.stage = Stage::Page(page)),
        (Hit::Secondary, Stage::Page(0)) => update(|setup| setup.stage = Stage::Page(SLIDES)),
        (Hit::Secondary, Stage::Page(page)) => update(|setup| setup.stage = Stage::Page(page - 1)),
        (Hit::Secondary, Stage::Failed(_)) => update(|setup| setup.stage = Stage::Page(SLIDES)),
        (Hit::Primary, Stage::Page(page)) if page < SLIDES => update(|setup| setup.stage = Stage::Page(page + 1)),
        (Hit::Primary, Stage::Page(_) | Stage::Failed(_)) => install_now(),
        (Hit::Primary, Stage::Done(exe)) => {
            install::launch(&exe);
            close();
        }
        (Hit::Snowfall(level), Stage::Page(_)) => update(|setup| setup.choices.snowfall = level),
        (Hit::Sound(sound), Stage::Page(_)) => update(|setup| setup.choices.sound = sound),
        (Hit::Icicles, Stage::Page(_)) => update(|setup| setup.choices.icicles ^= true),
        (Hit::Calls, Stage::Page(_)) => update(|setup| setup.choices.quiet_on_calls ^= true),
        (Hit::Login, Stage::Page(_)) => update(|setup| setup.choices.open_at_login ^= true),
        (Hit::Updates, Stage::Page(_)) => update(|setup| setup.choices.auto_update ^= true),
        _ => {}
    }
}

/// Installs, then writes what was chosen to the settings file the app reads when it starts.
fn install_now() {
    update(|setup| setup.stage = Stage::Installing);
    let result = install::install(APP, VERSION);
    update(|setup| {
        setup.stage = match result {
            Ok(exe) => {
                save_choices(setup, &exe);
                Stage::Done(exe)
            }
            Err(error) => Stage::Failed(error),
        }
    });
}

fn save_choices(setup: &Setup, exe: &std::path::Path) {
    let choices = setup.choices;
    let mut values = setup.saved.clone().unwrap_or_default();
    for (name, value) in [
        ("snowfall", choices.snowfall),
        ("ambience", choices.sound),
        ("icicles", choices.icicles as u32),
        ("quietOnCalls", choices.quiet_on_calls as u32),
        ("openAtLogin", choices.open_at_login as u32),
        ("autoUpdate", choices.auto_update as u32),
        // The presentation stands in for the app's own welcome, and Open at Login is settled here.
        ("welcomed", 1),
        ("loginOffered", 1),
    ] {
        values.insert(name.to_string(), value);
    }
    let _ = store::write(&values);
    install::set_open_at_login(exe, choices.open_at_login);
}

fn open_link(link: &str) {
    let wide: Vec<u16> = link.encode_utf16().chain([0]).collect();
    unsafe {
        ShellExecuteW(None, w!("open"), PCWSTR(wide.as_ptr()), PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL);
    }
}

fn close() {
    if SETUP.with_borrow(|setup| setup.as_ref().is_some_and(|setup| setup.stage == Stage::Installing)) {
        return;
    }
    if let Some(setup) = SETUP.take() {
        unsafe {
            let _ = DestroyWindow(setup.window);
        }
    }
}
