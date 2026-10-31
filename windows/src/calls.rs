//! Notices a call or a recording: another app using the camera or the microphone, as Windows itself records for
//! its privacy indicator under CapabilityAccessManager. An app in use has a start time and no stop time yet.

use std::ffi::c_void;

use windows::Win32::Foundation::ERROR_SUCCESS;
use windows::Win32::System::Registry::{HKEY, HKEY_CURRENT_USER, KEY_READ, RRF_RT_REG_QWORD, RegCloseKey, RegEnumKeyExW, RegGetValueW, RegOpenKeyExW};
use windows::core::{HSTRING, PCWSTR, PWSTR, w};

const STORE: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore";

/// Whether any app but this one is using the camera or microphone right now.
pub fn in_use() -> bool {
    let own = std::env::current_exe().map(|path| path.display().to_string().replace('\\', "#").to_lowercase()).unwrap_or_default();
    ["webcam", "microphone"].iter().any(|capability| {
        let packaged = format!("{STORE}\\{capability}");
        let desktop = format!("{packaged}\\NonPackaged");
        busy_under(&packaged, &own) || busy_under(&desktop, &own)
    })
}

fn busy_under(path: &str, own: &str) -> bool {
    let mut key = HKEY::default();
    let path = HSTRING::from(path);
    if unsafe { RegOpenKeyExW(HKEY_CURRENT_USER, &path, None, KEY_READ, &mut key) } != ERROR_SUCCESS {
        return false;
    }
    let mut busy = false;
    let mut index = 0;
    loop {
        let mut name = [0u16; 512];
        let mut length = name.len() as u32;
        let status = unsafe { RegEnumKeyExW(key, index, Some(PWSTR(name.as_mut_ptr())), &mut length, None, None, None, None) };
        if status != ERROR_SUCCESS {
            break;
        }
        index += 1;
        let app = String::from_utf16_lossy(&name[..length as usize]);
        if app.eq_ignore_ascii_case("NonPackaged") || app.to_lowercase() == own {
            continue;
        }
        let started = qword(key, PCWSTR(name.as_ptr()), w!("LastUsedTimeStart"));
        let stopped = qword(key, PCWSTR(name.as_ptr()), w!("LastUsedTimeStop"));
        if started.is_some_and(|start| start != 0) && stopped == Some(0) {
            busy = true;
            break;
        }
    }
    unsafe {
        let _ = RegCloseKey(key);
    }
    busy
}

fn qword(key: HKEY, subkey: PCWSTR, name: PCWSTR) -> Option<u64> {
    let mut value = 0u64;
    let mut size = 8u32;
    let status = unsafe { RegGetValueW(key, subkey, name, RRF_RT_REG_QWORD, None, Some((&raw mut value).cast::<c_void>()), Some(&mut size)) };
    (status == ERROR_SUCCESS).then_some(value)
}
