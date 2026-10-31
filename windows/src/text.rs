//! The app speaks Russian on a Russian Windows and English everywhere else, with no switch.

use std::sync::OnceLock;

use windows::Win32::Globalization::GetUserDefaultUILanguage;

/// LANG_RUSSIAN, the primary language in the low ten bits of a language id.
const RUSSIAN: u16 = 0x19;

pub fn russian() -> bool {
    static RUSSIAN_UI: OnceLock<bool> = OnceLock::new();
    *RUSSIAN_UI.get_or_init(|| unsafe { GetUserDefaultUILanguage() } & 0x3ff == RUSSIAN)
}

pub fn tr(english: &'static str, russian_text: &'static str) -> &'static str {
    if russian() { russian_text } else { english }
}
