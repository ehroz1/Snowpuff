//! Updates from GitHub releases: the latest release's `Snowpuff-Setup.exe` is downloaded, checked against the
//! SHA-256 GitHub reports for it and run with `--update`, which closes this copy, installs and opens the new one.

use std::ffi::c_void;
use std::os::windows::process::CommandExt;
use std::path::PathBuf;

use windows::Win32::Networking::WinHttp::{
    WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_FLAG_SECURE, WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_QUERY_STATUS_CODE, WinHttpCloseHandle,
    WinHttpConnect, WinHttpOpen, WinHttpOpenRequest, WinHttpQueryHeaders, WinHttpReadData, WinHttpReceiveResponse, WinHttpSendRequest,
    WinHttpSetTimeouts,
};
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
use windows::core::{PCWSTR, w};

use snowpuff_core::version::{asset_digest, field, newer, sha256};

pub const REPOSITORY: &str = "ehroz1/Snowpuff";
const INSTALLER: &str = "Snowpuff-Setup.exe";
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// A release newer than this build that carries an installer for Windows.
#[derive(Clone)]
pub struct Release {
    pub version: String,
    pub url: String,
    digest: Option<String>,
}

/// Asks GitHub for the latest release. Releases with nothing for Windows don't count as updates.
pub fn check() -> Result<Option<Release>, String> {
    let body = String::from_utf8_lossy(&fetch(&format!("https://api.github.com/repos/{REPOSITORY}/releases/latest"))?).into_owned();
    let tag = field(&body, "tag_name").ok_or("the latest release has no tag")?;
    let version = tag.trim_start_matches('v');
    let Some(digest) = asset_digest(&body, INSTALLER) else { return Ok(None) };
    if !newer(version, VERSION) {
        return Ok(None);
    }
    Ok(Some(Release {
        version: version.to_string(),
        url: format!("https://github.com/{REPOSITORY}/releases/download/{tag}/{INSTALLER}"),
        digest,
    }))
}

/// Downloads the release's installer, checks it and starts it. The installer closes this app, so nothing
/// after a successful call needs to happen here.
pub fn install(release: &Release) -> Result<(), String> {
    let installer = fetch(&release.url)?;
    if installer.len() < 64 * 1024 || !installer.starts_with(b"MZ") {
        return Err("the download isn't an installer".into());
    }
    if let Some(expected) = &release.digest
        && sha256(&installer) != *expected
    {
        return Err("the download doesn't match the release".into());
    }
    let path: PathBuf = std::env::temp_dir().join(format!("Snowpuff-Setup-{}.exe", release.version));
    std::fs::write(&path, &installer).map_err(|error| format!("couldn't save {}: {error}", path.display()))?;
    const DETACHED_PROCESS: u32 = 0x0000_0008;
    std::process::Command::new(&path)
        .arg("--update")
        .creation_flags(DETACHED_PROCESS)
        .spawn()
        .map(|_| ())
        .map_err(|error| format!("couldn't start the installer: {error}"))
}

pub fn open(url: &str) {
    let url: Vec<u16> = url.encode_utf16().chain([0]).collect();
    unsafe {
        ShellExecuteW(None, w!("open"), PCWSTR(url.as_ptr()), PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL);
    }
}

struct Handle(*mut c_void);

impl Drop for Handle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                let _ = WinHttpCloseHandle(self.0);
            }
        }
    }
}

/// GETs an https URL, following GitHub's redirects to its download servers.
fn fetch(url: &str) -> Result<Vec<u8>, String> {
    let rest = url.strip_prefix("https://").ok_or("only https is fetched")?;
    let (host, path) = rest.split_at(rest.find('/').unwrap_or(rest.len()));
    let failed = |what: &str| format!("{what} failed: {}", windows::core::Error::from_thread().message());
    let host: Vec<u16> = host.encode_utf16().chain([0]).collect();
    let path: Vec<u16> = if path.is_empty() { "/" } else { path }.encode_utf16().chain([0]).collect();
    unsafe {
        let session = Handle(WinHttpOpen(w!("Snowpuff"), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, PCWSTR::null(), PCWSTR::null(), 0));
        if session.0.is_null() {
            return Err(failed("Opening a connection"));
        }
        let _ = WinHttpSetTimeouts(session.0, 15_000, 15_000, 15_000, 60_000);
        let connection = Handle(WinHttpConnect(session.0, PCWSTR(host.as_ptr()), 443, 0));
        if connection.0.is_null() {
            return Err(failed("Connecting to GitHub"));
        }
        let request = Handle(WinHttpOpenRequest(
            connection.0,
            w!("GET"),
            PCWSTR(path.as_ptr()),
            PCWSTR::null(),
            PCWSTR::null(),
            std::ptr::null(),
            WINHTTP_FLAG_SECURE,
        ));
        if request.0.is_null() {
            return Err(failed("Preparing the request"));
        }
        // The API speaks JSON when asked; the download links answer with the file whatever is asked.
        let headers: Vec<u16> = "Accept: application/vnd.github+json\r\nX-GitHub-Api-Version: 2022-11-28\r\n".encode_utf16().collect();
        let api = url.starts_with("https://api.github.com/");
        WinHttpSendRequest(request.0, if api { Some(&headers) } else { None }, None, 0, 0, 0).map_err(|error| error.message())?;
        WinHttpReceiveResponse(request.0, std::ptr::null_mut()).map_err(|error| error.message())?;

        let mut status = 0u32;
        let mut size = 4u32;
        WinHttpQueryHeaders(
            request.0,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            PCWSTR::null(),
            Some((&raw mut status).cast()),
            &mut size,
            std::ptr::null_mut(),
        )
        .map_err(|error| error.message())?;
        if status == 404 {
            return Err("GitHub has no release yet".into());
        }
        if status != 200 {
            return Err(format!("GitHub answered {status}"));
        }

        let mut body = Vec::new();
        let mut buffer = vec![0u8; 64 * 1024];
        loop {
            let mut read = 0u32;
            WinHttpReadData(request.0, buffer.as_mut_ptr().cast(), buffer.len() as u32, &mut read).map_err(|error| error.message())?;
            if read == 0 {
                break;
            }
            body.extend_from_slice(&buffer[..read as usize]);
            if body.len() > 64 * 1024 * 1024 {
                return Err("the download is too large".into());
            }
        }
        Ok(body)
    }
}
