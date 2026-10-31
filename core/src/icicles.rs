//! Icicles along the bottom edges of windows that carry snow, like the ones under the window on the app icon.
//! They grow slowly, ride along when a window is moved gently, and snap off and shatter into snow when it is
//! jerked, shaken, closed or minimized. The Mac app has the same in Swift.

use std::collections::{HashMap, HashSet};

use crate::geometry::{Rect, V2};
use crate::simulation::{SnowSimulation, WindowId, WindowSurface};

/// One icicle as the graphics card draws it: where it hangs from, how long and wide, how far it is turned,
/// a seed for its ripples and glint, and how opaque it is.
#[derive(Clone, Copy, Debug, Default)]
#[repr(C)]
pub struct IcicleSprite {
    pub root: V2,
    pub length: f32,
    pub width: f32,
    pub angle: f32,
    pub seed: f32,
    pub alpha: f32,
    pub padding: f32,
}

/// A run of icicles that share the same windows in front of them, left, bottom, right, top.
pub struct IcicleGroup {
    pub offset: usize,
    pub count: usize,
    pub occluders: Vec<[f32; 4]>,
}

#[derive(Clone, Copy)]
struct Hanging {
    /// From the window's left edge.
    x: f32,
    length: f32,
    max_length: f32,
    width: f32,
    seed: f32,
    /// Points a second.
    rate: f32,
}

#[derive(Clone)]
struct Eave {
    frame: Rect,
    velocity: V2,
    hanging: Vec<Hanging>,
    occluders: Vec<[f32; 4]>,
}

struct Falling {
    position: V2,
    velocity: V2,
    length: f32,
    width: f32,
    angle: f32,
    spin: f32,
    seed: f32,
}

pub struct Icicles {
    enabled: bool,
    eaves: HashMap<WindowId, Eave>,
    /// Eaves of windows on another desktop, kept out of sight until they return.
    away: HashMap<WindowId, Eave>,
    falling: Vec<Falling>,
    grown: f32,
    dirty: bool,
    seed: u32,
}

impl Default for Icicles {
    fn default() -> Self {
        Icicles::new()
    }
}

impl Icicles {
    pub fn new() -> Icicles {
        let seed = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(1, |d| d.subsec_nanos()) | 1;
        Icicles { enabled: true, eaves: HashMap::new(), away: HashMap::new(), falling: Vec::new(), grown: 0.0, dirty: false, seed }
    }

    fn rand(&mut self, lower: f32, upper: f32) -> f32 {
        self.seed ^= self.seed << 13;
        self.seed ^= self.seed >> 17;
        self.seed ^= self.seed << 5;
        lower + (self.seed as f32 / u32::MAX as f32) * (upper - lower)
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }

    pub fn set_enabled(&mut self, on: bool) {
        self.enabled = on;
        if !on {
            self.drop_all();
        }
    }

    pub fn is_empty(&self) -> bool {
        self.falling.is_empty() && self.eaves.values().all(|eave| eave.hanging.iter().all(|icicle| icicle.length < 0.3))
    }

    /// Icicles in the air need a smooth frame rate.
    pub fn is_falling(&self) -> bool {
        !self.falling.is_empty()
    }

    pub fn count(&self) -> usize {
        self.falling.len() + self.eaves.values().map(|eave| eave.hanging.len()).sum::<usize>()
    }

    /// Follows the windows on screen, with the frames of the windows in front of each along its bottom edge.
    /// Windows that are gone drop their icicles; those in `keep` (on another desktop) keep them. `sliding` is a
    /// whole desktop sliding past: the windows move without being moved, so nothing breaks.
    pub fn update(&mut self, surfaces: &[(WindowSurface, Vec<Rect>)], interval: f32, keep: &HashSet<WindowId>, sliding: bool) {
        if !self.enabled {
            return;
        }
        let mut seen = HashSet::new();
        for (surface, under) in surfaces {
            seen.insert(surface.id);
            let frame = surface.frame;
            let occluders: Vec<[f32; 4]> = under.iter().take(16).map(|b| [b.min_x(), b.min_y(), b.max_x(), b.max_y()]).collect();
            let existing = self.eaves.remove(&surface.id).or_else(|| self.away.remove(&surface.id));
            let Some(mut eave) = existing else {
                let hanging = self.make_hanging(frame.width);
                self.eaves.insert(surface.id, Eave { frame, velocity: V2::ZERO, hanging, occluders });
                self.dirty = true;
                continue;
            };
            let old = eave.frame;
            let resized = frame.width != old.width || frame.height != old.height;
            if frame.width != old.width {
                // Icicles keep to the edge that stays put: dragging the left edge slides them with the right one.
                if (frame.max_x() - old.max_x()).abs() < 0.5 {
                    let shift = frame.min_x() - old.min_x();
                    for icicle in &mut eave.hanging {
                        icicle.x -= shift;
                    }
                }
                let width = frame.width;
                let (outside, inside): (Vec<Hanging>, Vec<Hanging>) = eave.hanging.iter().partition(|icicle| icicle.x < 14.0 || icicle.x > width - 14.0);
                for icicle in outside {
                    self.drop(icicle, frame, V2::ZERO);
                }
                eave.hanging = inside;
            }
            // A poll after a long quiet spell means the window was at rest until now.
            let step = interval.max(1.0 / 120.0);
            let previous = if interval > 0.12 { V2::ZERO } else { eave.velocity };
            let raw = V2::new(frame.min_x() - old.min_x(), frame.min_y() - old.min_y()) / step;
            // Window positions come in unevenly while one is dragged; smoothing keeps a steady drag from reading as jolts.
            let velocity = previous + (raw - previous) * 0.4;
            if !sliding && !resized {
                let jolt = (velocity - previous).length() / step * 0.016;
                let force = (velocity.length() * 0.7).max(jolt);
                // Long ones snap first: a sharp jerk or a shake breaks them, a slow glide doesn't.
                let (snapped, kept): (Vec<Hanging>, Vec<Hanging>) =
                    eave.hanging.iter().partition(|icicle| icicle.length > 2.0 && force > 2400.0 - icicle.length * 50.0);
                for icicle in snapped {
                    self.drop(icicle, old, velocity);
                }
                eave.hanging = kept;
            }
            eave.frame = frame;
            eave.velocity = if sliding { V2::ZERO } else { velocity };
            eave.occluders = occluders;
            self.eaves.insert(surface.id, eave);
            self.dirty = true;
        }
        let gone: Vec<WindowId> = self.eaves.keys().filter(|id| !seen.contains(id)).copied().collect();
        for id in gone {
            let Some(eave) = self.eaves.remove(&id) else { continue };
            if keep.contains(&id) {
                self.away.insert(id, eave);
            } else {
                for icicle in eave.hanging.iter().filter(|icicle| icicle.length > 1.5) {
                    self.drop(*icicle, eave.frame, V2::new(0.0, -60.0));
                }
            }
            self.dirty = true;
        }
    }

    pub fn drop_all(&mut self) {
        let eaves: Vec<Eave> = self.eaves.drain().map(|(_, eave)| eave).collect();
        for eave in eaves {
            for icicle in eave.hanging.iter().filter(|icicle| icicle.length > 1.5) {
                self.drop(*icicle, eave.frame, V2::ZERO);
            }
        }
        self.away.clear();
        self.dirty = true;
    }

    /// Lets every icicle melt away at once, as when all the snow is cleared calmly.
    pub fn melt(&mut self) {
        self.eaves.clear();
        self.away.clear();
        self.falling.clear();
        self.dirty = true;
    }

    /// Grows the icicles under snowy windows and moves the falling ones, shattering them into the snow where they
    /// land. Returns whether anything visible changed.
    pub fn step(&mut self, dt: f32, snow: &mut SnowSimulation) -> bool {
        let mut changed = self.dirty || !self.falling.is_empty();
        self.dirty = false;
        for (id, eave) in &mut self.eaves {
            // They only grow under a window with snow on it, and only so long.
            if snow.snow_depth_on_window(*id) <= 1.5 {
                continue;
            }
            for icicle in eave.hanging.iter_mut().filter(|icicle| icicle.length < icicle.max_length) {
                let grow = icicle.rate * dt;
                icicle.length = (icicle.length + grow).min(icicle.max_length);
                self.grown += grow;
            }
        }
        if self.grown > 0.25 {
            self.grown = 0.0;
            changed = true;
        }
        let mut i = 0;
        while i < self.falling.len() {
            let piece = &mut self.falling[i];
            piece.velocity.y -= 2200.0 * dt;
            piece.velocity.x *= 1.0 - (dt * 0.6).min(1.0);
            piece.position += piece.velocity * dt;
            piece.angle += piece.spin * dt;
            let tip = piece.position.y - piece.length * piece.angle.cos();
            let floor = snow.ground_level(piece.position.x);
            if tip <= floor || piece.position.y < -80.0 {
                if piece.position.y > -40.0 {
                    let size = piece.length * piece.width;
                    snow.shatter_icicle(V2::new(piece.position.x, floor.max(0.0) + 2.0), size);
                }
                self.falling.swap_remove(i);
            } else {
                i += 1;
            }
        }
        changed
    }

    /// Writes the icicles to draw into `buffer`, grouped by the windows in front of them.
    pub fn write(&self, buffer: &mut [IcicleSprite]) -> Vec<IcicleGroup> {
        let mut groups = Vec::new();
        let mut offset = 0;
        for eave in self.eaves.values() {
            let start = offset;
            let (left, bottom) = (eave.frame.min_x(), eave.frame.min_y());
            if bottom <= 4.0 {
                continue;
            }
            for icicle in eave.hanging.iter().filter(|icicle| icicle.length >= 0.6) {
                if offset >= buffer.len() {
                    break;
                }
                buffer[offset] = IcicleSprite {
                    root: V2::new(left + icicle.x, bottom + 0.5),
                    length: icicle.length,
                    width: icicle.width * (0.45 + icicle.length / 10.0).min(1.0),
                    angle: 0.0,
                    seed: icicle.seed,
                    alpha: (icicle.length / 3.0).min(1.0),
                    padding: 0.0,
                };
                offset += 1;
            }
            if offset > start {
                groups.push(IcicleGroup { offset: start, count: offset - start, occluders: eave.occluders.clone() });
            }
        }
        let start = offset;
        for piece in &self.falling {
            if offset >= buffer.len() {
                break;
            }
            buffer[offset] = IcicleSprite {
                root: piece.position,
                length: piece.length,
                width: piece.width,
                angle: piece.angle,
                seed: piece.seed,
                alpha: 1.0,
                padding: 0.0,
            };
            offset += 1;
        }
        if offset > start {
            groups.push(IcicleGroup { offset: start, count: offset - start, occluders: Vec::new() });
        }
        groups
    }

    fn drop(&mut self, icicle: Hanging, frame: Rect, velocity: V2) {
        if icicle.length <= 1.0 || self.falling.len() >= 400 {
            return;
        }
        let jitter = V2::new(self.rand(-40.0, 40.0), self.rand(-20.0, 30.0));
        let spin = self.rand(-3.0, 3.0) + velocity.x * 0.002;
        self.falling.push(Falling {
            position: V2::new(frame.min_x() + icicle.x, frame.min_y()),
            velocity: velocity * 0.6 + jitter,
            length: icicle.length,
            width: icicle.width,
            angle: 0.0,
            spin,
            seed: icicle.seed,
        });
        self.dirty = true;
    }

    /// Irregularly spaced, mostly short, with a few long ones, and none near the rounded corners.
    fn make_hanging(&mut self, width: f32) -> Vec<Hanging> {
        let mut result = Vec::new();
        let inset = 16.0;
        let mut x = inset + self.rand(0.0, 14.0);
        while x < width - inset {
            let max_length = 3.0 + self.rand(0.0, 1.0).powf(2.4) * 30.0;
            let width = 1.1 + max_length * 0.07 + self.rand(0.0, 0.7);
            let seed = self.rand(0.0, 1.0);
            let rate = max_length / self.rand(50.0, 140.0);
            result.push(Hanging { x, length: 0.0, max_length, width, seed, rate });
            x += self.rand(7.0, 34.0);
        }
        result
    }
}
