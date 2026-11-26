//! A C interface to the extras and the sound effects, for the Mac app: Swift calls these through
//! `Sources/CSnowpuffCore/include/snowpuff_core.h`, which must match the types here.

#![allow(clippy::missing_safety_doc)]

use std::sync::Mutex;

use super::extras::{Extras, Input, Settings, Weather};
use crate::geometry::{Rect, V2};
use super::types::RainWindow;
use super::sfx::{Cue, Sfx};
use super::types::Sprite;

#[repr(C)]
pub struct SPInput {
    pub dt: f32,
    pub cursor_x: f32,
    pub cursor_y: f32,
    pub has_cursor: u8,
    pub button: u8,
    pub magic: u8,
    pub padding: u8,
    pub daylight: f32,
    pub top_inset: f32,
}

#[repr(C)]
pub struct SPSettings {
    /// 0 snow, 1 leaves, 2 petals, 3 rain, 4 hail.
    pub weather: u8,
    pub blizzard: u8,
    pub fog: u8,
    pub stars: u8,
    pub garland: u8,
    pub frost: u8,
    pub creatures: u8,
    pub padding: u8,
    pub intensity: f32,
}

#[repr(C)]
pub struct SPRect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

#[repr(C)]
pub struct SPWindow {
    pub id: i64,
    pub frame: SPRect,
    /// Where this window's fronts start in the fronts array, and how many.
    pub fronts_offset: u32,
    pub fronts_count: u32,
    pub ledge_only: u8,
}

#[repr(C)]
pub struct SPCue {
    /// 0 crunch, 1 chime, 2 splat, 3 boom.
    pub kind: u32,
    pub value: f32,
}

#[repr(C)]
pub struct SPFrost {
    pub values: *const f32,
    pub columns: u32,
    pub rows: u32,
    pub cell: f32,
    pub reach: f32,
    pub changed: u8,
    pub mist: u8,
}

fn rect(r: &SPRect) -> Rect {
    Rect { x: r.x, y: r.y, width: r.width, height: r.height }
}

#[unsafe(no_mangle)]
pub extern "C" fn sp_extras_new(width: f32, height: f32) -> *mut Extras {
    Box::into_raw(Box::new(Extras::new(width, height)))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_extras_free(extras: *mut Extras) {
    if !extras.is_null() {
        drop(unsafe { Box::from_raw(extras) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_extras_resize(extras: *mut Extras, width: f32, height: f32) {
    unsafe { &mut *extras }.resize(width, height);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_extras_settings(extras: *mut Extras, settings: SPSettings) {
    let weather = match settings.weather {
        1 => Weather::Leaves,
        2 => Weather::Petals,
        3 => Weather::Rain,
        4 => Weather::Hail,
        _ => Weather::Snow,
    };
    unsafe { &mut *extras }.settings = Settings {
        weather,
        intensity: settings.intensity,
        blizzard: settings.blizzard != 0,
        fog: settings.fog != 0,
        stars: settings.stars != 0,
        garland: settings.garland != 0,
        frost: settings.frost != 0,
        creatures: settings.creatures != 0,
        snowmen: false,
    };
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_extras_ground(extras: *mut Extras, heights: *const f32, count: usize) {
    let heights = if heights.is_null() { &[][..] } else { unsafe { std::slice::from_raw_parts(heights, count) } };
    unsafe { &mut *extras }.set_ground(heights);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_extras_windows(extras: *mut Extras, windows: *const SPWindow, count: usize, fronts: *const SPRect, front_count: usize) {
    let windows = if windows.is_null() { &[][..] } else { unsafe { std::slice::from_raw_parts(windows, count) } };
    let fronts = if fronts.is_null() { &[][..] } else { unsafe { std::slice::from_raw_parts(fronts, front_count) } };
    let list: Vec<RainWindow> = windows
        .iter()
        .map(|w| {
            let start = (w.fronts_offset as usize).min(fronts.len());
            let end = (start + w.fronts_count as usize).min(fronts.len());
            RainWindow { id: w.id as isize, frame: rect(&w.frame), fronts: fronts[start..end].iter().map(rect).collect(), ledge_only: w.ledge_only != 0 }
        })
        .collect();
    unsafe { &mut *extras }.set_windows(&list);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_extras_covers(extras: *mut Extras, covers: *const f32, count: usize) {
    let flat = if covers.is_null() { &[][..] } else { unsafe { std::slice::from_raw_parts(covers, count * 4) } };
    let list: Vec<[f32; 4]> = flat.chunks_exact(4).map(|c| [c[0], c[1], c[2], c[3]]).collect();
    unsafe { &mut *extras }.set_covers(&list);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_extras_step(extras: *mut Extras, input: SPInput) {
    unsafe { &mut *extras }.step(Input {
        dt: input.dt,
        cursor: (input.has_cursor != 0).then_some(V2::new(input.cursor_x, input.cursor_y)),
        button: input.button != 0,
        magic: input.magic != 0,
        daylight: input.daylight,
        top_inset: input.top_inset,
    });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_extras_flurry(extras: *mut Extras) {
    unsafe { &mut *extras }.flurry();
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_extras_fireworks(extras: *mut Extras, seconds: f32) {
    unsafe { &mut *extras }.fireworks(seconds);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_extras_build_snowman(extras: *mut Extras, x: f32) {
    unsafe { &mut *extras }.build_snowman(x);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_extras_throw(extras: *mut Extras, x: f32, y: f32) {
    unsafe { &mut *extras }.throw_at(V2::new(x, y));
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_extras_clear(extras: *mut Extras) {
    unsafe { &mut *extras }.clear();
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_extras_active(extras: *const Extras) -> u8 {
    unsafe { &*extras }.is_active() as u8
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_extras_smooth(extras: *const Extras) -> u8 {
    unsafe { &*extras }.needs_smooth() as u8
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_extras_sprite_count(extras: *const Extras) -> usize {
    unsafe { &*extras }.sprite_count()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_extras_write(extras: *const Extras, out: *mut Sprite, capacity: usize) -> usize {
    if out.is_null() || capacity == 0 {
        return 0;
    }
    let out = unsafe { std::slice::from_raw_parts_mut(out, capacity) };
    unsafe { &*extras }.write(out)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_extras_frost(extras: *mut Extras) -> SPFrost {
    let extras = unsafe { &mut *extras };
    let reach = extras.frost_reach();
    let mist = extras.frost_is_mist() as u8;
    let (values, columns, rows, cell, changed) = extras.frost();
    SPFrost { values: values.as_ptr(), columns: columns as u32, rows: rows as u32, cell, reach, changed: changed as u8, mist }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_extras_take_cues(extras: *mut Extras, out: *mut SPCue, capacity: usize) -> usize {
    let cues = unsafe { &mut *extras }.take_cues();
    if out.is_null() {
        return 0;
    }
    let out = unsafe { std::slice::from_raw_parts_mut(out, capacity) };
    let mut n = 0;
    for cue in cues.into_iter().take(capacity) {
        out[n] = match cue {
            Cue::Crunch(v) => SPCue { kind: 0, value: v },
            Cue::Chime(v) => SPCue { kind: 1, value: v },
            Cue::Splat => SPCue { kind: 2, value: 0.0 },
            Cue::Boom(v) => SPCue { kind: 3, value: v },
        };
        n += 1;
    }
    n
}

#[unsafe(no_mangle)]
pub extern "C" fn sp_sfx_new(sample_rate: f32) -> *mut Mutex<Sfx> {
    Box::into_raw(Box::new(Mutex::new(Sfx::new(sample_rate))))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_sfx_free(sfx: *mut Mutex<Sfx>) {
    if !sfx.is_null() {
        drop(unsafe { Box::from_raw(sfx) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_sfx_set(sfx: *const Mutex<Sfx>, sample_rate: f32, volume: f32, rain: f32, hail: f32) {
    if let Ok(mut sfx) = unsafe { &*sfx }.lock() {
        sfx.set_sample_rate(sample_rate);
        sfx.volume = volume;
        sfx.rain = rain;
        sfx.hail = hail;
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_sfx_play(sfx: *const Mutex<Sfx>, kind: u32, value: f32) {
    let cue = match kind {
        0 => Cue::Crunch(value),
        1 => Cue::Chime(value),
        2 => Cue::Splat,
        _ => Cue::Boom(value),
    };
    if let Ok(mut sfx) = unsafe { &*sfx }.lock() {
        sfx.play(cue);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_sfx_audible(sfx: *const Mutex<Sfx>) -> u8 {
    unsafe { &*sfx }.lock().map(|sfx| sfx.audible() as u8).unwrap_or(1)
}

/// Adds the effects into two channels of `frames` samples each. Called on the audio thread: it never waits for the
/// lock, and skips a buffer rather than stall.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_sfx_mix(sfx: *const Mutex<Sfx>, left: *mut f32, right: *mut f32, frames: usize) {
    let Ok(mut sfx) = unsafe { &*sfx }.try_lock() else { return };
    let (left, right) = unsafe { (std::slice::from_raw_parts_mut(left, frames), std::slice::from_raw_parts_mut(right, frames)) };
    let mut buffer = [0.0f32; 1024];
    let mut done = 0;
    while done < frames {
        let n = (frames - done).min(512);
        let chunk = &mut buffer[..n * 2];
        chunk.iter_mut().for_each(|v| *v = 0.0);
        sfx.mix(chunk);
        for k in 0..n {
            left[done + k] += chunk[k * 2];
            right[done + k] += chunk[k * 2 + 1];
        }
        done += n;
    }
}

// MARK: Icicles

use std::collections::HashSet;

use super::icicles::{Eaves, IcicleSprite, Icicles, Snow};

/// How deep the snow lies on a window.
#[repr(C)]
pub struct SPDepth {
    pub id: i64,
    pub depth: f32,
}

/// Where a broken icicle burst into snow, and how much of it there was.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct SPShatter {
    pub x: f32,
    pub y: f32,
    pub size: f32,
}

/// A run of icicles sharing the windows in front of them: where its sprites and occluders start, and how many.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct SPIcicleGroup {
    pub offset: u32,
    pub count: u32,
    pub occluders_offset: u32,
    pub occluders_count: u32,
}

/// The snow as the app reported it for one step.
struct Reported<'a> {
    depths: &'a [SPDepth],
    ground: &'a [f32],
    shatters: Vec<SPShatter>,
}

impl Snow for Reported<'_> {
    fn depth_on_window(&self, id: isize) -> f32 {
        self.depths.iter().find(|d| d.id as isize == id).map_or(0.0, |d| d.depth)
    }

    fn ground_level(&self, x: f32) -> f32 {
        if self.ground.is_empty() {
            return 0.0;
        }
        let i = ((x / 4.0).round().max(0.0) as usize).min(self.ground.len() - 1);
        self.ground[i]
    }

    fn shatter(&mut self, at: V2, size: f32) {
        if self.shatters.len() < 64 {
            self.shatters.push(SPShatter { x: at.x, y: at.y, size });
        }
    }
}

unsafe fn slice<'a, T>(pointer: *const T, count: usize) -> &'a [T] {
    if pointer.is_null() || count == 0 { &[] } else { unsafe { std::slice::from_raw_parts(pointer, count) } }
}

#[unsafe(no_mangle)]
pub extern "C" fn sp_icicles_new() -> *mut Icicles {
    Box::into_raw(Box::new(Icicles::new()))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_icicles_free(icicles: *mut Icicles) {
    if !icicles.is_null() {
        drop(unsafe { Box::from_raw(icicles) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_icicles_enable(icicles: *mut Icicles, on: u8) {
    unsafe { &mut *icicles }.set_enabled(on != 0);
}

/// The windows now, as for the extras; `keep` are those away on another desktop, which keep their icicles.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_icicles_update(
    icicles: *mut Icicles,
    windows: *const SPWindow,
    count: usize,
    fronts: *const SPRect,
    front_count: usize,
    keep: *const i64,
    keep_count: usize,
    interval: f32,
    sliding: u8,
) {
    let windows = unsafe { slice(windows, count) };
    let fronts = unsafe { slice(fronts, front_count) };
    let eaves: Vec<Eaves> = windows
        .iter()
        .filter(|w| w.ledge_only == 0)
        .map(|w| {
            let start = (w.fronts_offset as usize).min(fronts.len());
            let end = (start + w.fronts_count as usize).min(fronts.len());
            Eaves { id: w.id as isize, frame: rect(&w.frame), fronts: fronts[start..end].iter().map(rect).collect() }
        })
        .collect();
    let keep: HashSet<isize> = unsafe { slice(keep, keep_count) }.iter().map(|&id| id as isize).collect();
    unsafe { &mut *icicles }.update(&eaves, interval, &keep, sliding != 0);
}

/// Moves the icicles on. `depths` is the snow on each window, `ground` the drift's top every 4 points; shattered
/// icicles are written to `shatters`, their count to `shattered`. Returns whether anything visible changed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_icicles_step(
    icicles: *mut Icicles,
    dt: f32,
    depths: *const SPDepth,
    depth_count: usize,
    ground: *const f32,
    ground_count: usize,
    shatters: *mut SPShatter,
    capacity: usize,
    shattered: *mut usize,
) -> u8 {
    let mut snow = Reported { depths: unsafe { slice(depths, depth_count) }, ground: unsafe { slice(ground, ground_count) }, shatters: Vec::new() };
    let changed = unsafe { &mut *icicles }.step(dt, &mut snow);
    let n = snow.shatters.len().min(capacity);
    if !shatters.is_null() {
        for (i, shatter) in snow.shatters.iter().take(n).enumerate() {
            unsafe { *shatters.add(i) = *shatter };
        }
    }
    if !shattered.is_null() {
        unsafe { *shattered = if shatters.is_null() { 0 } else { n } };
    }
    changed as u8
}

/// A click at a point: knocks down the icicle there and writes how high it rings; returns whether one was hit.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_icicles_knock(icicles: *mut Icicles, x: f32, y: f32, pitch: *mut f32) -> u8 {
    match unsafe { &mut *icicles }.knock(V2::new(x, y)) {
        Some(value) => {
            if !pitch.is_null() {
                unsafe { *pitch = value };
            }
            1
        }
        None => 0,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_icicles_melt(icicles: *mut Icicles) {
    unsafe { &mut *icicles }.melt();
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_icicles_drop_all(icicles: *mut Icicles) {
    unsafe { &mut *icicles }.drop_all();
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_icicles_falling(icicles: *const Icicles) -> u8 {
    unsafe { &*icicles }.is_falling() as u8
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_icicles_empty(icicles: *const Icicles) -> u8 {
    unsafe { &*icicles }.is_empty() as u8
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_icicles_count(icicles: *const Icicles) -> usize {
    unsafe { &*icicles }.count()
}

/// Writes the icicles to draw, in runs that share the windows in front of them; the counts written go to the
/// last three arguments.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sp_icicles_write(
    icicles: *const Icicles,
    sprites: *mut IcicleSprite,
    sprite_capacity: usize,
    groups: *mut SPIcicleGroup,
    group_capacity: usize,
    occluders: *mut [f32; 4],
    occluder_capacity: usize,
    counts: *mut usize,
) {
    let icicles = unsafe { &*icicles };
    let mut buffer = vec![IcicleSprite::default(); sprite_capacity];
    let written = icicles.write(&mut buffer);
    let sprite_count = written.iter().map(|g| g.offset + g.count).max().unwrap_or(0).min(sprite_capacity);
    for (i, sprite) in buffer.iter().take(sprite_count).enumerate() {
        unsafe { *sprites.add(i) = *sprite };
    }
    let (mut group_count, mut occluder_count) = (0usize, 0usize);
    for group in &written {
        if group_count >= group_capacity {
            break;
        }
        let take = group.occluders.len().min(occluder_capacity - occluder_count);
        for (k, occluder) in group.occluders.iter().take(take).enumerate() {
            unsafe { *occluders.add(occluder_count + k) = *occluder };
        }
        unsafe {
            *groups.add(group_count) =
                SPIcicleGroup { offset: group.offset as u32, count: group.count as u32, occluders_offset: occluder_count as u32, occluders_count: take as u32 }
        };
        occluder_count += take;
        group_count += 1;
    }
    if !counts.is_null() {
        unsafe {
            *counts = sprite_count;
            *counts.add(1) = group_count;
            *counts.add(2) = occluder_count;
        }
    }
}
