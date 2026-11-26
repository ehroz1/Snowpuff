//! Sound without sound files: a quiet bed of winter, made on the fly, and an ear for a breath blown at the
//! microphone. Platform-free: each app feeds these from its own audio devices. The Mac app has the same in Swift.

/// The winter sound: wind that rises and falls in slow gusts, and a fire crackling in the next room.
pub struct Ambience {
    pub wind: bool,
    pub fire: bool,
    /// 0 to 1.
    pub volume: f32,
    /// How hard the snow is falling, 0 to 1: the wind follows it.
    pub windiness: f32,
    sample_rate: f32,
    seed: u32,
    brown: [f32; 2],
    hiss: [f32; 2],
    gust: f32,
    gust_target: f32,
    gust_timer: f32,
    wind_level: f32,
    roar: f32,
    roar_low: f32,
    crackles: Vec<Crackle>,
    fire_level: f32,
    burst: f32,
}

#[derive(Clone, Copy)]
struct Crackle {
    left: f32,
    right: f32,
    envelope: f32,
    decay: f32,
    tone: f32,
    last: f32,
}

impl Ambience {
    pub fn new(sample_rate: f32) -> Ambience {
        Ambience {
            wind: false,
            fire: false,
            volume: 0.5,
            windiness: 0.5,
            sample_rate: sample_rate.max(8000.0),
            seed: 0x9E37_79B9,
            brown: [0.0; 2],
            hiss: [0.0; 2],
            gust: 0.5,
            gust_target: 0.5,
            gust_timer: 0.0,
            wind_level: 0.0,
            roar: 0.0,
            roar_low: 0.0,
            crackles: Vec::with_capacity(32),
            fire_level: 0.0,
            burst: 0.0,
        }
    }

    /// Whether anything can still be heard, while a sound switched off fades out.
    pub fn audible(&self) -> bool {
        self.wind || self.fire || self.wind_level > 0.0005 || self.fire_level > 0.0005
    }

    fn noise(&mut self) -> f32 {
        self.seed ^= self.seed << 13;
        self.seed ^= self.seed >> 17;
        self.seed ^= self.seed << 5;
        self.seed as f32 / u32::MAX as f32 * 2.0 - 1.0
    }

    fn chance(&mut self) -> f32 {
        self.noise() * 0.5 + 0.5
    }

    /// Fills interleaved stereo frames.
    pub fn render(&mut self, out: &mut [f32]) {
        let dt = 1.0 / self.sample_rate;
        let master = self.volume * 0.5;
        for frame in out.chunks_exact_mut(2) {
            let (mut l, mut r) = (0.0, 0.0);
            // Levels glide, so switching a sound on or off fades rather than clicks.
            self.wind_level += ((self.wind as u8 as f32) - self.wind_level) * dt * 1.5;
            self.fire_level += ((self.fire as u8 as f32) - self.fire_level) * dt * 1.5;

            if self.wind_level > 0.0005 {
                self.gust_timer -= dt;
                if self.gust_timer <= 0.0 {
                    self.gust_timer = 1.5 + self.chance() * 4.0;
                    self.gust_target = 0.25 + self.chance() * (0.45 + 0.5 * self.windiness);
                }
                self.gust += (self.gust_target - self.gust) * dt * 0.6;
                // Brown noise for the low rush, filtered white noise for the airy hiss whose brightness follows the gust.
                for side in 0..2 {
                    let n = self.noise();
                    self.brown[side] = (self.brown[side] + 0.02 * n) / 1.02;
                    let n = self.noise();
                    self.hiss[side] += (n - self.hiss[side]) * (0.02 + 0.06 * self.gust);
                }
                let level = self.wind_level * (0.25 + self.gust);
                l += (self.brown[0] * 3.2 + self.hiss[0] * 0.5) * level;
                r += (self.brown[1] * 3.2 + self.hiss[1] * 0.5) * level;
            }

            if self.fire_level > 0.0005 {
                // A soft low roar under it all.
                let n = self.noise();
                self.roar += (n - self.roar) * 0.01;
                self.roar_low += (self.roar - self.roar_low) * 0.05;
                let body = self.roar_low * 1.4 * self.fire_level;
                l += body;
                r += body;
                // Crackles come in little bursts: now and then a run of snaps, between them only the odd one.
                self.burst = (self.burst - dt * 2.0).max(0.0);
                if self.chance() < dt * 0.35 {
                    self.burst = 1.0;
                }
                let rate = 3.0 + 40.0 * self.burst;
                if self.crackles.len() < 24 && self.chance() < rate * dt {
                    let pan = self.chance();
                    let loud = self.chance().powf(2.2) * 0.9 + 0.05;
                    let pop = self.chance() < 0.12;
                    let decay = if pop { 40.0 } else { 250.0 + self.chance() * 600.0 };
                    self.crackles.push(Crackle {
                        left: loud * (1.0 - pan * 0.7),
                        right: loud * (0.3 + pan * 0.7),
                        envelope: 1.0,
                        decay,
                        tone: if pop { 0.25 } else { 0.9 },
                        last: 0.0,
                    });
                }
                let mut k = 0;
                while k < self.crackles.len() {
                    let raw = self.noise();
                    let c = &mut self.crackles[k];
                    // High-passed for a snap, low-passed for a pop.
                    let shaped = if c.tone > 0.5 { raw - c.last } else { c.last + (raw - c.last) * c.tone };
                    c.last = if c.tone > 0.5 { raw } else { shaped };
                    let s = shaped * c.envelope * self.fire_level;
                    l += s * c.left;
                    r += s * c.right;
                    c.envelope *= (-c.decay * dt).exp();
                    if c.envelope < 0.002 {
                        self.crackles.swap_remove(k);
                    } else {
                        k += 1;
                    }
                }
            }
            frame[0] = (l * master).clamp(-1.0, 1.0);
            frame[1] = (r * master).clamp(-1.0, 1.0);
        }
    }
}

/// Listens for a breath blown at the microphone. Blowing on one is loud rumbling noise, mostly far below the
/// pitch of a voice, so a loud sound whose energy sits mostly under ~150 Hz for a few tens of milliseconds counts
/// as a puff; talking does not.
pub struct BreathDetector {
    sample_rate: f32,
    low: f32,
    streak: f32,
    clock: f32,
    last_puff: f32,
}

impl BreathDetector {
    pub fn new(sample_rate: f32) -> BreathDetector {
        BreathDetector { sample_rate: sample_rate.max(8000.0), low: 0.0, streak: 0.0, clock: 0.0, last_puff: -10.0 }
    }

    /// Takes a block of mono samples, ideally 10–25 ms of them; returns a puff's strength, about 0.2 to 1.2,
    /// when this block continues one, several times a second while blowing.
    pub fn feed(&mut self, samples: &[f32]) -> Option<f32> {
        if samples.is_empty() {
            return None;
        }
        let duration = samples.len() as f32 / self.sample_rate;
        self.clock += duration;
        let alpha = 1.0 - (-2.0 * std::f32::consts::PI * 150.0 / self.sample_rate).exp();
        let (mut total, mut low_energy) = (0.0, 0.0);
        for &x in samples {
            self.low += (x - self.low) * alpha;
            total += x * x;
            low_energy += self.low * self.low;
        }
        let rms = (total / samples.len() as f32).sqrt();
        let share = if total > 0.0 { low_energy / total } else { 0.0 };
        if rms > 0.06 && share > 0.55 {
            self.streak += duration;
        } else {
            self.streak = 0.0;
            return None;
        }
        if self.streak <= 0.06 || self.clock - self.last_puff <= 0.15 {
            return None;
        }
        self.last_puff = self.clock;
        Some(((rms - 0.06) / 0.22 + 0.2).clamp(0.2, 1.2))
    }
}
