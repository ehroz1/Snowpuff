//! The winter sound out of the speakers, and an ear on the microphone for a breath, both through WASAPI in shared
//! mode on threads of their own. The sound itself and the ear's judgement come from `snowpuff_core::sound`.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use windows::Win32::Media::Audio::{
    AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM, AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY, IAudioCaptureClient, IAudioClient,
    IAudioRenderClient, IMMDeviceEnumerator, MMDeviceEnumerator, WAVEFORMATEX, eCapture, eConsole, eRender,
};
use windows::Win32::System::Com::{CLSCTX_ALL, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoUninitialize};
use windows::core::Result;

use snowpuff_core::sfx::{Cue, Sfx};
use snowpuff_core::sound::{Ambience, BreathDetector};

use crate::log;

const RATE: u32 = 48_000;
/// 32-bit float samples.
const IEEE_FLOAT: u16 = 3;

fn format(channels: u16) -> WAVEFORMATEX {
    WAVEFORMATEX {
        wFormatTag: IEEE_FLOAT,
        nChannels: channels,
        nSamplesPerSec: RATE,
        nAvgBytesPerSec: RATE * 4 * channels as u32,
        nBlockAlign: 4 * channels,
        wBitsPerSample: 32,
        cbSize: 0,
    }
}

/// Opens the default device for `flow` in shared mode, converting from our float format to whatever it takes.
fn client(capture: bool) -> Result<IAudioClient> {
    unsafe {
        let devices: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
        let device = devices.GetDefaultAudioEndpoint(if capture { eCapture } else { eRender }, eConsole)?;
        let client: IAudioClient = device.Activate(CLSCTX_ALL, None)?;
        let format = format(if capture { 1 } else { 2 });
        // 100 ms of buffer, in 100-nanosecond units.
        client.Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
            1_000_000,
            0,
            &format,
            None,
        )?;
        Ok(client)
    }
}

/// The winter sound. Settings change through `set`; the thread runs while anything is to be heard, through the fade.
pub struct Sound {
    ambience: Arc<Mutex<Ambience>>,
    /// Effects over the ambience: rain, hail, crunching snow, icicles, snowballs, fireworks.
    sfx: Arc<Mutex<Sfx>>,
    thread: Option<JoinHandle<()>>,
}

impl Sound {
    pub fn new() -> Sound {
        Sound { ambience: Arc::new(Mutex::new(Ambience::new(RATE as f32))), sfx: Arc::new(Mutex::new(Sfx::new(RATE as f32))), thread: None }
    }

    /// `mode`: 0 off, 1 wind, 2 fireplace, 3 both; `muted` silences it whatever the mode.
    pub fn set(&mut self, mode: u32, muted: bool, volume: f32, windiness: f32) {
        {
            let Ok(mut ambience) = self.ambience.lock() else { return };
            ambience.wind = !muted && (mode == 1 || mode == 3);
            ambience.fire = !muted && (mode == 2 || mode == 3);
            ambience.volume = volume.clamp(0.0, 1.0);
            ambience.windiness = windiness;
        }
        if let Ok(mut sfx) = self.sfx.lock() {
            sfx.volume = volume.clamp(0.0, 1.0);
            if muted {
                sfx.rain = 0.0;
                sfx.hail = 0.0;
            }
        }
        self.wake();
    }

    /// How hard it rains and hails, for their beds of sound; `on` is whether effects are wanted at all.
    pub fn set_effects(&mut self, on: bool, rain: f32, hail: f32) {
        if let Ok(mut sfx) = self.sfx.lock() {
            sfx.rain = if on { rain } else { 0.0 };
            sfx.hail = if on { hail } else { 0.0 };
        }
        self.wake();
    }

    pub fn play(&mut self, cue: Cue) {
        if let Ok(mut sfx) = self.sfx.lock() {
            sfx.play(cue);
        }
        self.wake();
    }

    /// Starts the sound thread when something can be heard and it isn't running.
    fn wake(&mut self) {
        let audible = self.ambience.lock().is_ok_and(|a| a.audible()) || self.sfx.lock().is_ok_and(|s| s.audible());
        if !audible || self.thread.as_ref().is_some_and(|thread| !thread.is_finished()) {
            return;
        }
        let (ambience, sfx) = (self.ambience.clone(), self.sfx.clone());
        self.thread = thread::Builder::new().name("sound".into()).spawn(move || play(&ambience, &sfx)).ok();
    }
}

fn play(ambience: &Mutex<Ambience>, sfx: &Mutex<Sfx>) {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
    // A device that goes away, as when headphones are unplugged, ends the stream; the default one takes over.
    while ambience.lock().is_ok_and(|ambience| ambience.audible()) || sfx.lock().is_ok_and(|sfx| sfx.audible()) {
        if let Err(error) = stream(ambience, sfx) {
            log!("sound: {error}");
            thread::sleep(Duration::from_secs(1));
        }
    }
    unsafe { CoUninitialize() };
}

fn stream(ambience: &Mutex<Ambience>, sfx: &Mutex<Sfx>) -> Result<()> {
    unsafe {
        let client = client(false)?;
        let size = client.GetBufferSize()?;
        let render: IAudioRenderClient = client.GetService()?;
        client.Start()?;
        let mut samples = vec![0.0f32; size as usize * 2];
        loop {
            let free = size - client.GetCurrentPadding()?;
            if free > 0 {
                let block = &mut samples[..free as usize * 2];
                let audible = {
                    let Ok(mut ambience) = ambience.lock() else { break };
                    ambience.render(block);
                    let mut heard = ambience.audible();
                    if let Ok(mut sfx) = sfx.lock() {
                        sfx.mix(block);
                        heard |= sfx.audible();
                    }
                    heard
                };
                let data = render.GetBuffer(free)?;
                std::ptr::copy_nonoverlapping(block.as_ptr(), data.cast::<f32>(), block.len());
                render.ReleaseBuffer(free, 0)?;
                if !audible {
                    break;
                }
            }
            thread::sleep(Duration::from_millis(15));
        }
        // Let what's buffered play out before stopping.
        thread::sleep(Duration::from_millis(120));
        let _ = client.Stop();
    }
    Ok(())
}

/// Listens to the microphone for a breath while it lives; `puffed` gets each puff's strength on the ear's thread.
pub struct Ear {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Ear {
    /// `failed` is called once, on the ear's thread, if the microphone can't be opened, as when Windows' privacy
    /// settings keep desktop apps from it.
    pub fn start(puffed: impl Fn(f32) + Send + 'static, failed: impl FnOnce() + Send + 'static) -> Ear {
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        let thread = thread::Builder::new().name("ear".into()).spawn(move || listen(&flag, &puffed, failed)).ok();
        Ear { stop, thread }
    }
}

impl Drop for Ear {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn listen(stop: &AtomicBool, puffed: &dyn Fn(f32), failed: impl FnOnce()) {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
    let mut failed = Some(failed);
    let mut detector = BreathDetector::new(RATE as f32);
    let mut tries = 0;
    while !stop.load(Ordering::Relaxed) {
        match capture(stop, &mut detector, puffed) {
            Ok(()) => tries = 0,
            Err(error) => {
                log!("microphone: {error}");
                tries += 1;
                if tries == 3
                    && let Some(failed) = failed.take()
                {
                    failed();
                }
                for _ in 0..20 {
                    if stop.load(Ordering::Relaxed) {
                        break;
                    }
                    thread::sleep(Duration::from_millis(100));
                }
            }
        }
    }
    unsafe { CoUninitialize() };
}

fn capture(stop: &AtomicBool, detector: &mut BreathDetector, puffed: &dyn Fn(f32)) -> Result<()> {
    unsafe {
        let client = client(true)?;
        let reader: IAudioCaptureClient = client.GetService()?;
        client.Start()?;
        let mut block: Vec<f32> = Vec::with_capacity(2048);
        while !stop.load(Ordering::Relaxed) {
            while reader.GetNextPacketSize()? > 0 {
                let mut data = std::ptr::null_mut();
                let mut frames = 0;
                let mut flags = 0;
                reader.GetBuffer(&mut data, &mut frames, &mut flags, None, None)?;
                // Silent packets carry no data worth reading.
                if flags & 2 == 0 && !data.is_null() {
                    block.extend_from_slice(std::slice::from_raw_parts(data.cast::<f32>(), frames as usize));
                } else {
                    block.extend(std::iter::repeat_n(0.0, frames as usize));
                }
                reader.ReleaseBuffer(frames)?;
                // Judged in blocks of 20 ms.
                while block.len() >= 960 {
                    if let Some(strength) = detector.feed(&block[..960]) {
                        puffed(strength);
                    }
                    block.drain(..960);
                }
            }
            thread::sleep(Duration::from_millis(10));
        }
        let _ = client.Stop();
    }
    Ok(())
}
