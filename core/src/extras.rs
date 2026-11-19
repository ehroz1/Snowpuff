//! Snowpuff's extras over the weather: a swirl behind a fast cursor, hail, fog, stars and meteors at night, a
//! garland along the top, fireworks, snowballs, snowmen, a cat in a drift, a bullfinch on a window, a sudden flurry,
//! and frost or mist on the edges of the screen that the cursor draws in. Platform-free: both apps feed it the
//! cursor, the windows and the drift along the bottom, and draw the sprites and the frost it gives back.
//!
//! Points with y up. Sprites use the same layout as the snow; kinds below zero in `leaf[0]` pick what is drawn.

use std::f32::consts::{PI, TAU};
use std::hash::{BuildHasher, Hasher};

use crate::geometry::V2;
use crate::rain::RainWindow;
use crate::sfx::Cue;
use crate::simulation::Sprite;

pub const GLOW: f32 = -4.0;
pub const SNOWMAN: f32 = -5.0;
pub const CAT: f32 = -6.0;
pub const BIRD: f32 = -7.0;
pub const FOG: f32 = -8.0;
pub const HAIL: f32 = -9.0;
pub const SNOWBALL: f32 = -10.0;
pub const BULB: f32 = -11.0;
pub const WIRE: f32 = -12.0;

/// What falls: the extras that belong to one weather step aside in another.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Weather {
    Snow,
    Leaves,
    Petals,
    Rain,
    Hail,
}

#[derive(Clone, Copy, Debug)]
pub struct Settings {
    pub weather: Weather,
    /// How hard it falls, 0 to about 2: hail follows it.
    pub intensity: f32,
    pub blizzard: bool,
    pub fog: bool,
    pub stars: bool,
    pub garland: bool,
    pub frost: bool,
    /// The cat and the bullfinch.
    pub creatures: bool,
}

impl Default for Settings {
    fn default() -> Settings {
        Settings { weather: Weather::Snow, intensity: 1.0, blizzard: true, fog: false, stars: true, garland: false, frost: true, creatures: true }
    }
}

/// What the app tells the extras each frame.
#[derive(Clone, Copy, Debug, Default)]
pub struct Input {
    pub dt: f32,
    /// The cursor on this screen, if it is on it.
    pub cursor: Option<V2>,
    /// The main mouse button is down.
    pub button: bool,
    /// The modifier that makes the cursor reach into the scene is held: Option on the Mac, Alt on Windows.
    pub magic: bool,
    /// 0 at night to 1 by day.
    pub daylight: f32,
    /// Room taken along the top, as by the menu bar: the garland hangs below it.
    pub top_inset: f32,
}

const GROUND_STEP: f32 = 4.0;
const FROST_CELL: f32 = 8.0;

#[derive(Clone, Copy)]
struct Particle {
    position: V2,
    velocity: V2,
    size: f32,
    alpha: f32,
    age: f32,
    life: f32,
    color: [f32; 3],
    /// Gravity on it, and how much air holds it back.
    gravity: f32,
    drag: f32,
    /// Drawn as a soft glow rather than a flake.
    glow: bool,
    /// A firework spark: leaves a fading trail, twinkles as it dies, or crackles apart at the end.
    trail: bool,
    glitter: bool,
    crackle: bool,
}

#[derive(Clone, Copy)]
struct Hailstone {
    position: V2,
    velocity: V2,
    size: f32,
    bounces: u32,
    resting: f32,
}

#[derive(Clone, Copy)]
struct Puff {
    position: V2,
    drift: f32,
    size: f32,
    alpha: f32,
    seed: f32,
    thinned: f32,
}

#[derive(Clone, Copy)]
struct Star {
    position: V2,
    size: f32,
    seed: f32,
}

#[derive(Clone, Copy)]
struct Meteor {
    position: V2,
    velocity: V2,
    age: f32,
}

#[derive(Clone, Copy)]
struct Rocket {
    position: V2,
    velocity: V2,
    burst_at: f32,
    color: [f32; 3],
    second: [f32; 3],
    kind: Burst,
}

/// The shapes a firework bursts into.
#[derive(Clone, Copy, PartialEq)]
enum Burst {
    /// A full round ball of stars.
    Peony,
    /// Stars that each leave a glittering tail.
    Chrysanthemum,
    /// Slow gold stars drooping into long weeping trails.
    Willow,
    /// A ring, tilted.
    Ring,
    /// A ball in one colour inside a ball in another.
    TwoTone,
    /// Stars that crackle apart into white sparks at the end.
    Crackle,
}

#[derive(Clone, Copy)]
struct Snowball {
    from: V2,
    to: V2,
    age: f32,
    flight: f32,
}

#[derive(Clone, Copy)]
struct Splat {
    position: V2,
    age: f32,
    seed: f32,
}

#[derive(Clone, Copy)]
struct Snowman {
    x: f32,
    built: f32,
    seed: f32,
    /// Melting away: the drift under it went.
    melting: bool,
    look: f32,
}

#[derive(Clone, Copy, PartialEq)]
enum CatState {
    Waiting(f32),
    Rising,
    Looking(f32),
    Sinking,
}

#[derive(Clone, Copy)]
struct Cat {
    x: f32,
    rise: f32,
    seed: f32,
    look: f32,
    blink: f32,
    state: CatState,
}

#[derive(Clone, Copy, PartialEq)]
enum BirdState {
    Waiting(f32),
    Arriving,
    Perched(f32),
    Leaving,
}

#[derive(Clone, Copy)]
struct Bird {
    state: BirdState,
    window: isize,
    /// Along the window's top from its left edge.
    x: f32,
    position: V2,
    from: V2,
    to: V2,
    flight: f32,
    age: f32,
    facing: f32,
    wing: f32,
    peck: f32,
    hop: f32,
}

pub struct Extras {
    pub settings: Settings,
    width: f32,
    height: f32,
    clock: f32,
    random: u64,
    ground: Vec<f32>,
    windows: Vec<RainWindow>,
    covers: Vec<[f32; 4]>,
    particles: Vec<Particle>,
    hail: Vec<Hailstone>,
    hail_owed: f32,
    puffs: Vec<Puff>,
    stars: Vec<Star>,
    meteor: Option<Meteor>,
    next_meteor: f32,
    rockets: Vec<Rocket>,
    fireworks_left: f32,
    next_rocket: f32,
    snowballs: Vec<Snowball>,
    splats: Vec<Splat>,
    snowmen: Vec<Snowman>,
    building: Option<(f32, f32)>,
    cat: Cat,
    bird: Bird,
    flurry_left: f32,
    flurry_owed: f32,
    last_cursor: Option<V2>,
    was_pressed: bool,
    cues: Vec<Cue>,
    crunch_cooldown: f32,
    daylight: f32,
    top_inset: f32,
    frost: Vec<f32>,
    frost_rest: Vec<f32>,
    frost_columns: usize,
    frost_rows: usize,
    frost_changed: bool,
    /// Where the frost would settle in, worked out once for the size and the weather.
    frost_target: Vec<f32>,
    frost_target_for: Option<(bool, u32)>,
    /// Time gathered toward the next slow frost update.
    frost_tick: f32,
    /// Some frost is on the glass.
    frost_any: bool,
}

impl Extras {
    pub fn new(width: f32, height: f32) -> Extras {
        let seed = std::collections::hash_map::RandomState::new().build_hasher().finish().max(1);
        let mut extras = Extras {
            settings: Settings::default(),
            width,
            height,
            clock: 0.0,
            random: seed,
            ground: Vec::new(),
            windows: Vec::new(),
            covers: Vec::new(),
            particles: Vec::new(),
            hail: Vec::new(),
            hail_owed: 0.0,
            puffs: Vec::new(),
            stars: Vec::new(),
            meteor: None,
            next_meteor: 30.0,
            rockets: Vec::new(),
            fireworks_left: 0.0,
            next_rocket: 0.0,
            snowballs: Vec::new(),
            splats: Vec::new(),
            snowmen: Vec::new(),
            building: None,
            cat: Cat { x: 0.0, rise: 0.0, seed: 0.5, look: 0.0, blink: 0.0, state: CatState::Waiting(150.0) },
            bird: Bird {
                state: BirdState::Waiting(90.0),
                window: 0,
                x: 0.0,
                position: V2::ZERO,
                from: V2::ZERO,
                to: V2::ZERO,
                flight: 1.0,
                age: 0.0,
                facing: 1.0,
                wing: 0.0,
                peck: 0.0,
                hop: 0.0,
            },
            flurry_left: 0.0,
            flurry_owed: 0.0,
            last_cursor: None,
            was_pressed: false,
            cues: Vec::new(),
            crunch_cooldown: 0.0,
            daylight: 1.0,
            top_inset: 0.0,
            frost: Vec::new(),
            frost_rest: Vec::new(),
            frost_columns: 0,
            frost_rows: 0,
            frost_changed: true,
            frost_target: Vec::new(),
            frost_target_for: None,
            frost_tick: 0.0,
            frost_any: false,
        };
        extras.resize(width, height);
        extras.cat.state = CatState::Waiting(extras.range(90.0, 240.0));
        extras.bird.state = BirdState::Waiting(extras.range(60.0, 150.0));
        extras
    }

    pub fn resize(&mut self, width: f32, height: f32) {
        self.width = width;
        self.height = height;
        self.stars.clear();
        let count = (width * height / 9000.0) as usize;
        for _ in 0..count {
            let position = V2::new(self.range(0.0, width), self.range(height * 0.35, height));
            let size = self.range(1.4, 2.8) * if self.next() < 0.08 { 1.5 } else { 1.0 };
            let seed = self.next();
            self.stars.push(Star { position, size, seed });
        }
        self.puffs.clear();
        self.frost_columns = (width / FROST_CELL).ceil() as usize + 1;
        self.frost_rows = (height / FROST_CELL).ceil() as usize + 1;
        self.frost = vec![0.0; self.frost_columns * self.frost_rows];
        self.frost_rest = vec![0.0; self.frost_columns * self.frost_rows];
        self.frost_changed = true;
        self.frost_target_for = None;
    }

    /// The top of the drift along the bottom of the screen, every few points across it.
    pub fn set_ground(&mut self, heights: &[f32]) {
        self.ground.clear();
        self.ground.extend_from_slice(heights);
    }

    /// Samples a ground function every few points across the screen.
    pub fn sample_ground(&mut self, ground: impl Fn(f32) -> f32) {
        let count = (self.width / GROUND_STEP) as usize + 2;
        self.ground.clear();
        self.ground.extend((0..count).map(|i| ground(i as f32 * GROUND_STEP)));
    }

    pub fn set_windows(&mut self, windows: &[RainWindow]) {
        self.windows.clear();
        self.windows.extend(windows.iter().filter(|window| !window.ledge_only).cloned());
    }

    /// Every app window on the screen, left, bottom, right, top: stars don't show over them.
    pub fn set_covers(&mut self, covers: &[[f32; 4]]) {
        self.covers.clear();
        self.covers.extend_from_slice(covers);
    }

    fn ground_at(&self, x: f32) -> f32 {
        if self.ground.is_empty() {
            return 0.0;
        }
        let f = (x / GROUND_STEP).clamp(0.0, (self.ground.len() - 1) as f32);
        let i = f.floor() as usize;
        let j = (i + 1).min(self.ground.len() - 1);
        self.ground[i] + (self.ground[j] - self.ground[i]) * (f - i as f32)
    }

    fn covered(&self, at: V2) -> bool {
        self.covers.iter().any(|c| at.x >= c[0] && at.x <= c[2] && at.y >= c[1] && at.y <= c[3])
    }

    /// Big soft flakes for a few seconds, as when "snow" is typed.
    pub fn flurry(&mut self) {
        self.flurry_left = 7.0;
    }

    /// Fireworks for this many seconds, as at midnight on New Year.
    pub fn fireworks(&mut self, seconds: f32) {
        self.fireworks_left = self.fireworks_left.max(seconds);
        self.next_rocket = self.next_rocket.min(0.2);
    }

    pub fn fireworks_running(&self) -> bool {
        self.fireworks_left > 0.0 || !self.rockets.is_empty()
    }

    /// Melts the snowmen and clears the frost, as clearing the snow does.
    pub fn clear(&mut self) {
        for snowman in &mut self.snowmen {
            snowman.melting = true;
        }
        self.frost.iter_mut().for_each(|v| *v = 0.0);
        self.frost_rest.iter_mut().for_each(|v| *v = 6.0);
        self.frost_any = false;
        self.frost_changed = true;
        self.splats.clear();
    }

    /// The sounds asked for since the last call.
    pub fn take_cues(&mut self) -> Vec<Cue> {
        std::mem::take(&mut self.cues)
    }

    /// Anything moving or showing that needs frames drawn.
    pub fn is_active(&self) -> bool {
        !self.particles.is_empty()
            || !self.hail.is_empty()
            || (self.settings.weather == Weather::Hail && self.settings.intensity > 0.0)
            || !self.puffs.is_empty()
            || self.meteor.is_some()
            || self.fireworks_running()
            || !self.snowballs.is_empty()
            || !self.splats.is_empty()
            || !self.snowmen.is_empty()
            || self.building.is_some()
            || matches!(self.cat.state, CatState::Rising | CatState::Looking(_) | CatState::Sinking)
            || !matches!(self.bird.state, BirdState::Waiting(_))
            || self.flurry_left > 0.0
            || (self.settings.garland && !self.windows.is_empty())
            || (self.settings.stars && self.daylight < 0.35)
    }

    /// Something moving fast enough to want every frame the display offers, rather than the calm rate that does for
    /// twinkling lights and a still snowman.
    pub fn needs_smooth(&self) -> bool {
        !self.particles.is_empty()
            || !self.hail.is_empty()
            || !self.rockets.is_empty()
            || !self.snowballs.is_empty()
            || self.meteor.is_some()
            || matches!(self.bird.state, BirdState::Arriving | BirdState::Leaving)
            || matches!(self.cat.state, CatState::Rising | CatState::Sinking)
            || self.building.is_some()
    }

    pub fn step(&mut self, input: Input) {
        let dt = input.dt.clamp(0.0, 0.05);
        self.clock += dt;
        self.daylight = input.daylight;
        self.top_inset = input.top_inset;
        let cursor_velocity = match (input.cursor, self.last_cursor) {
            (Some(now), Some(then)) if dt > 0.0 => (now - then) * (1.0 / dt),
            _ => V2::ZERO,
        };
        let pressed = input.button && !self.was_pressed;
        self.was_pressed = input.button;

        self.blizzard(dt, input.cursor, cursor_velocity);
        self.step_particles(dt);
        self.step_hail(dt);
        self.step_fog(dt, input.cursor, cursor_velocity);
        self.step_sky(dt);
        self.step_fireworks(dt);
        if let Some(cursor) = input.cursor
            && pressed
            && input.magic
        {
            self.throw(cursor);
        }
        self.step_snowballs(dt);
        self.step_snowmen(dt, input.cursor, input.magic && !input.button, cursor_velocity);
        self.step_cat(dt, input.cursor);
        self.step_bird(dt, input.cursor);
        self.step_flurry(dt);
        self.crunch(dt, input.cursor, cursor_velocity);
        self.step_frost(dt, input.cursor, input.magic);
        self.last_cursor = input.cursor;
    }

    fn blizzard(&mut self, dt: f32, cursor: Option<V2>, velocity: V2) {
        let Some(cursor) = cursor else { return };
        if !self.settings.blizzard || self.settings.weather != Weather::Snow {
            return;
        }
        let speed = velocity.length();
        if speed < 900.0 || self.particles.len() > 1500 {
            return;
        }
        let count = (speed * dt / 10.0).min(18.0) as usize;
        let along = velocity * (1.0 / speed);
        let across = V2::new(-along.y, along.x);
        for _ in 0..count {
            let swirl = self.range(-1.0, 1.0);
            let position = cursor - along * self.range(0.0, speed * dt) + across * swirl * 18.0;
            let velocity = velocity * self.range(0.15, 0.45) + across * swirl * self.range(80.0, 260.0);
            let size = self.range(1.4, 3.2);
            let life = self.range(1.0, 2.2);
            self.particles.push(Particle {
                position,
                velocity,
                size,
                alpha: 0.9,
                age: 0.0,
                life,
                color: [1.0, 1.0, 1.0],
                gravity: 40.0,
                drag: 1.6,
                glow: false,
            trail: false,
            glitter: false,
            crackle: false,
        });
        }
    }

    fn step_particles(&mut self, dt: f32) {
        let mut born: Vec<Particle> = Vec::new();
        let clock = self.clock;
        let room = self.particles.len() < 5000;
        self.particles.retain_mut(|p| {
            p.age += dt;
            p.velocity.y -= p.gravity * dt;
            p.velocity = p.velocity * (1.0 - (p.drag * dt).min(0.9));
            p.position += p.velocity * dt;
            // A tail: a dimmer spark left behind every frame, which drifts down and dies quickly.
            if p.trail && room && p.age < p.life * 0.85 {
                let fade = 1.0 - p.age / p.life;
                born.push(Particle {
                    position: p.position,
                    velocity: p.velocity * 0.08 + V2::new(0.0, -12.0),
                    size: p.size * 0.6,
                    alpha: 0.55 * fade,
                    age: 0.0,
                    life: 0.45 + 0.35 * hash(p.position.x, clock),
                    color: [p.color[0] * 0.9 + 0.1, p.color[1] * 0.75 + 0.15, p.color[2] * 0.5],
                    gravity: 40.0,
                    drag: 2.5,
                    glow: true,
                    trail: false,
                    glitter: true,
                    crackle: false,
                });
            }
            // Crackling stars burst into a few white sparks as they go.
            if p.crackle && p.age >= p.life * 0.8 && room {
                p.crackle = false;
                for k in 0..5 {
                    let angle = k as f32 * 1.256 + hash(p.position.y, clock) * 6.0;
                    born.push(Particle {
                        position: p.position,
                        velocity: V2::new(angle.cos(), angle.sin()) * 70.0,
                        size: 1.6,
                        alpha: 1.0,
                        age: 0.0,
                        life: 0.25,
                        color: [1.0, 0.97, 0.9],
                        gravity: 40.0,
                        drag: 3.0,
                        glow: true,
                        trail: false,
                        glitter: false,
                        crackle: false,
                    });
                }
            }
            p.age < p.life && p.position.y > -20.0
        });
        self.particles.append(&mut born);
    }

    fn step_hail(&mut self, dt: f32) {
        if self.settings.weather == Weather::Hail && self.settings.intensity > 0.0 {
            self.hail_owed += self.width / 1000.0 * 70.0 * self.settings.intensity * dt;
            while self.hail_owed >= 1.0 {
                self.hail_owed -= 1.0;
                let position = V2::new(self.range(-30.0, self.width + 30.0), self.height + self.range(5.0, 120.0));
                let velocity = V2::new(self.range(-60.0, 60.0), -self.range(650.0, 950.0));
                let size = self.range(2.0, 4.2);
                self.hail.push(Hailstone { position, velocity, size, bounces: 0, resting: 0.0 });
            }
        }
        let mut ticks = 0u32;
        let mut hail = std::mem::take(&mut self.hail);
        let windows = &self.windows;
        hail.retain_mut(|stone| {
            if stone.resting > 0.0 {
                stone.resting += dt;
                return stone.resting < 1.6;
            }
            let from = stone.position;
            stone.velocity.y -= 1500.0 * dt;
            stone.position += stone.velocity * dt;
            let to = stone.position;
            let mut surface = None;
            for window in windows {
                let top = window.frame.max_y();
                if from.y >= top && to.y < top && to.x >= window.frame.x && to.x <= window.frame.max_x()
                    && !window.fronts.iter().any(|f| to.x >= f.x && to.x <= f.max_x() && top >= f.y && top <= f.max_y())
                {
                    surface = Some(surface.map_or(top, |s: f32| s.max(top)));
                }
            }
            if surface.is_none() {
                let floor = ground_at(&self.ground, to.x).max(0.0);
                if to.y <= floor {
                    surface = Some(floor);
                }
            }
            if let Some(top) = surface {
                stone.position.y = top + stone.size * 0.5;
                if stone.bounces >= 2 || stone.velocity.y.abs() < 120.0 {
                    stone.resting = 0.001;
                    stone.velocity = V2::ZERO;
                } else {
                    stone.bounces += 1;
                    stone.velocity.y = -stone.velocity.y * 0.32;
                    stone.velocity.x += (from.x * 7.31 + self.clock * 13.7).sin() * 140.0;
                    ticks += 1;
                }
            }
            stone.position.y > -30.0
        });
        self.hail = hail;
        // The sound of hail follows how hard it falls; no cue a stone.
        let _ = ticks;
    }

    fn step_fog(&mut self, dt: f32, cursor: Option<V2>, velocity: V2) {
        if !self.settings.fog {
            for puff in &mut self.puffs {
                puff.alpha -= dt * 0.03;
            }
            self.puffs.retain(|puff| puff.alpha > 0.0);
            return;
        }
        let wanted = (self.width / 150.0) as usize + 4;
        while self.puffs.len() < wanted {
            let position = V2::new(self.range(-200.0, self.width + 200.0), self.range(-30.0, 150.0));
            let drift = self.range(6.0, 18.0) * if self.next() < 0.5 { -1.0 } else { 1.0 };
            let size = self.range(170.0, 250.0);
            let seed = self.next();
            self.puffs.push(Puff { position, drift, size, alpha: 0.0, seed, thinned: 0.0 });
        }
        let width = self.width;
        let clock = self.clock;
        for puff in &mut self.puffs {
            puff.position.x += puff.drift * dt;
            if puff.position.x < -260.0 {
                puff.position.x = width + 250.0;
            } else if puff.position.x > width + 260.0 {
                puff.position.x = -250.0;
            }
            let goal = 0.2 + 0.06 * (clock * 0.21 + puff.seed * 9.0).sin();
            puff.alpha += (goal - puff.alpha) * (dt * 0.25).min(1.0);
            // The cursor sweeps the fog aside: puffs it passes through thin out and drift off.
            if let Some(cursor) = cursor {
                let reach = puff.size * 0.45;
                let away = puff.position - cursor;
                let distance = away.length();
                if distance < reach && velocity.length() > 80.0 {
                    puff.thinned = (puff.thinned + dt * 2.5).min(0.85);
                    puff.position.x += velocity.x.signum() * 30.0 * dt;
                }
            }
            puff.thinned = (puff.thinned - dt * 0.08).max(0.0);
        }
    }

    fn step_sky(&mut self, dt: f32) {
        if !self.settings.stars || self.daylight >= 0.35 {
            self.meteor = None;
            return;
        }
        self.next_meteor -= dt;
        if self.next_meteor <= 0.0 && self.meteor.is_none() {
            self.next_meteor = self.range(45.0, 140.0);
            let position = V2::new(self.range(self.width * 0.1, self.width * 0.9), self.range(self.height * 0.7, self.height * 0.95));
            let direction = if self.next() < 0.5 { -1.0 } else { 1.0 };
            let velocity = V2::new(direction * self.range(500.0, 800.0), -self.range(200.0, 330.0));
            self.meteor = Some(Meteor { position, velocity, age: 0.0 });
        }
        if let Some(meteor) = &mut self.meteor {
            meteor.age += dt;
            meteor.position += meteor.velocity * dt;
            if meteor.age > 0.9 {
                self.meteor = None;
            }
        }
    }

    fn step_fireworks(&mut self, dt: f32) {
        if self.fireworks_left > 0.0 {
            self.fireworks_left -= dt;
            self.next_rocket -= dt;
            // The last quarter of a minute is the finale: shell after shell.
            let finale = self.fireworks_left < 15.0;
            if self.next_rocket <= 0.0 {
                self.next_rocket = if finale { self.range(0.07, 0.22) } else { self.range(0.45, 1.3) };
                self.launch();
                if !finale && self.next() < 0.25 {
                    self.launch();
                }
            }
        }
        let mut bursts = Vec::new();
        let mut sparks = Vec::new();
        self.rockets.retain_mut(|rocket| {
            rocket.velocity.y -= 600.0 * dt;
            rocket.position += rocket.velocity * dt;
            sparks.push(rocket.position);
            if rocket.position.y >= rocket.burst_at || rocket.velocity.y <= 40.0 {
                bursts.push(*rocket);
                false
            } else {
                true
            }
        });
        // A rising shell leaves a fizzing gold tail.
        for at in sparks {
            for _ in 0..2 {
                let velocity = V2::new(self.range(-25.0, 25.0), self.range(-70.0, -10.0));
                let life = self.range(0.3, 0.6);
                self.particles.push(Particle {
                    position: at,
                    velocity,
                    size: 1.7,
                    alpha: 0.8,
                    age: 0.0,
                    life,
                    color: [1.0, 0.78, 0.42],
                    gravity: 80.0,
                    drag: 2.0,
                    glow: true,
                    trail: false,
                    glitter: true,
                    crackle: false,
                });
            }
        }
        for rocket in bursts {
            self.explode(rocket);
        }
    }

    fn launch(&mut self) {
        let palette = [
            [1.0, 0.32, 0.3],
            [1.0, 0.75, 0.3],
            [0.4, 0.75, 1.0],
            [0.55, 1.0, 0.55],
            [1.0, 0.5, 0.85],
            [0.8, 0.55, 1.0],
            [1.0, 0.95, 0.85],
        ];
        let pick = |v: f32| palette[(v * palette.len() as f32) as usize % palette.len()];
        let color = pick(self.next());
        let second = pick(self.next());
        let kinds = [Burst::Peony, Burst::Chrysanthemum, Burst::Willow, Burst::Ring, Burst::TwoTone, Burst::Crackle];
        let kind = kinds[(self.next() * kinds.len() as f32) as usize % kinds.len()];
        let position = V2::new(self.range(self.width * 0.12, self.width * 0.88), -10.0);
        let peak = self.range(self.height * 0.5, self.height * 0.85);
        let speed = (2.0 * 600.0 * peak).sqrt();
        let velocity = V2::new(self.range(-50.0, 50.0), speed);
        self.rockets.push(Rocket { position, velocity, burst_at: peak, color, second, kind });
    }

    fn explode(&mut self, rocket: Rocket) {
        let at = rocket.position;
        let far = 1.0 - (at.y / self.height.max(1.0)).clamp(0.0, 1.0);
        self.cues.push(Cue::Boom(far));
        // The flash of the burst.
        self.particles.push(Particle {
            position: at,
            velocity: V2::ZERO,
            size: 26.0,
            alpha: 0.9,
            age: 0.0,
            life: 0.22,
            color: [1.0, 0.95, 0.85],
            gravity: 0.0,
            drag: 0.0,
            glow: true,
            trail: false,
            glitter: false,
            crackle: false,
        });
        let scale = (self.height / 900.0).clamp(0.7, 1.4);
        let (count, speed, life, gravity, drag) = match rocket.kind {
            Burst::Willow => (70, 150.0, 3.6, 70.0, 1.6),
            Burst::Ring => (64, 230.0, 1.9, 90.0, 1.2),
            Burst::Chrysanthemum => (80, 240.0, 2.0, 100.0, 1.3),
            _ => (110, 250.0, 2.1, 100.0, 1.25),
        };
        let tilt = self.range(-0.6, 0.6);
        let squash = self.range(0.35, 0.8);
        for k in 0..count {
            let angle = k as f32 / count as f32 * TAU + self.range(-0.04, 0.04);
            let direction = V2::new(angle.cos(), angle.sin());
            let velocity = match rocket.kind {
                // A ring: every star at the same speed, the circle tilted into an ellipse.
                Burst::Ring => {
                    let flat = V2::new(direction.x, direction.y * squash);
                    V2::new(flat.x * tilt.cos() - flat.y * tilt.sin(), flat.x * tilt.sin() + flat.y * tilt.cos()) * speed * scale
                }
                // A ball: stars at every depth, seen from the side, so they fill the circle.
                _ => direction * speed * scale * self.next().sqrt().max(0.25),
            };
            let inner = rocket.kind == Burst::TwoTone && k % 2 == 0;
            let (velocity, color) = if inner { (velocity * 0.55, rocket.second) } else { (velocity, rocket.color) };
            let color = if rocket.kind == Burst::Willow { [1.0, 0.72, 0.32] } else { color };
            let life = life * self.range(0.8, 1.15);
            let size = self.range(4.0, 5.6);
            self.particles.push(Particle {
                position: at,
                velocity,
                size,
                alpha: 1.0,
                age: 0.0,
                life,
                color,
                gravity,
                drag,
                glow: true,
                trail: matches!(rocket.kind, Burst::Chrysanthemum | Burst::Willow),
                glitter: matches!(rocket.kind, Burst::Peony | Burst::TwoTone | Burst::Willow),
                crackle: rocket.kind == Burst::Crackle,
            });
        }
    }

    fn throw(&mut self, target: V2) {
        if self.snowballs.len() >= 4 {
            return;
        }
        let from = if target.x < self.width * 0.5 { V2::new(self.width + 40.0, 40.0) } else { V2::new(-40.0, 40.0) };
        let flight = 0.45 + (target - from).length() / 4000.0;
        self.snowballs.push(Snowball { from, to: target, age: 0.0, flight });
    }

    fn step_snowballs(&mut self, dt: f32) {
        let mut landed = Vec::new();
        self.snowballs.retain_mut(|ball| {
            ball.age += dt;
            if ball.age >= ball.flight {
                landed.push(ball.to);
                false
            } else {
                true
            }
        });
        for at in landed {
            self.cues.push(Cue::Splat);
            for _ in 0..26 {
                let angle = self.range(0.0, TAU);
                let velocity = V2::new(angle.cos(), angle.sin()) * self.range(60.0, 260.0) + V2::new(0.0, 60.0);
                let size = self.range(1.5, 3.5);
                let life = self.range(0.6, 1.4);
                self.particles.push(Particle { position: at, velocity, size, alpha: 1.0, age: 0.0, life, color: [1.0, 1.0, 1.0], gravity: 700.0, drag: 0.8, glow: false, trail: false, glitter: false, crackle: false });
            }
            let seed = self.next();
            self.splats.push(Splat { position: at, age: 0.0, seed });
            // A hit scares the bird off and sends the cat down.
            if !matches!(self.bird.state, BirdState::Waiting(_) | BirdState::Leaving) && (self.bird.position - at).length() < 160.0 {
                self.bird_leave();
            }
            if matches!(self.cat.state, CatState::Rising | CatState::Looking(_)) && (V2::new(self.cat.x, self.ground_at(self.cat.x)) - at).length() < 160.0 {
                self.cat.state = CatState::Sinking;
            }
        }
        for splat in &mut self.splats {
            splat.age += dt;
            // It sags and slides down a little before it falls off.
            splat.position.y -= dt * (4.0 + splat.age * 3.0);
        }
        let mut fallen = Vec::new();
        self.splats.retain(|splat| {
            if splat.age > 4.5 {
                fallen.push(splat.position);
                false
            } else {
                true
            }
        });
        for at in fallen {
            for _ in 0..8 {
                let velocity = V2::new(self.range(-30.0, 30.0), self.range(-20.0, 20.0));
                let size = self.range(1.5, 3.0);
                self.particles.push(Particle { position: at, velocity, size, alpha: 0.9, age: 0.0, life: 2.0, color: [1.0, 1.0, 1.0], gravity: 500.0, drag: 0.5, glow: false, trail: false, glitter: false, crackle: false });
            }
        }
    }

    /// Builds a snowman at once where the drift is at `x`, as the hotkey does. A crowded spot moves it aside; with four
    /// standing, the oldest melts to make room.
    pub fn build_snowman(&mut self, x: f32) {
        if self.settings.weather != Weather::Snow {
            return;
        }
        let x = x.clamp(30.0, (self.width - 30.0).max(31.0));
        let x = match self.snowmen.iter().find(|s| !s.melting && (s.x - x).abs() < 70.0) {
            Some(near) => {
                let step = if near.x < self.width * 0.5 { 75.0 } else { -75.0 };
                (near.x + step).clamp(30.0, (self.width - 30.0).max(31.0))
            }
            None => x,
        };
        if self.snowmen.iter().filter(|s| !s.melting).count() >= 4
            && let Some(oldest) = self.snowmen.iter_mut().find(|s| !s.melting)
        {
            oldest.melting = true;
        }
        let seed = self.next();
        self.snowmen.push(Snowman { x, built: 0.0, seed, melting: false, look: 0.0 });
        self.cues.push(Cue::Crunch(1.0));
    }

    /// Throws a snowball at a point, as the hotkey does.
    pub fn throw_at(&mut self, target: V2) {
        self.throw(target);
    }

    fn step_snowmen(&mut self, dt: f32, cursor: Option<V2>, building: bool, velocity: V2) {
        // Holding the modifier with the cursor still near the bottom of the screen, where the drift is, packs a
        // snowman there in a second. Snow is brought along when the drift is thin.
        let allowed = self.settings.weather == Weather::Snow;
        match cursor {
            Some(cursor) if allowed && building && velocity.length() < 160.0 => {
                let depth = self.ground_at(cursor.x).max(0.0);
                let low = cursor.y <= depth + 70.0 && cursor.y >= -5.0;
                if low {
                    let progress = match self.building {
                        Some((x, progress)) if (x - cursor.x).abs() < 40.0 => progress + dt,
                        _ => 0.0,
                    };
                    if progress >= 1.0 {
                        self.build_snowman(cursor.x);
                        self.building = None;
                    } else {
                        self.building = Some((cursor.x, progress));
                    }
                } else {
                    self.building = None;
                }
            }
            _ => self.building = None,
        }
        // Snowmen stand until the snow is cleared or something else than snow falls.
        let melting = !allowed;
        for snowman in &mut self.snowmen {
            if melting {
                snowman.melting = true;
            }
            if snowman.melting {
                snowman.built -= dt * 0.5;
            } else {
                snowman.built = (snowman.built + dt * 1.2).min(1.0);
            }
            let goal = cursor.map_or(0.0, |c| ((c.x - snowman.x) / 300.0).clamp(-1.0, 1.0));
            snowman.look += (goal - snowman.look) * (dt * 4.0).min(1.0);
        }
        self.snowmen.retain(|s| !(s.melting && s.built <= 0.0));
    }

    fn step_cat(&mut self, dt: f32, cursor: Option<V2>) {
        let allowed = self.settings.creatures && self.settings.weather == Weather::Snow;
        let ground_at_cat = self.ground_at(self.cat.x);
        let near = cursor.is_some_and(|c| (c - V2::new(self.cat.x, ground_at_cat)).length() < 150.0);
        self.cat.blink += dt;
        match self.cat.state {
            CatState::Waiting(left) => {
                let left = left - dt;
                if left > 0.0 || !allowed {
                    self.cat.state = CatState::Waiting(left.max(if allowed { 0.0 } else { 30.0 }));
                    return;
                }
                // A spot with a deep drift, out from under windows and away from the cursor.
                for _ in 0..24 {
                    let x = self.range(80.0, (self.width - 80.0).max(81.0));
                    let depth = self.ground_at(x);
                    let away = cursor.is_none_or(|c| (c.x - x).abs() > 260.0);
                    if depth >= 26.0 && away && !self.covered(V2::new(x, depth + 10.0)) {
                        self.cat = Cat { x, rise: 0.0, seed: self.next(), look: 0.0, blink: 0.0, state: CatState::Rising };
                        return;
                    }
                }
                self.cat.state = CatState::Waiting(20.0);
            }
            CatState::Rising => {
                self.cat.rise += dt / 0.9;
                if near || !allowed {
                    self.cat.state = CatState::Sinking;
                } else if self.cat.rise >= 1.0 {
                    self.cat.rise = 1.0;
                    self.cat.state = CatState::Looking(self.range(6.0, 11.0));
                }
            }
            CatState::Looking(left) => {
                let goal = ((self.clock * 0.45 + self.cat.seed * 7.0).sin() * 1.4).clamp(-1.0, 1.0);
                self.cat.look += (goal - self.cat.look) * (dt * 2.0).min(1.0);
                let left = left - dt;
                self.cat.state = if near || left <= 0.0 || ground_at_cat < 18.0 || !allowed { CatState::Sinking } else { CatState::Looking(left) };
            }
            CatState::Sinking => {
                self.cat.rise -= dt / if near { 0.25 } else { 0.8 };
                if self.cat.rise <= 0.0 {
                    self.cat.rise = 0.0;
                    self.cat.state = CatState::Waiting(self.range(240.0, 720.0));
                }
            }
        }
    }

    fn bird_leave(&mut self) {
        let bird = &mut self.bird;
        bird.state = BirdState::Leaving;
        bird.from = bird.position;
        let side = if bird.facing > 0.0 { 1.0 } else { -1.0 };
        bird.to = V2::new(if side > 0.0 { self.width + 80.0 } else { -80.0 }, self.height + 60.0);
        bird.flight = 0.0;
    }

    fn step_bird(&mut self, dt: f32, cursor: Option<V2>) {
        let allowed = self.settings.creatures && self.settings.weather == Weather::Snow;
        self.bird.age += dt;
        self.bird.wing += dt * 14.0;
        let window = self.windows.iter().find(|w| w.id == self.bird.window).cloned();
        match self.bird.state {
            BirdState::Waiting(left) => {
                let left = left - dt;
                if left > 0.0 || !allowed {
                    self.bird.state = BirdState::Waiting(left.max(if allowed { 0.0 } else { 30.0 }));
                    return;
                }
                let candidates: Vec<RainWindow> = self
                    .windows
                    .iter()
                    .filter(|w| w.frame.width > 220.0 && w.frame.max_y() < self.height - 40.0)
                    .cloned()
                    .collect();
                if candidates.is_empty() {
                    self.bird.state = BirdState::Waiting(30.0);
                    return;
                }
                let pick = candidates[(self.next() * candidates.len() as f32) as usize % candidates.len()].clone();
                let x = self.range(40.0, pick.frame.width - 40.0);
                let landing = V2::new(pick.frame.x + x, pick.frame.max_y());
                if pick.fronts.iter().any(|f| landing.x >= f.x && landing.x <= f.max_x() && landing.y >= f.y && landing.y <= f.max_y()) {
                    self.bird.state = BirdState::Waiting(20.0);
                    return;
                }
                let from_left = self.next() < 0.5;
                let from = V2::new(if from_left { -60.0 } else { self.width + 60.0 }, (landing.y + self.range(120.0, 300.0)).min(self.height + 40.0));
                self.bird = Bird {
                    state: BirdState::Arriving,
                    window: pick.id,
                    x,
                    position: from,
                    from,
                    to: landing,
                    flight: 0.0,
                    age: 0.0,
                    facing: if from_left { 1.0 } else { -1.0 },
                    wing: 0.0,
                    peck: 0.0,
                    hop: 0.0,
                };
            }
            BirdState::Arriving => {
                let Some(window) = window else {
                    self.bird_leave();
                    return;
                };
                self.bird.to = V2::new(window.frame.x + self.bird.x, window.frame.max_y());
                self.bird.flight += dt / 2.2;
                let t = self.bird.flight.min(1.0);
                let ease = 1.0 - (1.0 - t) * (1.0 - t);
                let arc = (t * PI).sin() * 40.0;
                self.bird.position = self.bird.from + (self.bird.to - self.bird.from) * ease + V2::new(0.0, arc);
                if t >= 1.0 {
                    self.bird.state = BirdState::Perched(self.range(15.0, 35.0));
                }
            }
            BirdState::Perched(left) => {
                let Some(window) = window else {
                    self.bird_leave();
                    return;
                };
                let left = left - dt;
                // Hops along the edge now and then, and pecks at the snow.
                self.bird.peck = (self.bird.peck - dt * 3.0).max(0.0);
                self.bird.hop = (self.bird.hop - dt * 4.0).max(0.0);
                if self.next() < dt * 0.6 {
                    self.bird.peck = 1.0;
                }
                if self.next() < dt * 0.25 {
                    let step = self.range(-26.0, 26.0);
                    self.bird.x = (self.bird.x + step).clamp(20.0, window.frame.width - 20.0);
                    self.bird.facing = if step >= 0.0 { 1.0 } else { -1.0 };
                    self.bird.hop = 1.0;
                }
                self.bird.position = V2::new(window.frame.x + self.bird.x, window.frame.max_y());
                let scared = cursor.is_some_and(|c| (c - self.bird.position).length() < 120.0);
                if scared || left <= 0.0 || !allowed {
                    self.bird_leave();
                } else {
                    self.bird.state = BirdState::Perched(left);
                }
            }
            BirdState::Leaving => {
                self.bird.flight += dt / 1.6;
                let t = self.bird.flight.min(1.0);
                self.bird.position = self.bird.from + (self.bird.to - self.bird.from) * (t * t) + V2::new(0.0, (t * PI).sin() * 30.0);
                if t >= 1.0 {
                    self.bird.state = BirdState::Waiting(self.range(180.0, 540.0));
                }
            }
        }
    }

    fn step_flurry(&mut self, dt: f32) {
        if self.flurry_left <= 0.0 {
            return;
        }
        self.flurry_left -= dt;
        self.flurry_owed += self.width / 1000.0 * 120.0 * dt;
        while self.flurry_owed >= 1.0 {
            self.flurry_owed -= 1.0;
            let position = V2::new(self.range(0.0, self.width), self.height + self.range(5.0, 60.0));
            let velocity = V2::new(self.range(-30.0, 30.0), -self.range(60.0, 120.0));
            let size = self.range(4.0, 7.5);
            let life = self.height / 70.0 + 4.0;
            self.particles.push(Particle { position, velocity, size, alpha: 0.95, age: 0.0, life, color: [1.0, 1.0, 1.0], gravity: 0.0, drag: 0.0, glow: false, trail: false, glitter: false, crackle: false });
        }
    }

    fn crunch(&mut self, dt: f32, cursor: Option<V2>, velocity: V2) {
        self.crunch_cooldown -= dt;
        let Some(cursor) = cursor else { return };
        if self.settings.weather != Weather::Snow || self.crunch_cooldown > 0.0 {
            return;
        }
        let depth = self.ground_at(cursor.x);
        let speed = velocity.length();
        if depth > 8.0 && cursor.y < depth && cursor.y > -2.0 && speed > 150.0 {
            self.crunch_cooldown = 0.18;
            self.cues.push(Cue::Crunch((speed / 1500.0).clamp(0.3, 1.0)));
        }
    }

    /// Frost by snow, mist by rain, creeping in from the screen's edges; holding the modifier, the cursor draws in it.
    /// The frost itself moves slowly, so it is worked out a few times a second; drawing in it, every frame.
    fn step_frost(&mut self, dt: f32, cursor: Option<V2>, magic: bool) {
        let wanted = self.settings.frost && matches!(self.settings.weather, Weather::Snow | Weather::Rain | Weather::Hail);
        let columns = self.frost_columns;
        let rows = self.frost_rows;
        let reach: f32 = if self.settings.weather == Weather::Rain { 120.0 } else { 95.0 };
        let key = (wanted, reach.to_bits());
        if self.frost_target_for != Some(key) {
            self.frost_target_for = Some(key);
            let (width, height) = (self.width, self.height);
            self.frost_target = (0..rows * columns)
                .map(|i| {
                    if !wanted {
                        return 0.0;
                    }
                    let (x, y) = ((i % columns) as f32 * FROST_CELL, (i / columns) as f32 * FROST_CELL);
                    let edge = x.min(width - x).min(y).min(height - y).max(0.0);
                    // Deeper in the corners, ragged along the edges.
                    let corner = (x.min(width - x).min(150.0) + y.min(height - y).min(150.0)) / 300.0;
                    let ragged = 0.75 + 0.5 * value_noise(x * 0.013, y * 0.013);
                    let span = reach * ragged * (1.5 - corner);
                    if edge >= span { 0.0 } else { (1.0 - edge / span).powf(1.3) }
                })
                .collect();
        }
        let mut changed = false;
        self.frost_tick += dt;
        if self.frost_tick >= 0.25 && (wanted || self.frost_any) {
            let tick = std::mem::take(&mut self.frost_tick);
            let mut any = false;
            for i in 0..self.frost.len() {
                if self.frost_rest[i] > 0.0 {
                    self.frost_rest[i] -= tick;
                    any |= self.frost[i] > 0.0;
                    continue;
                }
                let (value, target) = (self.frost[i], self.frost_target[i]);
                if value == target {
                    any |= value > 0.0;
                    continue;
                }
                // Slow to creep in, quicker to go.
                let next = if target > value { value + (target - value).min(tick / 80.0) } else { value - (value - target).min(tick / 8.0) };
                self.frost[i] = next;
                any |= next > 0.0;
                changed = true;
            }
            self.frost_any = any;
        }
        if let (Some(cursor), Some(last)) = (cursor, self.last_cursor)
            && magic
            && wanted
            && self.frost_any
        {
            let steps = ((cursor - last).length() / 4.0).ceil().clamp(1.0, 60.0) as usize;
            for k in 0..=steps {
                let at = last + (cursor - last) * (k as f32 / steps as f32);
                let (cx, cy) = ((at.x / FROST_CELL).round() as isize, (at.y / FROST_CELL).round() as isize);
                for dy in -2..=2isize {
                    for dx in -2..=2isize {
                        let (column, row) = (cx + dx, cy + dy);
                        if column < 0 || row < 0 || column >= columns as isize || row >= rows as isize {
                            continue;
                        }
                        let d = ((dx * dx + dy * dy) as f32).sqrt() * FROST_CELL;
                        if d <= 14.0 {
                            let i = row as usize * columns + column as usize;
                            if self.frost[i] > 0.0 {
                                self.frost[i] *= (d / 14.0).powi(2);
                                changed = true;
                            }
                            // A line drawn stays clear a while before the frost creeps back.
                            self.frost_rest[i] = 25.0;
                        }
                    }
                }
            }
        }
        self.frost_changed |= changed;
    }

    /// The frost grid: its values, columns, rows and the size of a cell in points; whether it changed since asked.
    pub fn frost(&mut self) -> (&[f32], usize, usize, f32, bool) {
        let changed = std::mem::take(&mut self.frost_changed);
        (&self.frost, self.frost_columns, self.frost_rows, FROST_CELL, changed)
    }

    /// The frost grid to draw: its values, columns, rows and the size of a cell in points.
    pub fn frost_grid(&self) -> (&[f32], usize, usize, f32) {
        (&self.frost, self.frost_columns, self.frost_rows, FROST_CELL)
    }

    /// Whether the frost changed since last asked.
    pub fn take_frost_changed(&mut self) -> bool {
        std::mem::take(&mut self.frost_changed)
    }

    /// How deep the frost reaches in from the edges at most, for the bands drawn.
    pub fn frost_reach(&self) -> f32 {
        if self.frost_any { 190.0 } else { 0.0 }
    }

    /// Mist rather than frost.
    pub fn frost_is_mist(&self) -> bool {
        self.settings.weather == Weather::Rain
    }

    pub fn sprite_count(&self) -> usize {
        self.particles.len()
            + self.hail.len()
            + self.puffs.len()
            + self.stars.len()
            + 2
            + self.snowballs.len()
            + self.splats.len()
            + self.snowmen.len()
            + 1
            + 2
            + if self.settings.garland {
                self.garland_windows().iter().map(|w| (w.frame.width / 9.0) as usize + (w.frame.width / 30.0) as usize + 4).sum::<usize>()
            } else {
                0
            }
    }

    pub fn write(&self, out: &mut [Sprite]) -> usize {
        let mut n = 0;
        let mut put = |sprite: Sprite| {
            if n < out.len() {
                out[n] = sprite;
                n += 1;
            }
        };
        let night = ((0.35 - self.daylight) / 0.35).clamp(0.0, 1.0);
        if self.settings.stars && night > 0.0 {
            for star in &self.stars {
                if self.covered(star.position) {
                    continue;
                }
                let twinkle = 0.55 + 0.45 * (self.clock * (0.8 + star.seed * 2.2) + star.seed * 40.0).sin();
                put(glow(star.position, V2::ZERO, star.size, 0.95 * twinkle * night, [0.95, 0.97, 1.0]));
            }
            if let Some(meteor) = self.meteor {
                let fade = (meteor.age / 0.15).min(1.0) * (1.0 - (meteor.age / 0.9).powi(2));
                put(glow(meteor.position, meteor.velocity, 2.4, fade * night, [1.0, 0.97, 0.9]));
            }
        }
        for puff in &self.puffs {
            put(Sprite { position: puff.position, size: puff.size, alpha: puff.alpha * (1.0 - puff.thinned), leaf: [FOG, puff.seed, 0.0], ..Default::default() });
        }
        if self.settings.garland {
            self.write_garland(&mut put);
        }
        for p in &self.particles {
            let mut fade = 1.0 - (p.age / p.life).powi(2);
            // Glittering stars twinkle as they die.
            if p.glitter && p.age > p.life * 0.5 && hash(p.position.x * 0.37, (self.clock * 24.0).floor()) < 0.45 {
                fade *= 0.25;
            }
            if p.glow {
                // A short smear of its motion, so a spark reads as a bright streak rather than a dotted line.
                put(glow(p.position, p.velocity * 0.25, p.size, p.alpha * fade, p.color));
            } else {
                put(Sprite { position: p.position, velocity: p.velocity, size: p.size, alpha: p.alpha * fade, soft: 0.4, ..Default::default() });
            }
        }
        for stone in &self.hail {
            let fade = if stone.resting > 0.0 { 1.0 - stone.resting / 1.6 } else { 1.0 };
            put(Sprite { position: stone.position, velocity: stone.velocity, size: stone.size, alpha: 0.95 * fade, leaf: [HAIL, 0.0, 0.0], ..Default::default() });
        }
        for snowman in &self.snowmen {
            let ground = self.ground_at(snowman.x).max(0.0);
            let height = 78.0;
            let center = V2::new(snowman.x, ground - 4.0 + height * 0.5);
            put(Sprite {
                position: center,
                size: height,
                alpha: 1.0,
                leaf: [SNOWMAN, snowman.built.clamp(0.0, 1.0), snowman.seed],
                spin: [snowman.look, self.clock],
                ..Default::default()
            });
        }
        if let Some((x, progress)) = self.building {
            let ground = self.ground_at(x).max(0.0);
            let height = 78.0;
            put(Sprite {
                position: V2::new(x, ground - 4.0 + height * 0.5),
                size: height,
                alpha: 0.6,
                leaf: [SNOWMAN, progress * 0.35, 0.5],
                spin: [0.0, self.clock],
                ..Default::default()
            });
        }
        if self.cat.rise > 0.0 {
            let ground = self.ground_at(self.cat.x);
            let size = 44.0;
            put(Sprite {
                position: V2::new(self.cat.x, ground + size * 0.5 - 6.0),
                size,
                alpha: 1.0,
                leaf: [CAT, self.cat.rise, self.cat.seed],
                spin: [self.cat.look, self.cat.blink],
                ..Default::default()
            });
        }
        if !matches!(self.bird.state, BirdState::Waiting(_)) {
            let flying = match self.bird.state {
                BirdState::Perched(_) => self.bird.hop * 0.5,
                _ => 1.0,
            };
            let size = 30.0;
            let window_hidden = matches!(self.bird.state, BirdState::Perched(_))
                && self.windows.iter().find(|w| w.id == self.bird.window).is_some_and(|w| {
                    w.fronts.iter().any(|f| self.bird.position.x >= f.x && self.bird.position.x <= f.max_x() && self.bird.position.y >= f.y && self.bird.position.y <= f.max_y())
                });
            if !window_hidden {
                put(Sprite {
                    position: self.bird.position + V2::new(0.0, size * 0.5 - 2.0 + self.bird.hop * 5.0),
                    size,
                    alpha: 1.0,
                    leaf: [BIRD, flying, self.bird.facing],
                    spin: [self.bird.wing, self.bird.peck],
                    ..Default::default()
                });
            }
        }
        for ball in &self.snowballs {
            let t = (ball.age / ball.flight).min(1.0);
            let arc = (t * PI).sin() * 120.0;
            let at = ball.from + (ball.to - ball.from) * t + V2::new(0.0, arc);
            let size = 22.0 - 8.0 * t;
            put(Sprite { position: at, size, alpha: 1.0, leaf: [SNOWBALL, 0.0, 0.3], spin: [self.clock * 9.0, 0.0], ..Default::default() });
        }
        for splat in &self.splats {
            let fade = 1.0 - ((splat.age - 3.5) / 1.0).clamp(0.0, 1.0);
            put(Sprite { position: splat.position, size: 34.0, alpha: fade, leaf: [SNOWBALL, 1.0, splat.seed], ..Default::default() });
        }
        n
    }

    /// The windows a garland hangs on: those wide enough, their tops in sight, the largest first, a few at most.
    fn garland_windows(&self) -> Vec<&RainWindow> {
        let mut windows: Vec<&RainWindow> = self
            .windows
            .iter()
            .filter(|w| w.frame.width >= 180.0 && w.frame.max_y() < self.height - self.top_inset - 6.0)
            .collect();
        windows.sort_by(|a, b| (b.frame.width * b.frame.height).total_cmp(&(a.frame.width * a.frame.height)));
        windows.truncate(6);
        windows
    }

    /// A string of fairy lights along the top of each window: a twisted cord sagging between hooks at the corners and
    /// along the edge, glass bulbs hanging off it on little sockets, glowing in turns.
    fn write_garland(&self, put: &mut impl FnMut(Sprite)) {
        // Classic warm bulbs: red, amber, green, blue and pink.
        let colors = [[1.0, 0.27, 0.2], [1.0, 0.68, 0.18], [0.3, 0.86, 0.4], [0.3, 0.55, 1.0], [1.0, 0.42, 0.75]];
        // Three patterns take turns: a chase, a twinkle and a slow breath.
        let pattern = ((self.clock / 18.0) as usize) % 3;
        let mut bulb = 0usize;
        for window in self.garland_windows() {
            let frame = window.frame;
            let hidden = |at: V2| window.fronts.iter().any(|f| at.x >= f.x && at.x <= f.max_x() && at.y >= f.y && at.y <= f.max_y());
            let top = frame.max_y() - 1.0;
            let spans = (frame.width / 150.0).round().max(1.0);
            let span = frame.width / spans;
            let sag = (span * 0.11).clamp(8.0, 20.0);
            let sway = |x: f32| (self.clock * 1.3 + x * 0.013).sin() * 0.8;
            let wire = |x: f32| -> f32 {
                let t = ((x - frame.x) / span).fract();
                top - sag * (t * PI).sin() + sway(x) * (t * PI).sin()
            };
            // The cord in short straight pieces.
            let step = 9.0;
            let mut x = frame.x;
            while x < frame.max_x() - 0.5 {
                let next = (x + step).min(frame.max_x());
                let (a, b) = (V2::new(x, wire(x)), V2::new(next, wire(next)));
                let middle = (a + b) * 0.5;
                if !hidden(middle) {
                    put(Sprite { position: middle, velocity: b - a, size: 2.2, alpha: 1.0, leaf: [WIRE, 0.0, 0.0], ..Default::default() });
                }
                x = next;
            }
            // Bulbs hanging off it, pointing down along the cord's sag.
            let count = ((frame.width - 20.0) / 30.0).floor().max(1.0) as usize;
            let gap = (frame.width - 20.0) / count as f32;
            for k in 0..=count {
                let x = frame.x + 10.0 + k as f32 * gap;
                let slope = (wire(x + 1.0) - wire(x - 1.0)) * 0.5;
                let angle = slope.atan() * 0.6 + (self.clock * 1.7 + bulb as f32 * 1.3).sin() * 0.05;
                let at = V2::new(x - angle.sin() * 7.0, wire(x) - 7.0);
                if hidden(at) {
                    bulb += 1;
                    continue;
                }
                let color = colors[bulb % colors.len()];
                let i = bulb as f32;
                let on = match pattern {
                    0 => 0.15 + 0.85 * (((self.clock * 2.6 - i * 0.45).sin()) * 0.5 + 0.5).powi(2),
                    1 => if hash(i, (self.clock * 1.6).floor()) > 0.35 { 1.0 } else { 0.18 },
                    _ => 0.35 + 0.65 * ((self.clock * 1.1 + i * 0.9).sin() * 0.5 + 0.5),
                };
                put(Sprite { position: at, size: 15.0, alpha: 1.0, tint_amount: 1.0, tint: color, leaf: [BULB, on, angle], ..Default::default() });
                bulb += 1;
            }
        }
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

fn glow(position: V2, velocity: V2, size: f32, alpha: f32, color: [f32; 3]) -> Sprite {
    Sprite { position, velocity, size, alpha, tint_amount: 1.0, tint: color, leaf: [GLOW, 0.0, 0.0], ..Default::default() }
}

fn ground_at(ground: &[f32], x: f32) -> f32 {
    if ground.is_empty() {
        return 0.0;
    }
    let f = (x / GROUND_STEP).clamp(0.0, (ground.len() - 1) as f32);
    let i = f.floor() as usize;
    let j = (i + 1).min(ground.len() - 1);
    ground[i] + (ground[j] - ground[i]) * (f - i as f32)
}

fn hash(x: f32, y: f32) -> f32 {
    let v = (x * 127.1 + y * 311.7).sin() * 43758.547;
    v - v.floor()
}

fn value_noise(x: f32, y: f32) -> f32 {
    let (ix, iy) = (x.floor(), y.floor());
    let (fx, fy) = (x - ix, y - iy);
    let (ux, uy) = (fx * fx * (3.0 - 2.0 * fx), fy * fy * (3.0 - 2.0 * fy));
    let a = hash(ix, iy);
    let b = hash(ix + 1.0, iy);
    let c = hash(ix, iy + 1.0);
    let d = hash(ix + 1.0, iy + 1.0);
    a + (b - a) * ux + (c - a) * uy + (a - b - c + d) * ux * uy
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::Rect;

    fn frame(extras: &mut Extras, input: Input, seconds: f32) {
        for _ in 0..(seconds * 60.0) as usize {
            extras.step(Input { dt: 1.0 / 60.0, ..input });
        }
    }

    #[test]
    fn a_held_modifier_builds_a_snowman_near_the_bottom() {
        let mut extras = Extras::new(1200.0, 800.0);
        extras.sample_ground(|_| 30.0);
        frame(&mut extras, Input { cursor: Some(V2::new(400.0, 20.0)), magic: true, daylight: 1.0, ..Default::default() }, 1.2);
        assert_eq!(extras.snowmen.len(), 1);
        // Without any drift, near the bottom, it still works: the snow comes along.
        let mut bare = Extras::new(1200.0, 800.0);
        frame(&mut bare, Input { cursor: Some(V2::new(600.0, 40.0)), magic: true, daylight: 1.0, ..Default::default() }, 1.2);
        assert_eq!(bare.snowmen.len(), 1);
        // Higher up the screen nothing is built.
        let mut high = Extras::new(1200.0, 800.0);
        frame(&mut high, Input { cursor: Some(V2::new(600.0, 400.0)), magic: true, daylight: 1.0, ..Default::default() }, 2.0);
        assert!(high.snowmen.is_empty());
        // Rain melts them.
        extras.settings.weather = Weather::Rain;
        frame(&mut extras, Input { daylight: 1.0, ..Default::default() }, 4.0);
        assert!(extras.snowmen.is_empty());
    }

    #[test]
    fn the_hotkey_builds_snowmen_side_by_side_and_keeps_four() {
        let mut extras = Extras::new(1200.0, 800.0);
        for _ in 0..6 {
            extras.build_snowman(600.0);
            frame(&mut extras, Input { daylight: 1.0, ..Default::default() }, 0.2);
        }
        let standing: Vec<f32> = extras.snowmen.iter().filter(|s| !s.melting).map(|s| s.x).collect();
        assert_eq!(standing.len(), 4, "{standing:?}");
        frame(&mut extras, Input { daylight: 1.0, ..Default::default() }, 3.0);
        assert_eq!(extras.snowmen.len(), 4);
    }

    #[test]
    fn a_snowball_flies_lands_and_slides_off() {
        let mut extras = Extras::new(1200.0, 800.0);
        let at = V2::new(600.0, 400.0);
        extras.step(Input { dt: 1.0 / 60.0, cursor: Some(at), ..Default::default() });
        extras.step(Input { dt: 1.0 / 60.0, cursor: Some(at), button: true, magic: true, ..Default::default() });
        assert_eq!(extras.snowballs.len(), 1);
        frame(&mut extras, Input { cursor: Some(at), button: true, magic: true, ..Default::default() }, 1.0);
        assert!(extras.snowballs.is_empty() && extras.splats.len() == 1);
        assert!(extras.take_cues().contains(&Cue::Splat));
        frame(&mut extras, Input::default(), 6.0);
        assert!(extras.splats.is_empty());
    }

    #[test]
    fn fireworks_burst_and_end() {
        let mut extras = Extras::new(1200.0, 800.0);
        extras.fireworks(5.0);
        frame(&mut extras, Input::default(), 5.0);
        assert!(extras.take_cues().iter().any(|cue| matches!(cue, Cue::Boom(_))));
        frame(&mut extras, Input::default(), 6.0);
        assert!(!extras.fireworks_running() && extras.particles.is_empty());
    }

    #[test]
    fn the_bird_lands_on_a_window_and_leaves_when_the_cursor_comes() {
        let mut extras = Extras::new(1600.0, 1000.0);
        extras.set_windows(&[RainWindow { id: 7, frame: Rect { x: 300.0, y: 200.0, width: 700.0, height: 500.0 }, fronts: vec![], ledge_only: false }]);
        extras.bird.state = BirdState::Waiting(0.0);
        frame(&mut extras, Input { daylight: 1.0, ..Default::default() }, 3.0);
        assert!(matches!(extras.bird.state, BirdState::Perched(_)));
        assert!((extras.bird.position.y - 700.0).abs() < 1.0);
        let near = extras.bird.position + V2::new(30.0, 10.0);
        frame(&mut extras, Input { cursor: Some(near), daylight: 1.0, ..Default::default() }, 0.1);
        assert!(matches!(extras.bird.state, BirdState::Leaving));
    }

    #[test]
    fn frost_creeps_in_from_the_edges_and_the_cursor_draws_in_it() {
        let mut extras = Extras::new(800.0, 600.0);
        frame(&mut extras, Input { daylight: 1.0, ..Default::default() }, 120.0);
        let (values, columns, _, cell, _) = extras.frost();
        let edge = values[columns * 2 + 1];
        let middle = values[(300.0 / cell) as usize * columns + (400.0 / cell) as usize];
        assert!(edge > 0.4, "edge {edge}");
        assert!(middle < 0.01, "middle {middle}");
        // Drawing along the bottom edge with the modifier held clears a line.
        let mut input = Input { daylight: 1.0, magic: true, cursor: Some(V2::new(100.0, 8.0)), ..Default::default() };
        for k in 0..60 {
            input.cursor = Some(V2::new(100.0 + k as f32 * 5.0, 8.0));
            extras.step(Input { dt: 1.0 / 60.0, ..input });
        }
        let (values, columns, _, cell, _) = extras.frost();
        let drawn = values[(8.0 / cell) as usize * columns + (250.0 / cell) as usize];
        assert!(drawn < 0.05, "drawn {drawn}");
    }

    #[test]
    fn writes_what_it_counts() {
        let mut extras = Extras::new(1200.0, 800.0);
        extras.settings.garland = true;
        extras.set_windows(&[RainWindow { id: 3, frame: Rect { x: 100.0, y: 100.0, width: 700.0, height: 400.0 }, fronts: vec![], ledge_only: false }]);
        extras.settings.fog = true;
        extras.settings.weather = Weather::Hail;
        extras.fireworks(3.0);
        frame(&mut extras, Input { daylight: 0.0, ..Default::default() }, 3.0);
        let mut sprites = vec![Sprite::default(); extras.sprite_count()];
        let written = extras.write(&mut sprites);
        // Room for everything: the count never falls short of what is written.
        assert!(written > 100 && written < sprites.len(), "{written} of {}", sprites.len());
    }
}

#[cfg(test)]
mod bench {
    use super::*;

    #[test]
    #[ignore]
    fn step_cost() {
        let mut extras = Extras::new(1512.0, 982.0);
        extras.sample_ground(|_| 20.0);
        let start = std::time::Instant::now();
        for _ in 0..600 {
            extras.step(Input { dt: 1.0 / 60.0, daylight: 1.0, cursor: Some(V2::new(300.0, 300.0)), ..Default::default() });
        }
        println!("per step: {:?}", start.elapsed() / 600);
    }
}
