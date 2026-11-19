//! "What's New": a card shown once after Snowpuff updates itself, and from the menu any time.

use std::cell::RefCell;
use std::sync::Once;

use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::UI::Input::KeyboardAndMouse::{ReleaseCapture, SetCapture, VK_ESCAPE, VK_RETURN};
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{PCWSTR, Result, w};

use crate::log;
use snowpuff::card::{self, Card, Content, Hits};
use snowpuff::text::{russian, tr};

const CLASS: PCWSTR = w!("SnowpuffWhatsNew");
const WIDTH: f32 = 440.0;
const HEIGHT: f32 = 600.0;

struct Shown {
    window: HWND,
    card: Card,
    hits: Hits,
    holding: bool,
}

thread_local! {
    static SHOWN: RefCell<Option<Shown>> = const { RefCell::new(None) };
}

/// This version's news, one line each.
fn body() -> &'static str {
    if russian() {
        "Цветущая сакура и град в «Режиме»\n\
         «Погода за окном»: как сейчас на улице\n\
         Морозные узоры и запотевшее стекло\n\
         Снеговики, снежки, кот и снегирь\n\
         Звёзды, туман и гирлянда на окнах\n\
         Звуки дождя, града, снега и сосулек\n\
         Отсчёт до Нового года\n\
         Настройки, прозрачность, экономия батареи\n\
         Alt + курсор рисует по инею"
    } else {
        "Cherry Blossom and Hail under Mode\n\
         Weather Outside: as it is where you are\n\
         Frost patterns and misted glass\n\
         Snowmen, snowballs, a cat and a bullfinch\n\
         Stars, fog and a garland on your windows\n\
         Sounds of rain, hail, snow and icicles\n\
         A New Year countdown\n\
         Settings, opacity, Battery Saver\n\
         Alt + cursor draws on the frost"
    }
}

fn content(pressed: bool) -> Content<'static> {
    let title: &'static str = Box::leak(
        if russian() { format!("ЧТО НОВОГО В {}", crate::update::VERSION) } else { format!("NEW IN {}", crate::update::VERSION) }.into_boxed_str(),
    );
    Content { icon: 84.0, title, title_size: 30.0, body: body(), button: tr("LOVELY", "ОТЛИЧНО"), pressed, closable: true }
}

pub fn show() {
    if SHOWN.with_borrow(|shown| shown.as_ref().map(|s| s.window)).is_some_and(|window| unsafe { SetForegroundWindow(window) }.as_bool()) {
        return;
    }
    if let Err(error) = open() {
        log!("what's new failed: {error}");
    }
}

fn open() -> Result<()> {
    static REGISTER: Once = Once::new();
    REGISTER.call_once(|| {
        let _ = card::register(CLASS, Some(procedure));
    });
    let (scale, origin) = card::placement(WIDTH, HEIGHT);
    let card = Card::new(WIDTH, HEIGHT, scale)?;
    let (pixels, hits) = card.paint(&content(false))?;
    unsafe {
        let window = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
            CLASS,
            w!("Snowpuff"),
            WS_POPUP,
            origin.x,
            origin.y,
            card.size.0,
            card.size.1,
            None,
            None,
            None,
            None,
        )?;
        card::present(window, card.size, &pixels, Some(origin));
        SHOWN.set(Some(Shown { window, card, hits, holding: false }));
        let _ = ShowWindow(window, SW_SHOW);
        let _ = SetForegroundWindow(window);
    }
    Ok(())
}

fn close() {
    if let Some(shown) = SHOWN.take() {
        unsafe {
            let _ = DestroyWindow(shown.window);
        }
    }
}

unsafe extern "system" fn procedure(window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match message {
        WM_NCHITTEST => {
            let mut origin = RECT::default();
            unsafe {
                let _ = GetWindowRect(window, &mut origin);
            }
            let point = card::point(lparam);
            let inside = SHOWN.with_borrow(|shown| {
                shown.as_ref().map(|shown| {
                    let at = shown.card.dips(windows::Win32::Foundation::POINT { x: point.x - origin.left, y: point.y - origin.top });
                    card::contains(&shown.hits.button, at) || shown.hits.close.is_some_and(|close| card::contains(&close, at))
                })
            });
            // The card drags the window anywhere but on its controls.
            LRESULT(if inside == Some(false) { HTCAPTION as isize } else { HTCLIENT as isize })
        }
        WM_LBUTTONDOWN => {
            unsafe { SetCapture(window) };
            SHOWN.with_borrow_mut(|shown| {
                if let Some(shown) = shown {
                    shown.holding = true;
                    if let Ok((pixels, hits)) = shown.card.paint(&content(true)) {
                        shown.hits = hits;
                        card::present(shown.window, shown.card.size, &pixels, None);
                    }
                }
            });
            LRESULT(0)
        }
        WM_LBUTTONUP => {
            unsafe {
                let _ = ReleaseCapture();
            }
            let held = SHOWN.with_borrow(|shown| shown.as_ref().is_some_and(|shown| shown.holding));
            if held {
                close();
            }
            LRESULT(0)
        }
        WM_KEYDOWN if wparam.0 == VK_RETURN.0 as usize || wparam.0 == VK_ESCAPE.0 as usize => {
            close();
            LRESULT(0)
        }
        WM_CLOSE => {
            close();
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(window, message, wparam, lparam) },
    }
}
