//! Rain: streaks that beat down and splash where they land, and drops on the windows' glass that run down it in
//! lurches, leave a trail of beads, gather what they meet, hang under the bottom edge until they let go, smear under
//! the cursor and fly off a shaken window. Nothing piles up. Written for Snowpuff; the Mac app has the same in Swift.
//!
//! Points with y up, as in the rest of the simulation. Drops on the glass keep their place on their window, measured
//! from its left edge and down from its top, so they ride along when it moves.

use std::collections::HashMap;
use std::hash::{BuildHasher, Hasher};

use crate::geometry::{Rect, V2};
use crate::simulation::{Snowfall, Sprite, WindowId};

/// How hard it rains at each setting of the intensity slider; none while it is off.
pub fn intensity(snowfall: Snowfall) -> f32 {
    match snowfall {
        Snowfall::Off => 0.0,
        Snowfall::Light => 0.4,
        Snowfall::Heavy => 2.2,
        _ => 1.0,
    }
}

/// What the rain needs of a window: where it is and which windows are in front of it.
#[derive(Clone, Debug)]
pub struct RainWindow {
    pub id: WindowId,
    pub frame: Rect,
    /// Frames of the windows in front of this one: drops behind them don't show.
    pub fronts: Vec<Rect>,
    /// The Dock or the taskbar: rain splashes on it but no drops run down it.
    pub ledge_only: bool,
}

/// Sprite kinds, in a sprite's `leaf[0]`, below zero so they never pass for a leaf.
pub const STREAK: f32 = -1.0;
pub const BEAD: f32 = -2.0;
pub const SPRAY: f32 = -3.0;

const GRAVITY: f32 = 1500.0;
/// Of the streaks that hit a window's top, how many leave a drop on its glass.
const STICKING: f32 = 0.07;
const MAX_DROPS: usize = 700;
const MAX_TRAIL: usize = 1600;

#[derive(Clone, Copy)]
struct Streak {
    position: V2,
    velocity: V2,
    /// 0.55 far away to 1 near: far streaks are thinner and fainter and pass behind the windows.
    depth: f32,
}

/// A droplet in the air: a splash's spray, or a drop that let go of a window.
#[derive(Clone, Copy)]
struct Spray {
    position: V2,
    velocity: V2,
    size: f32,
    age: f32,
    life: f32,
    /// A drop fallen off a window splashes again where it lands; spray just fades.
    lands: bool,
}

#[derive(Clone, Copy, PartialEq)]
enum Motion {
    /// Clinging to the glass for this much longer.
    Resting(f32),
    /// Running down at this speed for this much longer.
    Running { speed: f32, left: f32 },
    /// Under the bottom edge, swelling until it lets go.
    Hanging,
}

#[derive(Clone, Copy)]
struct Drop {
    window: WindowId,
    /// From the window's left edge, and down from its top.
    x: f32,
    down: f32,
    size: f32,
    motion: Motion,
    /// How far it has run since it last left a bead behind.
    since_bead: f32,
    wobble: f32,
}

/// A bead left behind on the glass: it stays put and dries.
#[derive(Clone, Copy)]
struct Bead {
    window: WindowId,
    x: f32,
    down: f32,
    size: f32,
    age: f32,
    life: f32,
}

#[derive(Clone)]
struct Pane {
    frame: Rect,
    fronts: Vec<Rect>,
    ledge_only: bool,
    velocity: V2,
}

pub struct Rain {
    width: f32,
    height: f32,
    /// Raining, rather than letting the last of it run off.
    on: bool,
    /// Light 0.4, steady 1, heavy 2.2.
    intensity: f32,
    /// Leaning of the streaks: their sideways speed for each point a second they fall.
    pub slant: f32,
    streaks: Vec<Streak>,
    spray: Vec<Spray>,
    drops: Vec<Drop>,
    beads: Vec<Bead>,
    panes: HashMap<WindowId, Pane>,
    owed: f32,
    random: u64,
    last_cursor: Option<V2>,
}

impl Rain {
    pub fn new(width: f32, height: f32) -> Rain {
        let seed = std::collections::hash_map::RandomState::new().build_hasher().finish().max(1);
        Rain {
            width,
            height,
            on: false,
            intensity: 1.0,
            slant: -0.12,
            streaks: Vec::new(),
            spray: Vec::new(),
            drops: Vec::new(),
            beads: Vec::new(),
            panes: HashMap::new(),
            owed: 0.0,
            random: seed,
            last_cursor: None,
        }
    }

    pub fn resize(&mut self, width: f32, height: f32) {
        self.width = width;
        self.height = height;
    }

    pub fn set_on(&mut self, on: bool) {
        self.on = on;
    }

    pub fn is_on(&self) -> bool {
        self.on
    }

    pub fn set_intensity(&mut self, intensity: f32) {
        self.intensity = intensity.max(0.0);
    }

    /// Anything left to draw or move.
    pub fn is_active(&self) -> bool {
        self.on || !self.streaks.is_empty() || !self.spray.is_empty() || !self.drops.is_empty() || !self.beads.is_empty()
    }

    pub fn sprite_count(&self) -> usize {
        self.streaks.len() + self.spray.len() + self.drops.len() + self.beads.len()
    }

    /// Knocks everything off the glass, as clearing the screen does.
    pub fn clear(&mut self) {
        let drops = std::mem::take(&mut self.drops);
        for drop in drops {
            if let Some(at) = self.place(drop.window, drop.x, drop.down) {
                self.spray.push(Spray { position: at, velocity: V2::new(0.0, -60.0), size: drop.size * 0.8, age: 0.0, life: 3.0, lands: true });
            }
        }
        self.beads.clear();
    }

    /// The windows now and how long since the last time, to tell how fast each moves: a shaken window throws its drops off.
    pub fn update_windows(&mut self, windows: &[RainWindow], interval: f32) {
        let mut panes = HashMap::with_capacity(windows.len());
        for window in windows {
            let velocity = match self.panes.get(&window.id) {
                Some(old) if interval > 0.0 => {
                    let moved = V2::new(window.frame.x - old.frame.x, window.frame.max_y() - old.frame.max_y());
                    moved * (1.0 / interval.max(1.0 / 120.0))
                }
                _ => V2::ZERO,
            };
            panes.insert(
                window.id,
                Pane { frame: window.frame, fronts: window.fronts.clone(), ledge_only: window.ledge_only, velocity },
            );
        }
        // Drops on a window that went, or that was shaken hard, fall; beads on it are gone.
        let mut thrown = Vec::new();
        self.drops.retain(|drop| {
            let pane = panes.get(&drop.window);
            let shaken = pane.is_some_and(|pane| pane.velocity.length() > 1400.0);
            let resized = pane.is_some_and(|pane| drop.x > pane.frame.width || drop.down > pane.frame.height + 2.0);
            if pane.is_none() || shaken || resized {
                thrown.push((*drop, pane.map_or(V2::ZERO, |pane| pane.velocity)));
                false
            } else {
                true
            }
        });
        for (drop, velocity) in thrown {
            if let Some(at) = self.place(drop.window, drop.x, drop.down) {
                let push = velocity * 0.55 + V2::new(self.range(-40.0, 40.0), self.range(-20.0, 60.0));
                self.spray.push(Spray { position: at, velocity: push, size: drop.size * 0.8, age: 0.0, life: 3.0, lands: true });
            }
        }
        self.beads.retain(|bead| {
            panes.get(&bead.window).is_some_and(|pane| pane.velocity.length() <= 1400.0 && bead.x <= pane.frame.width && bead.down <= pane.frame.height)
        });
        self.panes = panes;
    }

    /// Moves everything on by `dt` seconds. `ground` is where the bottom of the screen catches the rain at an x.
    /// Returns whether anything is left to draw.
    pub fn step(&mut self, dt: f32, cursor: Option<V2>, ground: impl Fn(f32) -> f32) -> bool {
        let dt = dt.clamp(0.0, 0.05);
        self.spawn(dt);
        self.fall(dt, &ground);
        self.fly(dt, &ground);
        self.run(dt);
        if let Some(cursor) = cursor {
            if let Some(last) = self.last_cursor {
                self.smear(last, cursor, dt);
            }
        }
        self.last_cursor = cursor;
        for bead in &mut self.beads {
            bead.age += dt;
        }
        self.beads.retain(|bead| bead.age < bead.life);
        self.is_active()
    }

    fn spawn(&mut self, dt: f32) {
        if !self.on {
            return;
        }
        // About 150 streaks in the air over every 1000 points of width on a steady rain.
        let rate = self.width / 1000.0 * 165.0 * self.intensity;
        self.owed += rate * dt;
        // Leaning streaks drift sideways as they fall: they start upwind of where they will land.
        let drift = -self.slant * self.height;
        while self.owed >= 1.0 {
            self.owed -= 1.0;
            let depth = self.range(0.55, 1.0);
            let speed = self.range(900.0, 1250.0) * (0.75 + 0.25 * depth);
            let x = self.range((-drift).min(0.0) - 20.0, self.width + (-drift).max(0.0) + 20.0);
            let y = self.height + self.range(10.0, 160.0);
            self.streaks.push(Streak { position: V2::new(x, y), velocity: V2::new(-self.slant * speed, -speed), depth });
        }
    }

    fn fall(&mut self, dt: f32, ground: &impl Fn(f32) -> f32) {
        let mut hits: Vec<(V2, Option<WindowId>, f32)> = Vec::new();
        let panes: Vec<(WindowId, Pane)> = self.panes.iter().map(|(id, pane)| (*id, pane.clone())).collect();
        self.streaks.retain_mut(|streak| {
            let from = streak.position;
            streak.position += streak.velocity * dt;
            let to = streak.position;
            // Far streaks pass behind the windows and fade out somewhere low on the screen.
            if streak.depth < 0.72 {
                return to.y > ground(to.x).max(0.0) + (1.0 - streak.depth) * 220.0;
            }
            let mut landed: Option<(f32, Option<WindowId>)> = None;
            for (id, pane) in &panes {
                let top = pane.frame.max_y();
                if from.y >= top && to.y < top {
                    let t = (from.y - top) / (from.y - to.y).max(1e-3);
                    let x = from.x + (to.x - from.x) * t;
                    if x >= pane.frame.x && x <= pane.frame.max_x() && !hidden(&pane.fronts, V2::new(x, top)) && landed.is_none_or(|(y, _)| top > y) {
                        landed = Some((top, Some(*id)));
                    }
                }
            }
            let floor = ground(to.x).max(0.0);
            if landed.is_none() && to.y <= floor {
                landed = Some((floor, None));
            }
            match landed {
                Some((y, window)) => {
                    let t = (from.y - y) / (from.y - to.y).max(1e-3);
                    hits.push((V2::new(from.x + (to.x - from.x) * t, y), window, streak.depth));
                    false
                }
                None => to.y > -50.0,
            }
        });
        for (at, window, depth) in hits {
            self.splash(at, depth);
            if let Some(window) = window
                && self.drops.len() < MAX_DROPS
                && self.next() < STICKING
                && let Some(pane) = self.panes.get(&window)
                && !pane.ledge_only
            {
                let (x, size, rest, down) =
                    (at.x - pane.frame.x, self.range(3.0, 5.8), self.range(0.3, 3.5), self.range(1.5, 5.0));
                let wobble = self.range(0.0, 6.28);
                self.drops.push(Drop { window, x, down, size, motion: Motion::Resting(rest), since_bead: 0.0, wobble });
            }
        }
    }

    fn splash(&mut self, at: V2, strength: f32) {
        let count = 2 + (self.next() * 3.0 * strength) as usize;
        for _ in 0..count {
            let velocity = V2::new(self.range(-150.0, 150.0), self.range(60.0, 230.0) * strength);
            let (size, life) = (self.range(0.9, 1.8), self.range(0.22, 0.42));
            self.spray.push(Spray { position: at + V2::new(0.0, 1.0), velocity, size, age: 0.0, life, lands: false });
        }
    }

    fn fly(&mut self, dt: f32, ground: &impl Fn(f32) -> f32) {
        let mut landed = Vec::new();
        let panes: Vec<Pane> = self.panes.values().cloned().collect();
        self.spray.retain_mut(|spray| {
            spray.age += dt;
            let from = spray.position;
            spray.velocity.y -= GRAVITY * dt;
            spray.position += spray.velocity * dt;
            if !spray.lands {
                return spray.age < spray.life;
            }
            let to = spray.position;
            let on_window = panes.iter().any(|pane| {
                let top = pane.frame.max_y();
                from.y >= top && to.y < top && to.x >= pane.frame.x && to.x <= pane.frame.max_x() && !hidden(&pane.fronts, V2::new(to.x, top))
            });
            if on_window || to.y <= ground(to.x).max(0.0) {
                landed.push(to);
                return false;
            }
            spray.age < spray.life && to.y > -20.0
        });
        for at in landed {
            self.splash(at, 0.6);
        }
    }

    /// Drops on the glass: they rest, run a little, rest again, leave beads, take in what they run into, and hang
    /// under the bottom edge until heavy enough to let go.
    fn run(&mut self, dt: f32) {
        let mut released = Vec::new();
        let mut left_beads = Vec::new();
        let mut drops = std::mem::take(&mut self.drops);
        for drop in &mut drops {
            let Some(height) = self.panes.get(&drop.window).map(|pane| pane.frame.height) else { continue };
            match drop.motion {
                Motion::Resting(left) => {
                    // Heavier drops give way sooner.
                    let left = left - dt * (drop.size / 3.0);
                    drop.motion = if left <= 0.0 {
                        Motion::Running { speed: self.range(25.0, 70.0) * drop.size / 3.0, left: self.range(0.15, 1.1) }
                    } else {
                        Motion::Resting(left)
                    };
                }
                Motion::Running { speed, left } => {
                    let moved = speed * dt;
                    drop.down += moved;
                    drop.wobble += dt * 3.0;
                    drop.x += drop.wobble.sin() * moved * 0.12;
                    drop.since_bead += moved;
                    if drop.since_bead > self.range(5.0, 11.0) && drop.size > 1.6 {
                        drop.since_bead = 0.0;
                        let size = drop.size * self.range(0.28, 0.45);
                        left_beads.push(Bead { window: drop.window, x: drop.x, down: drop.down - drop.size * 0.4, size, age: 0.0, life: self.range(5.0, 11.0) });
                        drop.size = (drop.size * drop.size - size * size * 0.5).max(1.0).sqrt();
                    }
                    let left = left - dt;
                    drop.motion = if left <= 0.0 { Motion::Resting(self.range(0.1, 1.6)) } else { Motion::Running { speed, left } };
                    if drop.down >= height - drop.size * 0.3 {
                        drop.down = height;
                        drop.motion = Motion::Hanging;
                    }
                }
                Motion::Hanging => {
                    drop.size += dt * 0.9;
                    if drop.size > 7.4 {
                        released.push(*drop);
                        drop.size = 0.0;
                    }
                }
            }
        }
        drops.retain(|drop| drop.size > 0.0);
        // A running drop takes in the beads it runs over.
        let mut beads = std::mem::take(&mut self.beads);
        for drop in drops.iter_mut().filter(|drop| matches!(drop.motion, Motion::Running { .. })) {
            beads.retain(|bead| {
                let near = bead.window == drop.window
                    && (bead.x - drop.x).abs() < drop.size * 0.6 + bead.size
                    && bead.down > drop.down - drop.size
                    && bead.down < drop.down + drop.size * 0.5;
                if near {
                    drop.size = (drop.size * drop.size + bead.size * bead.size).sqrt().min(8.0);
                }
                !near
            });
        }
        beads.extend(left_beads);
        if beads.len() > MAX_TRAIL {
            let extra = beads.len() - MAX_TRAIL;
            beads.drain(..extra);
        }
        self.beads = beads;
        self.drops = drops;
        for drop in released {
            if let Some(at) = self.place(drop.window, drop.x, drop.down + drop.size * 0.5) {
                self.spray.push(Spray { position: at, velocity: V2::new(0.0, -40.0), size: drop.size * 0.75, age: 0.0, life: 3.0, lands: true });
            }
        }
    }

    /// The cursor moving through drops knocks hanging ones off and drags the others along, smeared into beads.
    fn smear(&mut self, from: V2, to: V2, dt: f32) {
        let moved = to - from;
        if moved.length() < 1.5 || dt <= 0.0 {
            return;
        }
        let velocity = moved * (1.0 / dt.max(1e-3));
        let mut knocked = Vec::new();
        let mut smeared = Vec::new();
        let mut drops = std::mem::take(&mut self.drops);
        for drop in &mut drops {
            let Some(pane) = self.panes.get(&drop.window) else { continue };
            let at = V2::new(pane.frame.x + drop.x, pane.frame.max_y() - drop.down);
            if hidden(&pane.fronts, at) || distance_to_segment(at, from, to) > 10.0 + drop.size {
                continue;
            }
            if drop.motion == Motion::Hanging {
                knocked.push((*drop, velocity * 0.4));
                drop.size = 0.0;
                continue;
            }
            let push = V2::new(moved.x, -moved.y) * 0.7;
            let steps = (push.length() / 4.0).ceil().clamp(1.0, 6.0) as usize;
            for k in 0..steps {
                let along = k as f32 / steps as f32;
                smeared.push((drop.window, drop.x + push.x * along, drop.down + push.y * along, drop.size * 0.35));
            }
            drop.x = (drop.x + push.x).clamp(0.0, pane.frame.width);
            drop.down = (drop.down + push.y).clamp(0.0, pane.frame.height);
            drop.size = (drop.size * 0.85).max(1.2);
            drop.motion = Motion::Resting(0.6);
        }
        drops.retain(|drop| drop.size > 0.0);
        self.drops = drops;
        for (window, x, down, size) in smeared {
            let life = self.range(3.0, 7.0);
            self.beads.push(Bead { window, x, down, size, age: 0.0, life });
        }
        for (drop, velocity) in knocked {
            if let Some(at) = self.place(drop.window, drop.x, drop.down) {
                self.spray.push(Spray { position: at, velocity, size: drop.size * 0.75, age: 0.0, life: 3.0, lands: true });
            }
        }
    }

    fn place(&self, window: WindowId, x: f32, down: f32) -> Option<V2> {
        self.panes.get(&window).map(|pane| V2::new(pane.frame.x + x, pane.frame.max_y() - down))
    }

    /// Writes the rain's sprites after what is already in `out`, returning how many.
    pub fn write(&self, out: &mut [Sprite]) -> usize {
        let mut n = 0;
        let mut put = |sprite: Sprite| {
            if n < out.len() {
                out[n] = sprite;
                n += 1;
            }
        };
        for streak in &self.streaks {
            put(Sprite {
                position: streak.position,
                velocity: streak.velocity,
                size: 0.9 + streak.depth * 0.7,
                alpha: 0.12 + streak.depth * 0.26,
                leaf: [STREAK, 0.0, 0.0],
                ..Default::default()
            });
        }
        for spray in &self.spray {
            let fade = if spray.lands { 1.0 } else { 1.0 - spray.age / spray.life };
            put(Sprite { position: spray.position, velocity: spray.velocity, size: spray.size, alpha: 0.55 * fade, leaf: [SPRAY, 0.0, 0.0], ..Default::default() });
        }
        for bead in &self.beads {
            let Some(pane) = self.panes.get(&bead.window) else { continue };
            let at = V2::new(pane.frame.x + bead.x, pane.frame.max_y() - bead.down);
            if hidden(&pane.fronts, at) {
                continue;
            }
            let fade = 1.0 - (bead.age / bead.life).powi(3);
            put(Sprite { position: at, size: bead.size, alpha: 0.9 * fade, leaf: [BEAD, 1.0, 0.0], ..Default::default() });
        }
        for drop in &self.drops {
            let Some(pane) = self.panes.get(&drop.window) else { continue };
            let at = V2::new(pane.frame.x + drop.x, pane.frame.max_y() - drop.down);
            if hidden(&pane.fronts, at) {
                continue;
            }
            // Running drops stretch along their run; hanging ones swell into a teardrop.
            let stretch = match drop.motion {
                Motion::Running { speed, .. } => 1.0 + (speed / 120.0).min(0.6),
                Motion::Hanging => 1.0 + (drop.size - 4.0).max(0.0) * 0.12,
                Motion::Resting(_) => 1.0,
            };
            put(Sprite { position: at, size: drop.size, alpha: 0.95, leaf: [BEAD, stretch, 0.0], ..Default::default() });
        }
        n
    }

    fn next(&mut self) -> f32 {
        self.random ^= self.random << 13;
        self.random ^= self.random >> 7;
        self.random ^= self.random << 17;
        (self.random >> 40) as f32 / (1u32 << 24) as f32
    }

    fn range(&mut self, lower: f32, upper: f32) -> f32 {
        lower + (upper - lower) * self.next()
    }
}

fn hidden(fronts: &[Rect], at: V2) -> bool {
    fronts.iter().any(|front| at.x >= front.x && at.x <= front.max_x() && at.y >= front.y && at.y <= front.max_y())
}

fn distance_to_segment(p: V2, a: V2, b: V2) -> f32 {
    let ab = b - a;
    let t = ((p - a).dot(ab) / ab.length_squared().max(1e-6)).clamp(0.0, 1.0);
    (p - (a + ab * t)).length()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn window(id: WindowId, x: f32, y: f32, width: f32, height: f32) -> RainWindow {
        RainWindow { id, frame: Rect { x, y, width, height }, fronts: Vec::new(), ledge_only: false }
    }

    fn run(rain: &mut Rain, seconds: f32) {
        let steps = (seconds * 60.0) as usize;
        for _ in 0..steps {
            rain.step(1.0 / 60.0, None, |_| 0.0);
        }
    }

    #[test]
    fn rain_falls_splashes_and_leaves_drops_on_glass() {
        let mut rain = Rain::new(1200.0, 800.0);
        rain.set_on(true);
        rain.update_windows(&[window(1, 200.0, 100.0, 800.0, 500.0)], 0.0);
        run(&mut rain, 6.0);
        assert!(rain.streaks.len() > 60, "streaks: {}", rain.streaks.len());
        assert!(!rain.drops.is_empty(), "no drops on the glass");
        assert!(rain.drops.iter().all(|drop| drop.x >= 0.0 && drop.x <= 800.0));
        assert!(rain.sprite_count() > 0);
        let mut sprites = vec![Sprite::default(); rain.sprite_count()];
        assert_eq!(rain.write(&mut sprites), rain.sprite_count());
    }

    #[test]
    fn drops_run_down_hang_and_let_go() {
        let mut rain = Rain::new(1200.0, 800.0);
        rain.set_on(true);
        rain.update_windows(&[window(1, 200.0, 300.0, 800.0, 120.0)], 0.0);
        run(&mut rain, 4.0);
        rain.set_on(false);
        run(&mut rain, 60.0);
        // With the rain over, everything runs off: no drop is left clinging forever, nothing piles up.
        assert!(rain.drops.is_empty(), "drops left: {}", rain.drops.len());
        assert!(rain.streaks.is_empty());
    }

    #[test]
    fn shaking_a_window_throws_its_drops_off() {
        let mut rain = Rain::new(1200.0, 800.0);
        rain.set_on(true);
        rain.update_windows(&[window(1, 200.0, 100.0, 800.0, 500.0)], 0.0);
        run(&mut rain, 6.0);
        assert!(!rain.drops.is_empty());
        rain.update_windows(&[window(1, 260.0, 100.0, 800.0, 500.0)], 1.0 / 60.0);
        assert!(rain.drops.is_empty());
        assert!(rain.spray.iter().any(|spray| spray.lands));
    }

    #[test]
    fn drops_behind_a_window_in_front_stay_hidden() {
        let mut rain = Rain::new(1200.0, 800.0);
        rain.set_on(true);
        let mut back = window(1, 0.0, 0.0, 1200.0, 600.0);
        back.fronts = vec![Rect { x: 0.0, y: 0.0, width: 1200.0, height: 800.0 }];
        rain.update_windows(&[back], 0.0);
        run(&mut rain, 6.0);
        // Its whole top is behind the front window, so no rain reaches its glass.
        assert!(rain.drops.is_empty());
    }
}
