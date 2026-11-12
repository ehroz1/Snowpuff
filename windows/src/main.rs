#![windows_subsystem = "windows"]

mod app;
mod audio;
mod calls;
mod desktop;
mod light;
mod log;
mod prefs;
mod render;
mod screen;
mod snow;
mod tracker;
mod update;
mod welcome;

use windows::Win32::Foundation::{ERROR_ALREADY_EXISTS, GetLastError};
use windows::Win32::System::Recovery::{REGISTER_APPLICATION_RESTART_FLAGS, RegisterApplicationRestart};
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::HiDpi::{DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetProcessDpiAwarenessContext};
use windows::core::w;

fn main() {
    // What "Uninstall" in Settings runs; it removes everything, even with Snowpuff still running.
    if std::env::args().skip(1).any(|argument| argument == "--uninstall") {
        snowpuff::install::uninstall();
        return;
    }
    unsafe {
        let _instance = CreateMutexW(None, true, w!("Local\\Snowpuff"));
        if GetLastError() == ERROR_ALREADY_EXISTS {
            return;
        }
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
    log::start();
    log!("Snowpuff {}", env!("CARGO_PKG_VERSION"));
    // A mistake anywhere is written down instead of vanishing with the process.
    std::panic::set_hook(Box::new(|info| {
        let thread = std::thread::current().name().unwrap_or("main").to_string();
        log!("panic on {thread}: {info}");
    }));
    // Should Snowpuff still crash outright, Windows opens it again (once it has run for a minute, so a crash at
    // start doesn't loop). Updates and Quit end it normally, which doesn't count.
    unsafe {
        let _ = RegisterApplicationRestart(windows::core::w!("--restarted"), REGISTER_APPLICATION_RESTART_FLAGS(0));
    }
    if let Err(error) = app::run() {
        log!("failed: {error}");
    }
}
